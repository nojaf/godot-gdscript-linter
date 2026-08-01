# GDScript Linter - Unused function check
# https://poplava.itch.io
class_name GDLintUnusedFunctionCheck
extends RefCounted
## Reports functions that nothing in the project references.
##
## Deliberately conservative: it counts every occurrence of the name anywhere in
## the project -- calls, bare Callable references, names inside strings, and
## method="..." wiring in scene files -- and only reports a function when the
## name appears nowhere but its own declaration. That direction of error is the
## safe one: it misses some dead code rather than telling you to delete
## something that is live.
##
## Engine-called virtuals (_ready, _process, ...) are excluded by asking ClassDB
## what the native base class declares, so overriding them is never reported.
##
## Placeholder bodies (just `pass`) are skipped -- the empty-function check
## already covers those, and a placeholder is usually intentional.

const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")

const CHECK_UNUSED_FUNCTION := "unused-function"

## Files searched for references. Scene and resource files matter because the
## editor wires signals to handlers by name: method="_on_button_pressed".
const REFERENCE_EXTENSIONS := ["gd", "tscn", "tres"]

var _ignore_handler := GDLintIgnoreHandler.new()
var _respect_ignores: bool = true

# Identifier -> how many times it appears anywhere in the project.
var _token_counts := {}
# Function name -> how many times it is DECLARED across the project.
var _declaration_counts := {}


## Report unused functions in the given res:// script paths. References are
## searched project-wide regardless of which paths are being reported on, so
## narrowing the analysis scope cannot manufacture false positives.
func run(file_paths: Array, p_respect_ignores: bool = true) -> Array:
	_respect_ignores = p_respect_ignores
	_token_counts.clear()
	_declaration_counts.clear()

	_index_project()

	var issues: Array = []
	for path in file_paths:
		issues.append_array(_check_file(path))
	return issues


func _index_project() -> void:
	for path in _collect_project_files("res://"):
		var text := _read_text(path)
		if text.is_empty():
			continue

		if path.get_extension().to_lower() == "gd":
			# Comments are stripped so a function merely mentioned in prose does
			# not count as a reference. String literals are KEPT, because
			# call("foo") and Callable(self, "foo") are real references.
			text = _strip_comments_preserving_strings(text)
			_count_declarations(text)

		for token in _tokenize(text):
			_token_counts[token] = _token_counts.get(token, 0) + 1


func _check_file(path: String) -> Array:
	var script: Script = load(path) as Script
	# Without a compiled script the native base is unknown, so engine virtuals
	# cannot be identified and every _ready() would look dead. Skip the file.
	if script == null or script.get_instance_base_type().is_empty():
		return []

	var virtuals := _native_method_names(script.get_instance_base_type())

	var lines := _read_lines(path)
	if lines.is_empty():
		return []

	if _respect_ignores:
		_ignore_handler.initialize(lines)

	var issues: Array = []
	for declaration in _find_declarations(lines):
		var name: String = declaration.name

		if declaration.is_placeholder:
			continue
		if virtuals.has(name):
			continue
		if _is_referenced(name, declaration.self_occurrences):
			continue
		if _respect_ignores and _ignore_handler.should_ignore(declaration.line, CHECK_UNUSED_FUNCTION):
			continue

		issues.append(IssueClass.create(
			path, declaration.line, IssueClass.Severity.WARNING, CHECK_UNUSED_FUNCTION,
			"Function '%s' is never referenced in the project" % name))

	if _respect_ignores:
		_ignore_handler.clear()
	return issues


# Every declaration contributes one occurrence of its own name, and mentions
# inside the function's own body are not somebody else calling it -- a function
# that only recurses, or that returns its own name as a string, is still dead.
# What is left after discounting both is a genuine reference.
func _is_referenced(name: String, self_occurrences: int) -> bool:
	var occurrences: int = _token_counts.get(name, 0)
	var declarations: int = _declaration_counts.get(name, 1)
	return occurrences - declarations - self_occurrences > 0


func _find_declarations(lines: Array) -> Array:
	var func_regex := RegEx.new()
	func_regex.compile("^\\s*(?:static\\s+)?func\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")

	var declarations: Array = []
	for i in range(lines.size()):
		var found := func_regex.search(String(lines[i]))
		if found == null:
			continue
		var name := found.get_string(1)
		declarations.append({
			"name": name,
			"line": i + 1,
			"is_placeholder": _is_placeholder_body(lines, i),
			"self_occurrences": _count_in_body(lines, i, name, func_regex),
		})
	return declarations


# How often the function names itself inside its own body. Comments are stripped
# to match how the project-wide index was built, so the two counts are comparable.
func _count_in_body(lines: Array, declaration_index: int, name: String, func_regex: RegEx) -> int:
	var count := 0
	for i in range(declaration_index + 1, lines.size()):
		var raw: String = String(lines[i])
		# The body ends at the next function, or at the next class-level line.
		if func_regex.search(raw) != null:
			break
		var trimmed := raw.strip_edges()
		if not trimmed.is_empty() and not trimmed.begins_with("#") and raw == trimmed:
			break
		for token in _tokenize(_strip_comments_preserving_strings(raw)):
			if token == name:
				count += 1
	return count


# True when the body contains nothing but `pass`. Those are intentional stubs and
# the empty-function check already reports them.
func _is_placeholder_body(lines: Array, declaration_index: int) -> bool:
	var body_indent := -1
	for i in range(declaration_index + 1, lines.size()):
		var raw: String = String(lines[i])
		var trimmed := raw.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue

		var indent := raw.length() - raw.strip_edges(true, false).length()
		if body_indent == -1:
			body_indent = indent
		elif indent < body_indent:
			break  # dedented out of the body

		if trimmed != "pass":
			return false
	return body_indent != -1


func _count_declarations(text: String) -> void:
	var func_regex := RegEx.new()
	func_regex.compile("(?m)^\\s*(?:static\\s+)?func\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	for found in func_regex.search_all(text):
		var name := found.get_string(1)
		_declaration_counts[name] = _declaration_counts.get(name, 0) + 1


func _native_method_names(native: String) -> Dictionary:
	var names := {}
	if native.is_empty():
		return names
	# NOTE: ClassDB.class_has_method() reports false for virtuals like _ready,
	# but the method LIST includes them. Using has_method here would mark every
	# lifecycle override as dead code.
	for method in ClassDB.class_get_method_list(native):
		names[method.name] = true
	return names


func _tokenize(text: String) -> PackedStringArray:
	var identifier := RegEx.new()
	identifier.compile("[A-Za-z_][A-Za-z0-9_]*")
	var tokens := PackedStringArray()
	for found in identifier.search_all(text):
		tokens.append(found.get_string())
	return tokens


# Cuts each line at its first unquoted '#'. String contents are preserved so that
# names referenced only from strings still count.
func _strip_comments_preserving_strings(text: String) -> String:
	var out := PackedStringArray()
	for raw in text.split("\n"):
		var line: String = raw
		var quote := ""
		var cut := -1
		for i in range(line.length()):
			var ch := line[i]
			if quote.is_empty():
				if ch == "\"" or ch == "'":
					quote = ch
				elif ch == "#":
					cut = i
					break
			elif ch == quote:
				quote = ""
		out.append(line.substr(0, cut) if cut >= 0 else line)
	return "\n".join(out)


func _collect_project_files(root: String) -> Array:
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
			elif REFERENCE_EXTENSIONS.has(entry.get_extension().to_lower()):
				found.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	return found


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


func _read_lines(path: String) -> Array:
	var text := _read_text(path)
	if text.is_empty():
		return []
	return Array(text.split("\n"))
