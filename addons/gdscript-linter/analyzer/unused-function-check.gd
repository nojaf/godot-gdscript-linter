# GDScript Linter - Unused function check
# https://poplava.itch.io
class_name GDLintUnusedFunctionCheck
extends RefCounted
## Reports functions that nothing in the project references.
##
## Structure comes from GDLintSourceIndex, which parses the source properly.
## Meaning comes from the engine: ClassDB says which methods are engine virtuals,
## so overriding `_ready` is never reported.
##
## Conservative, but not credulous. A reference is an identifier occurrence in
## code, a segment of a member chain, or a string that actually names a method
## (`call("foo")`, `Callable(self, "foo")`). A string anywhere else is prose, so
## `print("all done")` does not keep `all()` alive.
##
## Scene and resource files are still read as text here, because the index covers
## .gd only and Godot calls methods by name from data: signal connections wired in
## the editor, and AnimationPlayer method tracks.

const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")

const CHECK_UNUSED_FUNCTION := "unused-function"

## Calls whose string arguments name a method.
const METHOD_NAME_CALLS := [
	"call",
	"call_deferred",
	"callv",
	"call_group",
	"call_group_flags",
	"has_method",
	"rpc",
	"rpc_id",
	"connect",
	"disconnect",
	"is_connected",
	"emit_signal",
	"Callable",
	"bind",
]

## Data files Godot calls methods from, which the index does not parse.
const DATA_TEXT_EXTENSIONS := ["tscn", "tres", "cs", "json", "cfg"]
const DATA_BINARY_EXTENSIONS := ["res", "scn"]

var _ignore_handler := GDLintIgnoreHandler.new()
var _respect_ignores: bool = true

# Identifier -> occurrences anywhere in the project.
var _occurrences := { }
# Function name -> how many times it is declared.
var _declaration_counts := { }


## Report unused functions in the given res:// paths, using a built index.
func run(index: GDLintSourceIndex, file_paths: Array, p_respect_ignores: bool = true) -> Array:
	_respect_ignores = p_respect_ignores
	_occurrences.clear()
	_declaration_counts.clear()

	var include_addons := false
	for path: String in file_paths:
		if _is_addon_path(path):
			include_addons = true
			break

	_count_from_index(index, include_addons)
	_count_from_data_files(include_addons)

	var candidates: Array = []
	for path: String in file_paths:
		candidates.append_array(_check_file(index, path))
	return _group_by_name(candidates)


# Every identifier the index saw, from all three places a name can appear.
#
# Chain segments are NOT emitted as reference records, so counting references
# alone would make every `self.foo()` call invisible and report live methods as
# dead. That is the dangerous direction.
func _count_from_index(index: GDLintSourceIndex, include_addons: bool) -> void:
	for path: String in index.files:
		if not include_addons and _is_addon_path(path):
			continue
		var entry: Dictionary = index.files[path]

		for reference: Dictionary in entry.references:
			_add(String(reference.get("name", "")))

		for chain: Dictionary in entry.member_chains:
			for segment: Dictionary in chain.get("segments", []):
				_add(String(segment.get("name", "")))

		for literal: Dictionary in entry.string_literals:
			var argument_of: Dictionary = literal.get("argument_of", { })
			if METHOD_NAME_CALLS.has(String(argument_of.get("callee", ""))):
				_add(String(literal.get("value", "")))

		for declaration: Dictionary in entry.declarations:
			if String(declaration.get("kind", "")) == "function":
				var name := String(declaration.get("name", ""))
				_declaration_counts[name] = _declaration_counts.get(name, 0) + 1


func _add(name: String) -> void:
	if name.is_empty():
		return
	_occurrences[name] = _occurrences.get(name, 0) + 1


# A method wired to a signal in the editor, or fired from an AnimationPlayer
# track, appears only in scene and resource data.
func _count_from_data_files(include_addons: bool) -> void:
	var identifier := RegEx.new()
	identifier.compile("[A-Za-z_][A-Za-z0-9_]*")

	for path: String in _collect_data_files("res://"):
		if not include_addons and _is_addon_path(path):
			continue

		if DATA_BINARY_EXTENSIONS.has(path.get_extension().to_lower()):
			for token in _extract_ascii_identifiers(path):
				_add(token)
			continue

		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var text := file.get_as_text()
		file.close()
		for found in identifier.search_all(text):
			_add(found.get_string())


func _check_file(index: GDLintSourceIndex, path: String) -> Array:
	var entry: Dictionary = index.file_records(path)
	if entry.is_empty() or entry.get("parse_error", false):
		return [] # nothing trustworthy to say about a file that did not parse

	var script: Script = load(path) as Script
	if script == null or script.get_instance_base_type().is_empty():
		return []
	var virtuals := _native_method_names(script.get_instance_base_type())

	if _respect_ignores:
		_ignore_handler.initialize(_read_lines(path))

	var candidates: Array = []
	for declaration: Dictionary in entry.declarations:
		if String(declaration.get("kind", "")) != "function":
			continue

		var name := String(declaration.get("name", ""))
		var line := GDLintSourceIndex.line_of(declaration)

		# A `pass` body is an intentional stub; empty-function already covers it.
		if bool(declaration.get("body_is_pass_only", false)):
			continue
		if virtuals.has(name):
			continue
		if _is_referenced(name, _self_occurrences(entry, declaration)):
			continue
		if _respect_ignores and _ignore_handler.should_ignore(line, CHECK_UNUSED_FUNCTION):
			continue

		candidates.append({ "name": name, "path": path, "line": line })

	if _respect_ignores:
		_ignore_handler.clear()
	return candidates


# Mentions of a function's own name inside its own body. A function that only
# recurses, or that returns its own name as a string, is still dead. Scope makes
# this exact: records inside `func foo` at file level carry scope "foo".
func _self_occurrences(entry: Dictionary, declaration: Dictionary) -> int:
	var outer := String(declaration.get("scope", ""))
	var name := String(declaration.get("name", ""))
	var body_scope := name if outer.is_empty() else outer + "." + name

	var count := 0
	for reference: Dictionary in entry.references:
		if String(reference.get("scope", "")) == body_scope \
				and String(reference.get("name", "")) == name:
			count += 1
	for chain: Dictionary in entry.member_chains:
		if String(chain.get("scope", "")) != body_scope:
			continue
		for segment: Dictionary in chain.get("segments", []):
			if String(segment.get("name", "")) == name:
				count += 1
	for literal: Dictionary in entry.string_literals:
		if String(literal.get("scope", "")) != body_scope:
			continue
		var argument_of: Dictionary = literal.get("argument_of", { })
		if METHOD_NAME_CALLS.has(String(argument_of.get("callee", ""))) \
				and String(literal.get("value", "")) == name:
			count += 1
	return count


# Occurrences count uses, never declarations: the index reports a declaration as
# its own record and does not also emit a reference for the name being declared.
# The previous text-based version had to subtract declarations because scanning
# tokens counted the `func foo` line itself. Subtracting here instead cancels out
# real call sites, which reports live functions as dead.
#
# Mentions inside the function's own body are still discounted. A function that
# only recurses, or that returns its own name as a string, is dead.
func _is_referenced(name: String, self_occurrences: int) -> bool:
	return _occurrences.get(name, 0) - self_occurrences > 0


# One issue per unreferenced name, at its first declaration in path order. A base
# plus its overrides, or an @abstract declaration plus its implementations, is one
# dead contract rather than one problem per site.
func _group_by_name(candidates: Array) -> Array:
	var by_name := { }
	for candidate in candidates:
		var name: String = candidate.name
		if not by_name.has(name):
			by_name[name] = []
		by_name[name].append(candidate)

	var issues: Array = []
	for name: String in by_name.keys():
		var sites: Array = by_name[name]
		sites.sort_custom(
			func(a, b):
				if a.path == b.path:
					return a.line < b.line
				return a.path < b.path,
		)

		var first: Dictionary = sites[0]
		var message := "Function '%s' is never referenced in the project" % name
		if sites.size() > 1:
			message += " (declared in %d places)" % sites.size()
		issues.append(
			IssueClass.create(
				first.path,
				first.line,
				IssueClass.Severity.WARNING,
				CHECK_UNUSED_FUNCTION,
				message,
			)
		)
	return issues


# NOTE: ClassDB.class_has_method() reports false for virtuals like _ready, while
# the method LIST includes them. Using has_method here would mark every lifecycle
# override as dead code.
func _native_method_names(native: String) -> Dictionary:
	var names := { }
	if native.is_empty():
		return names
	for method in ClassDB.class_get_method_list(native):
		names[method.name] = true
	return names


func _is_addon_path(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	if normalized.begins_with("res://"):
		normalized = normalized.substr(6)
	return normalized.begins_with("addons/")


func _collect_data_files(root: String) -> Array:
	var found: Array = []
	var pending: Array = [root]
	while not pending.is_empty():
		var current: String = pending.pop_back()
		var dir := DirAccess.open(current)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if entry.begins_with("."):
				entry = dir.get_next()
				continue
			var full := current.path_join(entry)
			if dir.current_is_dir():
				pending.append(full)
			else:
				var extension := entry.get_extension().to_lower()
				if DATA_TEXT_EXTENSIONS.has(extension) or DATA_BINARY_EXTENSIONS.has(extension):
					found.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	return found


# Godot keeps strings in binary resources as a plain UTF-8 table, so a method name
# in an animation track survives as readable bytes.
func _extract_ascii_identifiers(path: String) -> PackedStringArray:
	var tokens := PackedStringArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return tokens

	var bytes := file.get_buffer(file.get_length())
	file.close()

	var current := PackedByteArray()
	for byte in bytes:
		var is_identifier_char := (
			(byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)
			or (byte >= 48 and byte <= 57) or byte == 95
		)
		if is_identifier_char:
			current.append(byte)
		else:
			if current.size() > 0:
				tokens.append(current.get_string_from_ascii())
				current.clear()
	if current.size() > 0:
		tokens.append(current.get_string_from_ascii())
	return tokens


func _read_lines(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var content := file.get_as_text()
	file.close()
	return Array(content.split("\n"))
