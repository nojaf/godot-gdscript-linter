# GDScript Linter - Member access check
# https://poplava.itch.io
class_name GDLintMemberCheck
extends RefCounted
## Verifies that every `self.foo.bar` chain actually resolves, by asking the
## engine what members a type has instead of parsing declarations.
##
## Three findings, all CRITICAL:
##   script-load-failed   - the script does not compile, so nothing in it can be
##                          checked (Godot prints the parse error, on stderr)
##   unknown-member       - a name in the chain is not a member of the type it is
##                          being read from
##   wrong-argument-count - a signal is emitted with the wrong argument count
##
## Why this is needed at all: GDScript resolves property access through `self`
## at runtime, and does not verify property access on typed object variables
## either. Both of these compile clean and fail only when the line executes:
##
##     self.clock_labl.text = "x"   # no such member on this script
##     self.clock.ziggy = "x"       # clock is a Label; Label has no 'ziggy'
##     self.stopped_walking.emit()  # the signal takes one argument
##
## Method call arity is NOT checked here: Godot's parser already rejects those,
## so a bad call surfaces as script-load-failed. Signal emits are the only arity
## it lets through.
##
## Requires files on disk to be current and the project to have been imported —
## a stale script class cache makes every script fail to load.

const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")

const CHECK_LOAD_FAILED := "script-load-failed"
const CHECK_UNKNOWN_MEMBER := "unknown-member"
const CHECK_ARGUMENT_COUNT := "wrong-argument-count"

## How far a call's argument list may span before we give up counting it.
const MAX_CALL_LINES := 60

## Scripts overriding any of these can answer to names that exist in no member
## list, so they are skipped entirely.
const DYNAMIC_PROPERTY_HOOKS := ["_get_property_list", "_set", "_get"]

var _ignore_handler := GDLintIgnoreHandler.new()
var _respect_ignores: bool = true

# class name -> {names: Dictionary, types: Dictionary}, built on demand.
var _member_cache := {}
# class_name -> res:// path, for classes declared by project scripts.
var _global_classes := {}


## Run over the given res:// script paths, returning an Array of Issue.
func run(file_paths: Array, p_respect_ignores: bool = true) -> Array:
	_respect_ignores = p_respect_ignores
	_member_cache.clear()
	_build_global_class_map()

	var scripts := {}      # path -> Script, null when it failed to compile
	var broken: Array = []
	for path in file_paths:
		var script: Script = load(path) as Script
		# load() hands back a non-null but uncompiled Script for a broken file;
		# an empty instance base type is what actually marks it unusable.
		if script == null or script.get_instance_base_type().is_empty():
			scripts[path] = null
			broken.append(path)
		else:
			scripts[path] = script

	var issues: Array = []
	issues.append_array(_report_load_failures(broken, scripts))

	for path in file_paths:
		if scripts[path] == null:
			continue
		issues.append_array(_check_file(path, scripts[path]))

	return issues


func _build_global_class_map() -> void:
	_global_classes.clear()
	for entry in ProjectSettings.get_global_class_list():
		if entry.has("class") and entry.has("path"):
			_global_classes[String(entry["class"])] = String(entry["path"])


# A broken base script breaks everything extending it. Report the root cause and
# fold the dependents into its message rather than listing every consequence.
func _report_load_failures(broken: Array, scripts: Dictionary) -> Array:
	var class_to_path := {}
	for path in scripts.keys():
		var declared := _declared_class_name(path)
		if not declared.is_empty():
			class_to_path[declared] = path

	var caused_by := {}
	for path in broken:
		var base := _declared_base(path)
		if base.is_empty():
			continue
		var base_path := ""
		if class_to_path.has(base):
			base_path = class_to_path[base]
		elif base.begins_with("res://"):
			base_path = base
		if base_path != path and broken.has(base_path):
			caused_by[path] = base_path

	var dependents := {}
	for path in caused_by.keys():
		var root: String = caused_by[path]
		var guard := 0
		while caused_by.has(root) and guard < 100:
			root = caused_by[root]
			guard += 1
		dependents[root] = dependents.get(root, 0) + 1

	var issues: Array = []
	for path in broken:
		if caused_by.has(path):
			continue
		var message := "Script fails to compile (see the parse error above)"
		if dependents.has(path):
			message += "; %d dependent script(s) fail because of it" % dependents[path]
		issues.append(IssueClass.create(
			path, 1, IssueClass.Severity.CRITICAL, CHECK_LOAD_FAILED, message))
	return issues


func _check_file(path: String, script: Script) -> Array:
	# Only the script's OWN methods count here: ClassDB reports these hooks as
	# virtuals on Object, so testing the merged member set would skip everything.
	for method in script.get_script_method_list():
		if DYNAMIC_PROPERTY_HOOKS.has(method.name):
			return []

	var lines := _read_lines(path)
	if lines.is_empty():
		return []

	if _respect_ignores:
		_ignore_handler.initialize(lines)

	# `self` followed by one or more .name segments.
	var chain_regex := RegEx.new()
	chain_regex.compile("\\bself((?:\\.[A-Za-z_][A-Za-z0-9_]*)+)")

	# A bare `some_signal.emit(` -- not preceded by a dot or another identifier.
	var bare_emit_regex := RegEx.new()
	bare_emit_regex.compile("(?<![.\\w])([A-Za-z_][A-Za-z0-9_]*)\\.emit\\s*\\(")

	var root := _members_of_script(script)
	var root_label := _script_label(path, script)

	var issues: Array = []
	var in_block_string := false
	for i in range(lines.size()):
		var line: String = lines[i]

		# Triple-quoted blocks would otherwise hand us matches out of prose.
		var fence_count := line.count("\"\"\"")
		if in_block_string:
			if fence_count > 0:
				in_block_string = false
			continue
		if fence_count % 2 == 1:
			in_block_string = true
			continue

		var code := _strip_strings_and_comments(line)
		for found in chain_regex.search_all(code):
			var segments: PackedStringArray = found.get_string(1).substr(1).split(".")
			# A '(' right after the chain makes the last segment a call, and the
			# argument list may run past the end of this line.
			var argument_count := -1
			var paren := _next_non_space(code, found.get_end())
			if paren != -1 and code[paren] == "(":
				argument_count = _count_call_arguments(lines, i, paren)
			var issue = _check_chain(path, i + 1, segments, root, root_label, argument_count)
			if issue != null:
				issues.append(issue)

		# Signals are just as often emitted without the `self.` prefix, and Godot
		# misses that form too. The lookbehind keeps this from re-matching the
		# tail of a chain already handled above.
		for found in bare_emit_regex.search_all(code):
			var signal_name := found.get_string(1)
			if not root.signals.has(signal_name):
				continue
			var paren := _next_non_space(code, found.get_end() - 1)
			if paren == -1 or code[paren] != "(":
				continue
			var given := _count_call_arguments(lines, i, paren)
			if given < 0:
				continue
			var issue = _check_signal_arity(path, i + 1, signal_name, given, root.signals[signal_name])
			if issue != null:
				issues.append(issue)

	if _respect_ignores:
		_ignore_handler.clear()
	return issues


# Walk the chain, hopping from one type's member set to the next. Stops silently
# the moment a type can no longer be resolved -- no resolution, no verdict.
# argument_count is -1 when the chain is not a call, or when the argument list
# could not be counted.
func _check_chain(path: String, line_num: int, segments: PackedStringArray, root: Dictionary, root_label: String, argument_count: int = -1):
	var current := root
	var owner_label := root_label
	var last := segments.size() - 1

	for index in range(segments.size()):
		var segment := segments[index]

		if not current.names.has(segment):
			if _respect_ignores and _ignore_handler.should_ignore(line_num, CHECK_UNKNOWN_MEMBER):
				return null
			var message := "'%s' is not a member of %s" % [segment, owner_label]
			var suggestion := _closest_member(segment, current.names)
			if not suggestion.is_empty():
				message += " (did you mean '%s'?)" % suggestion
			return IssueClass.create(
				path, line_num, IssueClass.Severity.CRITICAL, CHECK_UNKNOWN_MEMBER, message)

		# <signal>.emit(...) -- checked here because a signal has no type to step
		# into, so the walk would otherwise stop before reaching .emit.
		if index == last - 1 and argument_count >= 0 \
				and segments[last] == "emit" and current.signals.has(segment):
			return _check_signal_arity(path, line_num, segment, argument_count,
				current.signals[segment])

		# Only object-typed properties carry a class we can step into. Methods,
		# signals, constants and built-in types end the walk.
		var next_class: String = current.types.get(segment, "")
		if next_class.is_empty():
			return null
		var next := _members_of_class(next_class)
		if next.names.is_empty():
			return null
		current = next
		owner_label = next_class

	return null


# Signals have no default arguments, so the expected count is exact.
func _check_signal_arity(path: String, line_num: int, signal_name: String, given: int, expected: int):
	if given == expected:
		return null
	if _respect_ignores and _ignore_handler.should_ignore(line_num, CHECK_ARGUMENT_COUNT):
		return null
	return IssueClass.create(
		path, line_num, IssueClass.Severity.CRITICAL, CHECK_ARGUMENT_COUNT,
		"Signal '%s' emitted with %d argument(s), expected %d" % [signal_name, given, expected])


func _next_non_space(text: String, from: int) -> int:
	for i in range(from, text.length()):
		if text[i] != " " and text[i] != "\t":
			return i
	return -1


# Counts top-level commas between the matching parentheses, following the call
# across lines when it wraps. Returns -1 when the list cannot be delimited, so an
# unbalanced or over-long call yields no verdict rather than a wrong one.
func _count_call_arguments(lines: Array, start_line: int, paren_index: int) -> int:
	var depth := 0
	var commas := 0
	var has_content := false
	var limit: int = mini(lines.size(), start_line + MAX_CALL_LINES)

	for i in range(start_line, limit):
		# Strings and comments are removed so their commas and brackets never count.
		var code := _strip_strings_and_comments(String(lines[i]))
		var start := paren_index if i == start_line else 0
		if start >= code.length():
			continue

		for j in range(start, code.length()):
			var ch := code[j]
			match ch:
				"(", "[", "{":
					depth += 1
				")", "]", "}":
					depth -= 1
					if depth == 0:
						return commas + 1 if has_content else 0
				",":
					if depth == 1:
						commas += 1
				_:
					if depth >= 1 and ch != " " and ch != "\t":
						has_content = true
	return -1


# Members of a loaded script: its own plus, already merged by the engine, those
# inherited from base scripts, plus the native class the chain bottoms out in.
func _members_of_script(script: Script) -> Dictionary:
	var names := {}
	var types := {}
	var signals := {}

	for prop in script.get_script_property_list():
		# Drops the per-file category rows the property list interleaves.
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			names[prop.name] = true
			_record_type(types, prop)
	for method in script.get_script_method_list():
		names[method.name] = true
	for signal_info in script.get_script_signal_list():
		names[signal_info.name] = true
		signals[signal_info.name] = signal_info.args.size()
	for constant in script.get_script_constant_map().keys():
		names[String(constant)] = true

	var native := script.get_instance_base_type()
	if not native.is_empty():
		var native_members := _members_of_native(native)
		names.merge(native_members.names)
		types.merge(native_members.types)
		signals.merge(native_members.signals)

	return {"names": names, "types": types, "signals": signals}


func _members_of_class(class_name_str: String) -> Dictionary:
	if _member_cache.has(class_name_str):
		return _member_cache[class_name_str]

	var resolved := {"names": {}, "types": {}, "signals": {}}
	if _global_classes.has(class_name_str):
		var script: Script = load(_global_classes[class_name_str]) as Script
		if script != null and not script.get_instance_base_type().is_empty():
			resolved = _members_of_script(script)
	elif ClassDB.class_exists(class_name_str):
		resolved = _members_of_native(class_name_str)

	_member_cache[class_name_str] = resolved
	return resolved


func _members_of_native(native: String) -> Dictionary:
	var cache_key := "native:" + native
	if _member_cache.has(cache_key):
		return _member_cache[cache_key]

	var names := {}
	var types := {}
	var signals := {}
	for prop in ClassDB.class_get_property_list(native):
		names[prop.name] = true
		_record_type(types, prop)
	for method in ClassDB.class_get_method_list(native):
		names[method.name] = true
	for signal_info in ClassDB.class_get_signal_list(native):
		names[signal_info.name] = true
		signals[signal_info.name] = signal_info.args.size()
	for constant in ClassDB.class_get_integer_constant_list(native):
		names[constant] = true

	var resolved := {"names": names, "types": types, "signals": signals}
	_member_cache[cache_key] = resolved
	return resolved


func _record_type(types: Dictionary, prop: Dictionary) -> void:
	if prop.get("type", TYPE_NIL) != TYPE_OBJECT:
		return
	var declared := String(prop.get("class_name", ""))
	if not declared.is_empty():
		types[prop.name] = declared


# similarity() is 0.0..1.0; below the threshold a suggestion is noise, not help.
func _closest_member(name: String, names: Dictionary) -> String:
	const MIN_SIMILARITY := 0.5
	var best := ""
	var best_score := MIN_SIMILARITY
	for candidate in names.keys():
		var score := String(candidate).similarity(name)
		if score > best_score:
			best_score = score
			best = String(candidate)
	return best


func _strip_strings_and_comments(line: String) -> String:
	var result := line

	var dq := RegEx.new()
	dq.compile("\"[^\"]*\"")
	result = dq.sub(result, "\"\"", true)

	var sq := RegEx.new()
	sq.compile("'[^']*'")
	result = sq.sub(result, "''", true)

	# With the strings gone a '#' can only start a comment.
	var comment := result.find("#")
	if comment >= 0:
		result = result.substr(0, comment)

	return result


func _read_lines(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var content := file.get_as_text()
	file.close()
	return Array(content.split("\n"))


func _declared_class_name(path: String) -> String:
	for line in _read_lines(path):
		var trimmed: String = String(line).strip_edges()
		if trimmed.begins_with("class_name "):
			return trimmed.substr("class_name ".length()).strip_edges().split(" ")[0]
	return ""


func _declared_base(path: String) -> String:
	for line in _read_lines(path):
		var trimmed: String = String(line).strip_edges()
		if trimmed.begins_with("extends "):
			return trimmed.substr("extends ".length()).strip_edges().replace("\"", "")
	return ""


func _script_label(path: String, script: Script) -> String:
	var global_name := script.get_global_name()
	if not String(global_name).is_empty():
		return String(global_name)
	return path.get_file()
