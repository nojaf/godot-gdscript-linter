# GDScript Linter - Unused function check
# https://poplava.itch.io
class_name GDLintUnusedFunctionCheck
extends RefCounted
## Reports functions that nothing in the project references.
##
## Conservative, but not credulous. A reference is any occurrence of the name in
## code, plus a name inside a string only where that string actually names a
## method -- call("foo"), Callable(self, "foo") -- plus method="..." wiring in
## scene and resource files. A string anywhere else is prose: print("all done")
## does not keep a function called `all` alive.
##
## Where it errs, it errs toward silence: it misses some dead code rather than
## telling you to delete something that is live.
##
## Engine-called virtuals (_ready, _process, ...) are excluded by asking ClassDB
## what the native base class declares, so overriding them is never reported.
##
## Placeholder bodies (just `pass`) are skipped -- the empty-function check
## already covers those, and a placeholder is usually intentional.

const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")

const CHECK_UNUSED_FUNCTION := "unused-function"

## Text files searched for references. Scene and resource files matter because
## Godot itself calls methods by name from data rather than from code:
##   .tscn  [connection ... method="_on_button_pressed"]
##   .tscn  AnimationPlayer method tracks: "method": &"spawn_wave"
##   .tres  the same, once an animation is saved outside its scene
## .cs is here for Mono projects calling into GDScript by name.
const REFERENCE_TEXT_EXTENSIONS := ["gd", "tscn", "tres", "cs", "json", "cfg"]

## Binary equivalents of the above. Godot stores strings in these as plain UTF-8,
## so the ASCII runs are readable even though the container is not. Scanning them
## can only ADD references, so a false read makes the check quieter, never wronger.
const REFERENCE_BINARY_EXTENSIONS := ["res", "scn"]

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

	# addons/ is third-party code and is excluded from analysis by default. Its
	# text must not count as references either: the linter's own installed copy
	# contains ~80 standalone `all` tokens, which was enough to hide a real dead
	# `all()` in the project being analyzed. Only index it when it is what is
	# being analyzed (dogfooding the addon itself).
	var include_addons := false
	for path: String in file_paths:
		if _is_addon_path(path):
			include_addons = true
			break

	_index_project(include_addons)

	var issues: Array = []
	for path in file_paths:
		issues.append_array(_check_file(path))
	return issues


# Analyzed paths arrive with or without the res:// prefix depending on how the
# target was given on the command line, so both forms have to be recognized.
func _is_addon_path(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	if normalized.begins_with("res://"):
		normalized = normalized.substr(6)
	return normalized.begins_with("addons/")


func _index_project(include_addons: bool) -> void:
	for path: String in _collect_project_files("res://"):
		if not include_addons and _is_addon_path(path):
			continue
		var extension := path.get_extension().to_lower()

		if REFERENCE_BINARY_EXTENSIONS.has(extension):
			for token in _extract_ascii_identifiers(path):
				_token_counts[token] = _token_counts.get(token, 0) + 1
			continue

		var text := _read_text(path)
		if text.is_empty():
			continue

		if extension == "gd":
			text = _strip_comments_preserving_strings(text)
			_count_declarations(text)
			for token in _countable_tokens(text):
				_token_counts[token] = _token_counts.get(token, 0) + 1
			continue

		# Scene and resource text is data, not prose: scan all of it.
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
		# Same token policy as the project-wide index, so the two counts subtract
		# cleanly against each other.
		for token in _countable_tokens(_strip_comments_preserving_strings(raw)):
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


## Calls whose string arguments name a method. A string anywhere else is prose:
## print("all done") must not keep a function called `all` alive.
const METHOD_NAME_CALLS := [
	"call", "call_deferred", "callv", "call_group", "call_group_flags",
	"has_method", "rpc", "rpc_id", "connect", "disconnect", "is_connected",
	"emit_signal", "Callable", "bind",
]


# Identifiers that count as references in GDScript source: everything outside
# string literals, plus the contents of strings sitting in a method-name position.
func _countable_tokens(text: String) -> PackedStringArray:
	var spans := _string_spans(text)
	var without_strings := _blank_spans(text, spans)

	var tokens := _tokenize(without_strings)
	for span in _method_name_spans(without_strings):
		for string_span in spans:
			if string_span.start >= span[0] and string_span.start < span[1]:
				tokens.append_array(_tokenize(text.substr(
					string_span.start + 1, string_span.end - string_span.start - 1)))
	return tokens


# Start/end offsets of every string literal, so they can be blanked out and then
# selectively read back. Triple-quoted blocks are handled as one span.
func _string_spans(text: String) -> Array:
	var spans: Array = []
	var i := 0
	while i < text.length():
		var ch := text[i]
		if ch != "\"" and ch != "'":
			i += 1
			continue

		var triple := text.substr(i, 3) == ch.repeat(3)
		var closer := ch.repeat(3) if triple else ch
		var start := i
		i += closer.length()
		while i < text.length():
			if text[i] == "\\":
				i += 2
				continue
			if text.substr(i, closer.length()) == closer:
				i += closer.length()
				break
			i += 1
		spans.append({"start": start, "end": i - 1})
	return spans


# Replaces each span with spaces, keeping every offset where it was.
func _blank_spans(text: String, spans: Array) -> String:
	var out := text
	for span in spans:
		var length: int = span.end - span.start + 1
		out = out.substr(0, span.start) + " ".repeat(length) + out.substr(span.end + 1)
	return out


# Argument-list spans of the calls above, found in string-free text so a call
# name mentioned inside a string cannot open one.
func _method_name_spans(without_strings: String) -> Array:
	var opener := RegEx.new()
	# Only a preceding word character disqualifies a match (so `recall(` is not
	# `call(`). A preceding dot must NOT: these are nearly always written as
	# self.call(...) or node.rpc(...).
	opener.compile("(?<!\\w)(" + "|".join(METHOD_NAME_CALLS) + ")\\s*\\(")

	var spans: Array = []
	for found in opener.search_all(without_strings):
		var depth := 0
		var start := found.get_end() - 1
		for i in range(start, without_strings.length()):
			var ch := without_strings[i]
			if ch == "(":
				depth += 1
			elif ch == ")":
				depth -= 1
				if depth == 0:
					spans.append([start, i])
					break
	return spans


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
			else:
				var extension := entry.get_extension().to_lower()
				if REFERENCE_TEXT_EXTENSIONS.has(extension) or REFERENCE_BINARY_EXTENSIONS.has(extension):
					found.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	return found


# Pulls identifier-shaped ASCII runs out of a binary resource. Godot's binary
# format keeps strings in a plain UTF-8 table, so a method name stored in an
# animation track survives as readable bytes.
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
			(byte >= 65 and byte <= 90) or    # A-Z
			(byte >= 97 and byte <= 122) or   # a-z
			(byte >= 48 and byte <= 57) or    # 0-9
			byte == 95)                       # _
		if is_identifier_char:
			current.append(byte)
		else:
			if current.size() > 0:
				tokens.append(current.get_string_from_ascii())
				current.clear()
	if current.size() > 0:
		tokens.append(current.get_string_from_ascii())

	return tokens


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
