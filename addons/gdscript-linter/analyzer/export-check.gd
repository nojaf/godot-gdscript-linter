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
## The engine says which properties are exported and which can hold null.
## GDLintSourceIndex says where each is declared, whether it opts out with
## `= null`, and which names something null-tests, in which scope.

const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")

const CHECK_UNGUARDED_EXPORT := "unguarded-export"

## Where a Node's guard has to live. Exports are populated as the node enters the
## tree, so these are the callbacks that actually run with them set. A guard in a
## helper nobody calls protects nothing.
const LIFECYCLE_CALLBACKS := ["_ready", "_enter_tree"]

## Calls whose argument being an export counts as having checked it.
const GUARD_CALLS := ["assert", "is_instance_valid"]

var _ignore_handler := GDLintIgnoreHandler.new()
var _respect_ignores: bool = true


## Run over the given res:// script paths, returning an Array of Issue.
func run(index: GDLintSourceIndex, file_paths: Array, p_respect_ignores: bool = true) -> Array:
	_respect_ignores = p_respect_ignores

	var issues: Array = []
	for path: String in file_paths:
		issues.append_array(_check_file(index, path))
	return issues


func _check_file(index: GDLintSourceIndex, path: String) -> Array:
	var script: Script = load(path) as Script
	# A script that does not compile reports nothing here; --check-members
	# already flags it, and its property list would be empty anyway.
	if script == null or script.get_instance_base_type().is_empty():
		return []

	var exports := _object_exports(script)
	if exports.is_empty():
		return []

	var entry := index.file_records(path)
	if entry.is_empty() or entry.get("parse_error", false):
		return []

	if _respect_ignores:
		_ignore_handler.initialize(_read_lines(path))

	# A Node's guard must be in a lifecycle callback. A Resource has neither, so
	# any scope counts for one. The distinction comes from the engine rather than
	# from reading the extends line.
	var restrict_to_lifecycle := ClassDB.is_parent_class(script.get_instance_base_type(), "Node")
	var guarded := _guarded_names(entry, restrict_to_lifecycle)

	var issues: Array = []
	for name: String in exports:
		var declaration := _find_declaration(entry, name)
		if declaration.is_empty():
			continue  # cannot point at it; say nothing
		if String(declaration.get("default", "")) == "null":
			continue  # `= null` declares it optional on purpose
		if guarded.has(name):
			continue

		var line := GDLintSourceIndex.line_of(declaration)
		if _respect_ignores and _ignore_handler.should_ignore(line, CHECK_UNGUARDED_EXPORT):
			continue

		issues.append(IssueClass.create(
			path, line, IssueClass.Severity.CRITICAL, CHECK_UNGUARDED_EXPORT,
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


# The class-level declaration of `name`. Scope tells a member apart from a local
# of the same name, which reading lines could not do.
func _find_declaration(entry: Dictionary, name: String) -> Dictionary:
	for declaration: Dictionary in entry.declarations:
		if String(declaration.get("kind", "")) != "variable":
			continue
		if not String(declaration.get("scope", "")).is_empty():
			continue  # a local, not the export
		if String(declaration.get("name", "")) == name:
			return declaration
	return {}


# Names that something actually null-tests.
#
# Matching the TEST rather than a mention matters: `if self.critters.any_walking:`
# names `critters` without checking it, and counting that would excuse the export
# forever. Comparisons come from the index, so the shapes below are the only
# policy left here.
func _guarded_names(entry: Dictionary, restrict_to_lifecycle: bool) -> Dictionary:
	var guarded := {}

	for comparison: Dictionary in entry.comparisons:
		if restrict_to_lifecycle and not _in_lifecycle(String(comparison.get("scope", ""))):
			continue
		var operator := String(comparison.get("operator", ""))
		if operator != "==" and operator != "!=":
			continue
		var left := _bare_name(String(comparison.get("left", {}).get("text", "")))
		var right := _bare_name(String(comparison.get("right", {}).get("text", "")))
		if right == "null" and not left.is_empty():
			guarded[left] = true
		elif left == "null" and not right.is_empty():
			guarded[right] = true

	# assert(x) and is_instance_valid(x), plus `if x:` and `if not x:`.
	for reference: Dictionary in entry.references:
		if restrict_to_lifecycle and not _in_lifecycle(String(reference.get("scope", ""))):
			continue
		var name := String(reference.get("name", ""))

		if bool(reference.get("is_call", false)) and GUARD_CALLS.has(name):
			for argument: Dictionary in reference.get("arguments", []):
				var bare := _bare_name(String(argument.get("text", "")))
				if not bare.is_empty():
					guarded[bare] = true
			continue

		if String(reference.get("context", "")) == "condition":
			guarded[name] = true

	for chain: Dictionary in entry.member_chains:
		if restrict_to_lifecycle and not _in_lifecycle(String(chain.get("scope", ""))):
			continue
		if String(chain.get("context", "")) != "condition":
			continue
		# Only `if self.thing:` guards `thing`. `if self.thing.walking:` does not.
		var names := GDLintSourceIndex.resolvable_segments(chain)
		if names.size() == 2 and names[0] == "self":
			guarded[names[1]] = true

	return guarded


func _in_lifecycle(scope: String) -> bool:
	return LIFECYCLE_CALLBACKS.has(scope)


# `self.critters` and `critters` both name the same export. Anything more
# complicated is not a plain reference to it.
func _bare_name(text: String) -> String:
	var trimmed := text.strip_edges()
	if trimmed.begins_with("self."):
		trimmed = trimmed.substr(5)
	if trimmed.is_valid_identifier():
		return trimmed
	return ""


func _read_lines(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var content := file.get_as_text()
	file.close()
	return Array(content.split("\n"))
