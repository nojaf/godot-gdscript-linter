# GDScript Linter - Unguarded export check
# https://poplava.itch.io
class_name GDLintExportCheck
extends RefCounted
## Reports object-typed `@export` variables that nothing null-guards.
##
## An export holding an object reference is null until something wires it in the
## editor, and nothing guarantees that happened. The failure lands at runtime, far
## from the declaration:
##
##     @export var critters: Critters      # never wired
##     ...
##     self.critters.critter_tapped.connect(...)   # null, at _ready time
##
## Two ways to satisfy the check, both explicit:
##   - guard it: assert(critters != null, "..."), or an `if` null check
##   - declare it optional: `= null` on the declaration
##
## Built-in types are never reported: `@export var hp: int` is 0, not null.
##
## Requires the project to have been imported -- exports are read from the engine,
## not from the text, so `@export_range`, setters and the rest need no parsing.

const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")

const CHECK_UNGUARDED_EXPORT := "unguarded-export"

## GDScript allows annotations before a declaration on the same line:
##     @abstract func may_target(candidate: Critter) -> bool
## A pattern anchored at `func` misses those, and the miss is silent rather than
## noisy: the declaration never registers, while its text still counts as an
## occurrence that keeps the implementation looking alive.
const ANNOTATIONS := "(?:@\\w+(?:\\([^)]*\\))?\\s+)*"

var _ignore_handler := GDLintIgnoreHandler.new()
var _respect_ignores: bool = true


## Run over the given res:// script paths, returning an Array of Issue.
func run(file_paths: Array, p_respect_ignores: bool = true) -> Array:
	_respect_ignores = p_respect_ignores

	var issues: Array = []
	for path: String in file_paths:
		issues.append_array(_check_file(path))
	return issues


func _check_file(path: String) -> Array:
	var script: Script = load(path) as Script
	# A script that does not compile reports nothing here; --check-members
	# already flags it, and its property list would be empty anyway.
	if script == null or script.get_instance_base_type().is_empty():
		return []

	var exports := _object_exports(script)
	if exports.is_empty():
		return []

	var lines := _read_lines(path)
	if lines.is_empty():
		return []

	if _respect_ignores:
		_ignore_handler.initialize(lines)

	# Where the guard has to live depends on what the script is. A Node gets its
	# exports populated as it enters the tree, so _ready/_enter_tree is the place
	# that actually runs with them set; a guard parked in a helper nobody calls
	# protects nothing. A Resource has neither callback, so it is accepted anywhere.
	var native := script.get_instance_base_type()
	var scopes: Array = []
	if ClassDB.is_parent_class(native, "Node"):
		scopes = _lifecycle_ranges(lines)

	var guarded := _guarded_names(lines, scopes)

	var issues: Array = []
	for name: String in exports:
		var declaration := _find_declaration(lines, name)
		if declaration.line == -1:
			continue  # cannot point at it; say nothing
		if declaration.optional:
			continue  # `= null` declares it optional on purpose
		if guarded.has(name):
			continue
		if _respect_ignores and _ignore_handler.should_ignore(declaration.line, CHECK_UNGUARDED_EXPORT):
			continue

		issues.append(IssueClass.create(
			path, declaration.line, IssueClass.Severity.CRITICAL, CHECK_UNGUARDED_EXPORT,
			"Export '%s' is never null-guarded; " % name
			+ "add assert(%s != null, \"...\") or declare it optional with '= null'" % name))

	if _respect_ignores:
		_ignore_handler.clear()
	return issues


# Exported properties that can hold null. The engine distinguishes exported from
# plain members, and object types from built-ins, so none of this is parsed.
func _object_exports(script: Script) -> Array:
	var names: Array = []
	for prop in script.get_script_property_list():
		var usage := int(prop.usage)
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue  # a plain member, not an @export
		if prop.type != TYPE_OBJECT:
			continue  # int/float/Color/Array and friends are never null
		names.append(String(prop.name))
	return names


# The declaration's line, and whether it opts out with `= null`. The engine knows
# the property exists but not where it was written or what it defaults to.
func _find_declaration(lines: Array, name: String) -> Dictionary:
	var declaration := RegEx.new()
	declaration.compile("^\\s*(?:@export\\w*(?:\\s*\\([^)]*\\))?\\s+)?var\\s+" + name + "\\b(.*)$")

	var null_default := RegEx.new()
	null_default.compile("=\\s*null\\b")

	for i in range(lines.size()):
		# The comment has to go first: a trailing note that merely mentions
		# `= null` would otherwise read as the declaration opting out.
		var code := _strip_comment(String(lines[i]))
		var found := declaration.search(code)
		if found == null:
			continue
		return {"line": i + 1, "optional": null_default.search(found.get_string(1)) != null}

	return {"line": -1, "optional": false}


# Cuts the line at its first unquoted '#'.
func _strip_comment(line: String) -> String:
	var quote := ""
	for i in range(line.length()):
		var ch := line[i]
		if quote.is_empty():
			if ch == "\"" or ch == "'":
				quote = ch
			elif ch == "#":
				return line.substr(0, i)
		elif ch == quote:
			quote = ""
	return line


# Names that something actually null-tests, anywhere in the file.
#
# Matching the TEST rather than "appears near an assert" matters: a condition that
# merely mentions the name -- `if self.critters.any_enemy_walking:` -- is not a
# guard, and counting it silently excuses the export forever.
#
# Working line by line also handles asserts that wrap, since each line of a
# compound condition carries its own `x != null` term.
const GUARD_PATTERNS := [
	"(?:self\\.)?([A-Za-z_][A-Za-z0-9_]*)\\s*(?:==|!=)\\s*null",   # x != null
	"null\\s*(?:==|!=)\\s*(?:self\\.)?([A-Za-z_][A-Za-z0-9_]*)",   # null != x
	"is_instance_valid\\(\\s*(?:self\\.)?([A-Za-z_][A-Za-z0-9_]*)\\s*\\)",
	"^\\s*(?:el)?if\\s+(?:not\\s+)?(?:self\\.)?([A-Za-z_][A-Za-z0-9_]*)\\s*:",  # if x: / if not x:
	"\\bassert\\(\\s*(?:not\\s+)?(?:self\\.)?([A-Za-z_][A-Za-z0-9_]*)\\s*[,)]", # assert(x, ...)
]


# scopes limits which lines may contain a guard, as [start, end) pairs. Empty
# means the whole file counts.
func _guarded_names(lines: Array, scopes: Array) -> Dictionary:
	var matchers: Array = []
	for pattern in GUARD_PATTERNS:
		var regex := RegEx.new()
		regex.compile(pattern)
		matchers.append(regex)

	var guarded := {}
	for i in range(lines.size()):
		if not scopes.is_empty() and not _within(i, scopes):
			continue
		var code := _strip_comment(String(lines[i]))
		for matcher: RegEx in matchers:
			for found in matcher.search_all(code):
				guarded[found.get_string(1)] = true
	return guarded


func _within(index: int, scopes: Array) -> bool:
	for scope in scopes:
		if index >= scope[0] and index < scope[1]:
			return true
	return false


# Line ranges of _ready and _enter_tree. A body runs to the next function or to
# the next class-level statement.
func _lifecycle_ranges(lines: Array) -> Array:
	var any_func := RegEx.new()
	any_func.compile("^\\s*" + ANNOTATIONS + "(?:static\\s+)?func\\s+([A-Za-z_][A-Za-z0-9_]*)")

	var ranges: Array = []
	var open_from := -1
	for i in range(lines.size()):
		var text := String(lines[i])
		var found := any_func.search(text)

		if found != null:
			if open_from != -1:
				ranges.append([open_from, i])
				open_from = -1
			var name := found.get_string(1)
			if name == "_ready" or name == "_enter_tree":
				open_from = i
			continue

		# A non-indented statement ends the body just as a new function does.
		if open_from != -1 and not text.strip_edges().is_empty() and text == text.strip_edges(true, false):
			ranges.append([open_from, i])
			open_from = -1

	if open_from != -1:
		ranges.append([open_from, lines.size()])
	return ranges


func _read_lines(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var content := file.get_as_text()
	file.close()
	return Array(content.split("\n"))
