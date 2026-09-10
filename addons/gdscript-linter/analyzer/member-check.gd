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
## Five findings, all CRITICAL:
##   script-load-failed    - the script does not compile, so nothing in it can be
##                           checked (Godot prints the parse error, on stderr)
##   unknown-member        - a name in a chain is not a member of the type it is
##                           read from
##   wrong-argument-count  - a signal is emitted with the wrong argument count
##   wrong-parameter-count - a signal is connected to a method that cannot take
##                           what it emits
##   method-not-called     - a method is used as a condition without being called
##
## GDScript verifies none of these at parse time. Property access through `self`
## is resolved at runtime, property access on typed object variables is not
## verified either, signal arity is checked neither at the emit nor at the
## connect, and a bare method reference in a condition is a Callable, which is
## always true.
##
## Method call arity is deliberately absent: Godot's own parser rejects those, so
## a bad call surfaces here as script-load-failed instead.

const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")

const CHECK_LOAD_FAILED := "script-load-failed"
const CHECK_UNKNOWN_MEMBER := "unknown-member"
const CHECK_ARGUMENT_COUNT := "wrong-argument-count"
const CHECK_PARAMETER_COUNT := "wrong-parameter-count"
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
# The callable handed to each `.connect(...)` in the current file, keyed by the
# source range of that argument. Built per file by _connect_callables_of.
var _connect_callables := { }


## Run over the given res:// script paths, returning an Array of Issue.
func run(index: GDLintSourceIndex, file_paths: Array, p_respect_ignores: bool = true) -> Array:
	_respect_ignores = p_respect_ignores
	_types.build_class_map()

	var scripts := { } # path -> Script, null when it failed to compile
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
	var caused_by := { }
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

	var dependents := { }
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
		issues.append(
			IssueClass.create(path, 1, IssueClass.Severity.CRITICAL, CHECK_LOAD_FAILED, message)
		)
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
	_connect_callables = _connect_callables_of(entry)
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
	var locals := { }
	for declaration: Dictionary in entry.declarations:
		var kind := String(declaration.get("kind", ""))
		if kind != "variable" and kind != "parameter" and kind != "constant":
			continue
		var scope := String(declaration.get("scope", ""))
		if scope.is_empty():
			continue # a class-level member, not a local
		if not locals.has(scope):
			locals[scope] = { }
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


func _check_chain(
	path: String,
	chain: Dictionary,
	root: Dictionary,
	root_label: String,
	locals: Dictionary,
):
	var segments: Array = chain.get("segments", [])
	if segments.is_empty():
		return null

	var line := GDLintSourceIndex.line_of(chain)
	var scope := String(chain.get("scope", ""))
	var in_condition := String(chain.get("context", "")) == "condition"

	# Stop where hop-by-hop resolution stops being valid. `self.get_thing().field`
	# says nothing about the call's return type, and `$Clock.text` is not a member
	# of the enclosing script. A subscript on a named member, `self.slots[i]`,
	# does resolve when the member is a typed container; one on anything else
	# carries no name and stops the walk.
	var names: Array = []
	var subscripted: Array = []
	var last_is_call := false
	for segment: Dictionary in segments:
		var kind := String(segment.get("kind", ""))
		if kind != "self" and kind != "identifier" and kind != "call" and kind != "subscript":
			break
		if not segment.has("name"):
			break
		names.append(String(segment.get("name", "")))
		subscripted.append(kind == "subscript")
		last_is_call = kind == "call"
		if kind == "call":
			break # the return type is unknown; nothing past this resolves

	if names.is_empty():
		return null

	var start := 0
	if names[0] == "self":
		start = 1
	elif _is_shadowed(locals, scope, names[0]) or not root.names.has(names[0]):
		return null # a local, or not ours to resolve

	var current := root
	var owner_label := root_label
	var owner_class := root_label
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
				_fold.defer(
					line,
					name,
					names.slice(start, index),
					owner_label,
					owner_class,
					_types.closest_member(name, current.names),
				)
				return null
			return _unknown_member(path, line, name, owner_class, current)

		# A method used as a condition without being called. The reference is a
		# Callable, which is always truthy, so the branch never branches.
		if index == last and in_condition and not last_is_call and current.methods.has(name):
			return _method_not_called(path, line, name)

		# <signal>.emit(...) -- a signal has no type to step into, so the walk
		# would otherwise stop before reaching .emit.
		if index == last - 1 and names[last] == "emit" and current.signals.has(name):
			var given: int = chain.get("arguments", []).size()
			return _check_signal_arity(path, line, name, given, current.signals[name])

		# <signal>.connect(<callable>) -- the other end of the same contract.
		if index == last - 1 and names[last] == "connect" and current.signals.has(name):
			return _check_handler_arity(
				path,
				line,
				name,
				current.signals[name],
				chain,
				root,
				locals,
			)

		var declared := _declared_type(current, name, subscripted[index])
		if declared.is_empty():
			return null
		var next := _types.of_class(declared.class)
		if next.names.is_empty():
			return null
		current = next
		owner_label = declared.label
		owner_class = declared.class

	return null


# What a hop reads from next: the declared type of a plain member, or the element
# type of a subscripted one. Empty when the declaration does not say.
func _declared_type(current: Dictionary, name: String, is_subscript: bool) -> Dictionary:
	if is_subscript:
		return current.elements.get(name, { })
	var declared: String = current.types.get(name, "")
	if declared.is_empty():
		return { }
	return { "class": declared, "label": declared }


func _unknown_member(
	path: String,
	line: int,
	member: String,
	owner_label: String,
	current: Dictionary,
):
	var message := "'%s' is not a member of %s" % [member, owner_label]
	var suggestion := _types.closest_member(member, current.names)
	if not suggestion.is_empty():
		message += " (did you mean '%s'?)" % suggestion
	return IssueClass.create(
		path,
		line,
		IssueClass.Severity.CRITICAL,
		CHECK_UNKNOWN_MEMBER,
		message,
	)


func _method_not_called(path: String, line: int, name: String):
	if _respect_ignores and _ignore_handler.should_ignore(line, CHECK_METHOD_NOT_CALLED):
		return null
	return IssueClass.create(
		path,
		line,
		IssueClass.Severity.CRITICAL,
		CHECK_METHOD_NOT_CALLED,
		"'%s' is a method used as a condition without being called; " % name
		+ "the reference is always true (did you mean '%s()'?)" % name,
	)


# Signals have no default arguments, so the expected count is exact.
func _check_signal_arity(path: String, line: int, signal_name: String, given: int, expected: int):
	if given == expected:
		return null
	if _respect_ignores and _ignore_handler.should_ignore(line, CHECK_ARGUMENT_COUNT):
		return null
	return IssueClass.create(
		path,
		line,
		IssueClass.Severity.CRITICAL,
		CHECK_ARGUMENT_COUNT,
		"Signal '%s' emitted with %d argument(s), expected %d" % [signal_name, given, expected],
	)


# A signal calls its handler with exactly what it emits, plus whatever `.bind`
# appended and minus whatever `.unbind` dropped. A GDScript method called with
# more arguments than it declares, or fewer than it requires, is a runtime error
# and the handler never runs. Godot checks this nowhere: not at parse, not at
# connect, only when the signal fires.
#
# The callable is resolved from the index record sitting in the argument slot:
# `self._on_x`, unqualified `_on_x`, a method reached through a typed member such
# as `self.player.commit`, each optionally followed by one `.bind(...)` or
# `.unbind(n)`. Anything else (a lambda, `Callable(self, "name")`, a local, a
# call that returns a Callable) is not a method this can look up, and gives no
# verdict.
func _check_handler_arity(
	path: String,
	line: int,
	signal_name: String,
	emitted: int,
	chain: Dictionary,
	root: Dictionary,
	locals: Dictionary,
):
	var arguments: Array = chain.get("arguments", [])
	if arguments.is_empty():
		return null
	var record: Dictionary = _connect_callables.get(_range_key(arguments[0]), { })
	if record.is_empty():
		return null

	var handler := _resolve_handler(record, root, locals)
	if handler.is_empty() or bool(handler.arity.vararg):
		return null

	var given: int = emitted + int(handler.bound) - int(handler.unbound)
	var required := int(handler.arity.required)
	var total := int(handler.arity.total)
	if given >= required and given <= total:
		return null
	if _respect_ignores and _ignore_handler.should_ignore(line, CHECK_PARAMETER_COUNT):
		return null

	var takes := str(required) if required == total else "%d to %d" % [required, total]
	var message := (
		"Handler '%s' takes %s parameter(s), but signal '%s' calls it with %d"
		% [handler.name, takes, signal_name, given]
	)
	if int(handler.bound) > 0:
		message += " (%d emitted + %d bound)" % [emitted, int(handler.bound)]
	elif int(handler.unbound) > 0:
		message += " (%d emitted - %d unbound)" % [emitted, int(handler.unbound)]
	return IssueClass.create(
		path,
		line,
		IssueClass.Severity.CRITICAL,
		CHECK_PARAMETER_COUNT,
		message,
	)


# The callable in every `.connect(...)` argument slot of a file, keyed by its
# range. The index emits a nested record for the argument itself, tagged with
# the callee it is an argument of, so the connect chain and the callable it was
# handed are joined by position rather than by re-parsing the argument text.
func _connect_callables_of(entry: Dictionary) -> Dictionary:
	var callables := { }
	for bucket in ["member_chains", "references"]:
		for record: Dictionary in entry[bucket]:
			var argument_of: Dictionary = record.get("argument_of", { })
			if String(argument_of.get("callee", "")) != "connect":
				continue
			if int(argument_of.get("index", -1)) != 0:
				continue
			callables[_range_key(record)] = record
	return callables


static func _range_key(record: Dictionary) -> String:
	var range: Dictionary = record.get("range", { })
	return "%s:%s" % [range.get("start_byte", -1), range.get("end_byte", -1)]


# The method a connect argument names, with its arity and how many arguments a
# trailing `.bind(...)` adds or `.unbind(n)` removes. Empty when the argument is
# not a method this can resolve.
func _resolve_handler(record: Dictionary, root: Dictionary, locals: Dictionary) -> Dictionary:
	var scope := String(record.get("scope", ""))
	var names: Array = []
	var subscripted: Array = []
	var trailing_call := ""

	if String(record.get("record", "")) == "reference":
		if bool(record.get("is_call", false)):
			return { } # a call that returns a Callable; nothing to look up
		names.append(String(record.get("name", "")))
		subscripted.append(false)
	else:
		var segments: Array = record.get("segments", [])
		for position in range(segments.size()):
			var segment: Dictionary = segments[position]
			var kind := String(segment.get("kind", ""))
			if kind == "call":
				# Only a trailing bind/unbind is understood, and the chain's
				# arguments belong to its last call, so the call must be last.
				if position != segments.size() - 1:
					return { }
				trailing_call = String(segment.get("name", ""))
				break
			if kind != "self" and kind != "identifier" and kind != "subscript":
				return { }
			if not segment.has("name"):
				return { }
			names.append(String(segment.get("name", "")))
			subscripted.append(kind == "subscript")

	var bound := 0
	var unbound := 0
	var call_arguments: Array = record.get("arguments", [])
	match trailing_call:
		"":
			pass
		"bind":
			bound = call_arguments.size()
		"unbind":
			if call_arguments.size() != 1:
				return { }
			var count := String(call_arguments[0].get("text", ""))
			if not count.is_valid_int():
				return { }
			unbound = int(count)
		_:
			return { }

	var start := 0
	if not names.is_empty() and names[0] == "self":
		start = 1
	elif names.is_empty() or _is_shadowed(locals, scope, names[0]) or not root.names.has(names[0]):
		return { }
	if start >= names.size():
		return { }

	var current := root
	for index in range(start, names.size()):
		var name: String = names[index]
		if index == names.size() - 1:
			if subscripted[index] or not current.methods.has(name):
				return { }
			return {
				"name": name,
				"arity": current.methods[name],
				"bound": bound,
				"unbound": unbound,
			}
		var declared := _declared_type(current, name, subscripted[index])
		if declared.is_empty():
			return { }
		current = _types.of_class(declared.class)
		if current.names.is_empty():
			return { }
	return { }


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
