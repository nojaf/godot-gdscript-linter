# GDScript Linter - Member types
# https://poplava.itch.io
class_name GDLintMemberTypes
extends RefCounted
## What the engine says a type contains.
##
## Every member of a class including inherited ones, the declared type of each,
## signal arity, and which project class a name refers to. None of it is known by
## line number, which is the other half and comes from GDLintSourceIndex.
##
## Answers are cached per type. Resolving a script class loads it, and loading a
## script runs its @tool static initializers, so this asks for as few as it can:
## ancestry is walked over the global class list, which needs no loading at all.

## Stops a cycle in the class list from hanging the ancestry walk.
const ANCESTRY_LIMIT := 50

## Member sets, keyed by type name. A native type is keyed "native:<name>" so it
## cannot collide with a script class of the same name.
var _cache := {}
## class_name -> res:// path, for classes declared by project scripts.
var _paths := {}
## class_name -> the base it declares, for walking ancestry without loading.
var _bases := {}


## Read the project's class list. Call once per run, before anything else here.
func build_class_map() -> void:
	_cache.clear()
	_paths.clear()
	_bases.clear()
	for entry in ProjectSettings.get_global_class_list():
		if entry.has("class") and entry.has("path"):
			_paths[String(entry["class"])] = String(entry["path"])
			_bases[String(entry["class"])] = String(entry.get("base", ""))


func of_script(script: Script) -> Dictionary:
	var names := {}
	var types := {}
	var signals := {}
	var methods := {}

	for prop in script.get_script_property_list():
		# Drops the per-file category rows the property list interleaves.
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			names[prop.name] = true
			_record_type(types, prop)
	for method in script.get_script_method_list():
		names[method.name] = true
		methods[method.name] = true
	for signal_info in script.get_script_signal_list():
		names[signal_info.name] = true
		signals[signal_info.name] = signal_info.args.size()
	for constant in script.get_script_constant_map().keys():
		names[String(constant)] = true

	var native := script.get_instance_base_type()
	if not native.is_empty():
		var native_members := of_native(native)
		names.merge(native_members.names)
		types.merge(native_members.types)
		signals.merge(native_members.signals)
		methods.merge(native_members.methods)

	return {"names": names, "types": types, "signals": signals, "methods": methods}


func of_class(class_name_str: String) -> Dictionary:
	if _cache.has(class_name_str):
		return _cache[class_name_str]

	var resolved := {"names": {}, "types": {}, "signals": {}, "methods": {}}
	if _paths.has(class_name_str):
		var script: Script = load(_paths[class_name_str]) as Script
		if script != null and not script.get_instance_base_type().is_empty():
			resolved = of_script(script)
	elif ClassDB.class_exists(class_name_str):
		resolved = of_native(class_name_str)

	_cache[class_name_str] = resolved
	return resolved


func of_native(native: String) -> Dictionary:
	var cache_key := "native:" + native
	if _cache.has(cache_key):
		return _cache[cache_key]

	var names := {}
	var types := {}
	var signals := {}
	var methods := {}
	for prop in ClassDB.class_get_property_list(native):
		names[prop.name] = true
		_record_type(types, prop)
	for method in ClassDB.class_get_method_list(native):
		names[method.name] = true
		methods[method.name] = true
	for signal_info in ClassDB.class_get_signal_list(native):
		names[signal_info.name] = true
		signals[signal_info.name] = signal_info.args.size()
	for constant in ClassDB.class_get_integer_constant_list(native):
		names[constant] = true

	var resolved := {"names": names, "types": types, "signals": signals, "methods": methods}
	_cache[cache_key] = resolved
	return resolved


func _record_type(types: Dictionary, prop: Dictionary) -> void:
	if prop.get("type", TYPE_NIL) != TYPE_OBJECT:
		return
	var declared := String(prop.get("class_name", ""))
	if not declared.is_empty():
		types[prop.name] = declared


# similarity() is 0.0..1.0; below the threshold a suggestion is noise, not help.
func closest_member(name: String, names: Dictionary) -> String:
	const MIN_SIMILARITY := 0.5
	var best := ""
	var best_score := MIN_SIMILARITY
	for candidate in names.keys():
		var score := String(candidate).similarity(name)
		if score > best_score:
			best_score = score
			best = String(candidate)
	return best


# Which class could the declaration have named? Every project class deriving from
# the declared type is scored by how many of the unknown members it has, and the
# answer is given only when exactly one has all of them. A genuine typo belongs
# to no class, so it goes unanswered rather than guessed at, and a tie names
# nothing for the same reason.
#
# Ancestry is walked over the class list, which costs no loading, so only classes
# that could actually fit are loaded for their member sets.
func type_with_all_members(owner_label: String, wanted: Array) -> String:
	if wanted.is_empty():
		return ""
	var best := ""
	for candidate: String in _paths:
		if candidate == owner_label or not _derives_from(candidate, owner_label):
			continue
		var members := of_class(candidate)
		if members.names.is_empty():
			continue
		if _members_present(members.names, wanted) < wanted.size():
			continue
		if not best.is_empty():
			return ""  # two classes fit; naming either one would be a guess
		best = candidate
	return best


func _members_present(names: Dictionary, wanted: Array) -> int:
	var hits := 0
	for name: String in wanted:
		if names.has(name):
			hits += 1
	return hits


func _derives_from(candidate: String, ancestor: String) -> bool:
	if ancestor.is_empty():
		return false
	var current := candidate
	var guard := 0
	while _bases.has(current) and guard < ANCESTRY_LIMIT:
		current = String(_bases[current])
		if current == ancestor:
			return true
		guard += 1
	return (ClassDB.class_exists(current) and ClassDB.class_exists(ancestor)
		and ClassDB.is_parent_class(current, ancestor))


# Names bound by a local, parameter or loop variable, keyed by the scope they are
# bound in. A chain rooted in one of these is skipped: the member of that name may
# not be what the line refers to.
