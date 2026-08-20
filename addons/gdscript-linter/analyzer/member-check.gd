# GDScript Linter - Member access check
# https://poplava.itch.io
class_name GDLintMemberCheck
extends RefCounted
## Verifies that member access resolves, by joining two sources.
##
## GDLintSourceIndex says where things are written: member chains with their
## segments, whether each segment is a call, argument counts, the scope each sits
## in, and what each file extends. The engine says what things mean: every member
## of a type including inherited ones, declared types, and signal arity.
##
## Four findings, all CRITICAL:
##   script-load-failed   - the script does not compile, so nothing in it can be
##                          checked (Godot prints the parse error, on stderr)
##   unknown-member       - a name in a chain is not a member of the type it is
##                          read from
##   wrong-argument-count - a signal is emitted with the wrong argument count
##   method-not-called    - a method is used as a condition without being called
##
## GDScript verifies none of these at parse time. Property access through `self`
## is resolved at runtime, property access on typed object variables is not
## verified either, signal emit arity is not checked, and a bare method reference
## in a condition is a Callable, which is always true.
##
## Method call arity is deliberately absent: Godot's own parser rejects those, so
## a bad call surfaces here as script-load-failed instead.

const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")

const CHECK_LOAD_FAILED := "script-load-failed"
const CHECK_UNKNOWN_MEMBER := "unknown-member"
const CHECK_ARGUMENT_COUNT := "wrong-argument-count"
const CHECK_METHOD_NOT_CALLED := "method-not-called"

## Scripts overriding any of these can answer to names that exist in no member
## list, so they are skipped entirely.
const DYNAMIC_PROPERTY_HOOKS := ["_get_property_list", "_set", "_get"]


var _ignore_handler := GDLintIgnoreHandler.new()
var _respect_ignores: bool = true

# What the engine says each type contains.
var _types := GDLintMemberTypes.new()
# Decides how unknown members read through a typed member are reported.
var _fold := GDLintWideReadFold.new(_types, CHECK_UNKNOWN_MEMBER)


## Run over the given res:// script paths, returning an Array of Issue.
func run(index: GDLintSourceIndex, file_paths: Array, p_respect_ignores: bool = true) -> Array:
	_respect_ignores = p_respect_ignores
	_types.build_class_map()

	var scripts := {}      # path -> Script, null when it failed to compile
	var broken: Array = []
	for path: String in file_paths:
		var script: Script = load(path) as Script
		# load() hands back a non-null but uncompiled Script for a broken file;
		# an empty instance base type is what actually marks it unusable.
		if script == null or script.get_instance_base_type().is_empty():
			scripts[path] = null
			broken.append(path)
		else:
			scripts[path] = script

	var issues: Array = []
	issues.append_array(_report_load_failures(index, broken))

	for path: String in file_paths:
		if scripts[path] == null:
			continue
		issues.append_array(_check_file(index, path, scripts[path]))

	return issues


# A broken base script breaks everything extending it. Report the root cause and
# fold the dependents into its message rather than listing every consequence.
#
# Both halves come from the index, and neither can come from the engine. A script
# that does not compile has no base script to ask what it extends, and the
# engine's global class list is built at import, so a `class_name` written since
# the last `--import` is missing from it and a real cascade reports as several
# unrelated failures. The index parses these files anyway, their failures being
# semantic rather than syntactic, and reads them as they are on disk.
#
# GDLintMemberTypes is deliberately not used here, though it answers the same
# question. It is the right source for resolving a member's declared type, where
# the script has to load for its members to be read at all, and the wrong one
# here, where the script by definition does not load.
#
# The index skips `res://addons` unless an addon is what is being analyzed, so a
# base class declared by an addon does not fold. Addon code is not the code under
# analysis, and the consequence is one extra finding rather than a wrong one.
func _report_load_failures(index: GDLintSourceIndex, broken: Array) -> Array:
	var declared := index.declared_classes()
	var caused_by := {}
	for path: String in broken:
		var base := index.file_extends(path)
		if base.is_empty():
			continue
		var base_path := ""
		if declared.has(base):
			base_path = declared[base]
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
	for path: String in broken:
		if caused_by.has(path):
			continue
		var message := "Script fails to compile (see the parse error above)"
		if dependents.has(path):
			message += "; %d dependent script(s) fail because of it" % dependents[path]
		issues.append(IssueClass.create(
			path, 1, IssueClass.Severity.CRITICAL, CHECK_LOAD_FAILED, message))
	return issues


func _check_file(index: GDLintSourceIndex, path: String, script: Script) -> Array:
	# Only the script's OWN methods count here: ClassDB reports these hooks as
	# virtuals on Object, so testing the merged member set would skip everything.
	for method in script.get_script_method_list():
		if DYNAMIC_PROPERTY_HOOKS.has(method.name):
			return []

	var entry := index.file_records(path)
	if entry.is_empty() or entry.get("parse_error", false):
		return []

	if _respect_ignores:
		_ignore_handler.initialize(_read_lines(path))

	_fold.clear()
	var root := _types.of_script(script)
	var root_label := _script_label(path, script)
	var locals := _locals_by_scope(entry)

	var issues: Array = []
	for chain: Dictionary in entry.member_chains:
		var issue = _check_chain(path, chain, root, root_label, locals)
		if issue != null:
			issues.append(issue)

	# `if predicate:` -- a bare method name used as a truth test. The index marks
	# any expression tested for truthiness, including operands of and/or/not.
	for reference: Dictionary in entry.references:
		if String(reference.get("context", "")) != "condition":
			continue
		if bool(reference.get("is_call", false)):
			continue
		var name := String(reference.get("name", ""))
		if not root.methods.has(name):
			continue
		if _is_shadowed(locals, String(reference.get("scope", "")), name):
			continue
		var issue = _method_not_called(path, GDLintSourceIndex.line_of(reference), name)
		if issue != null:
			issues.append(issue)

	issues.append_array(_fold.issues(path, entry))

	if _respect_ignores:
		_ignore_handler.clear()
	return issues


func _locals_by_scope(entry: Dictionary) -> Dictionary:
	var locals := {}
	for declaration: Dictionary in entry.declarations:
		var kind := String(declaration.get("kind", ""))
		if kind != "variable" and kind != "parameter" and kind != "constant":
			continue
		var scope := String(declaration.get("scope", ""))
		if scope.is_empty():
			continue  # a class-level member, not a local
		if not locals.has(scope):
			locals[scope] = {}
		locals[scope][String(declaration.get("name", ""))] = true
	return locals


# True when `name` is bound as a local anywhere up the scope chain. Scopes are
# dotted, so a name bound in `Inner._ready` also covers records written there.
func _is_shadowed(locals: Dictionary, scope: String, name: String) -> bool:
	var current := scope
	while true:
		if locals.has(current) and locals[current].has(name):
			return true
		var cut := current.rfind(".")
		if cut == -1:
			return false
		current = current.substr(0, cut)
	return false


func _check_chain(path: String, chain: Dictionary, root: Dictionary, root_label: String, locals: Dictionary):
	var segments: Array = chain.get("segments", [])
	if segments.is_empty():
		return null

	var line := GDLintSourceIndex.line_of(chain)
	var scope := String(chain.get("scope", ""))
	var in_condition := String(chain.get("context", "")) == "condition"

	# Stop where hop-by-hop resolution stops being valid. `self.get_thing().field`
	# says nothing about the call's return type, and `$Clock.text` is not a member
	# of the enclosing script.
	var names: Array = []
	var last_is_call := false
	for segment: Dictionary in segments:
		var kind := String(segment.get("kind", ""))
		if kind != "self" and kind != "identifier" and kind != "call":
			break
		names.append(String(segment.get("name", "")))
		last_is_call = kind == "call"
		if kind == "call":
			break  # the return type is unknown; nothing past this resolves

	if names.is_empty():
		return null

	var start := 0
	if names[0] == "self":
		start = 1
	elif _is_shadowed(locals, scope, names[0]) or not root.names.has(names[0]):
		return null  # a local, or not ours to resolve

	var current := root
	var owner_label := root_label
	var last := names.size() - 1

	for index in range(start, names.size()):
		var name: String = names[index]

		if not current.names.has(name):
			if _respect_ignores and _ignore_handler.should_ignore(line, CHECK_UNKNOWN_MEMBER):
				return null
			# Read through a member's declared type rather than off the script's
			# own members. Held back: the same variable failing repeatedly is one
			# wrong annotation, not one bug per line. Decided by GDLintWideReadFold.
			if index > start:
				_fold.defer(line, name, names.slice(start, index), owner_label,
					_types.closest_member(name, current.names))
				return null
			return _unknown_member(path, line, name, owner_label, current)

		# A method used as a condition without being called. The reference is a
		# Callable, which is always truthy, so the branch never branches.
		if index == last and in_condition and not last_is_call and current.methods.has(name):
			return _method_not_called(path, line, name)

		# <signal>.emit(...) -- a signal has no type to step into, so the walk
		# would otherwise stop before reaching .emit.
		if index == last - 1 and names[last] == "emit" and current.signals.has(name):
			var given: int = chain.get("arguments", []).size()
			return _check_signal_arity(path, line, name, given, current.signals[name])

		var next_class: String = current.types.get(name, "")
		if next_class.is_empty():
			return null
		var next := _types.of_class(next_class)
		if next.names.is_empty():
			return null
		current = next
		owner_label = next_class

	return null


func _unknown_member(path: String, line: int, member: String, owner_label: String,
		current: Dictionary):
	var message := "'%s' is not a member of %s" % [member, owner_label]
	var suggestion := _types.closest_member(member, current.names)
	if not suggestion.is_empty():
		message += " (did you mean '%s'?)" % suggestion
	return IssueClass.create(
		path, line, IssueClass.Severity.CRITICAL, CHECK_UNKNOWN_MEMBER, message)


func _method_not_called(path: String, line: int, name: String):
	if _respect_ignores and _ignore_handler.should_ignore(line, CHECK_METHOD_NOT_CALLED):
		return null
	return IssueClass.create(
		path, line, IssueClass.Severity.CRITICAL, CHECK_METHOD_NOT_CALLED,
		"'%s' is a method used as a condition without being called; " % name
		+ "the reference is always true (did you mean '%s()'?)" % name)


# Signals have no default arguments, so the expected count is exact.
func _check_signal_arity(path: String, line: int, signal_name: String, given: int, expected: int):
	if given == expected:
		return null
	if _respect_ignores and _ignore_handler.should_ignore(line, CHECK_ARGUMENT_COUNT):
		return null
	return IssueClass.create(
		path, line, IssueClass.Severity.CRITICAL, CHECK_ARGUMENT_COUNT,
		"Signal '%s' emitted with %d argument(s), expected %d" % [signal_name, given, expected])


# Members of a loaded script: its own plus, already merged by the engine, those
# inherited from base scripts, plus the native class the chain bottoms out in.
func _script_label(path: String, script: Script) -> String:
	var global_name := script.get_global_name()
	if not String(global_name).is_empty():
		return String(global_name)
	return path.get_file()


func _read_lines(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var content := file.get_as_text()
	file.close()
	return Array(content.split("\n"))
