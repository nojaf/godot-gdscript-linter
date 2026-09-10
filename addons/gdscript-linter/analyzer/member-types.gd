# GDScript Linter - Member types
# https://poplava.itch.io
class_name GDLintMemberTypes
extends RefCounted
## What the engine says a type contains.
##
## Every member of a class including inherited ones, the declared type of each,
## signal arity, method arity, and which project class a name refers to. None of
## it is known by line number, which is the other half and comes from
## GDLintSourceIndex.
##
## `methods` maps each name to its arity: `required` parameters, `total`
## parameters including those with defaults, and `vararg` when the method takes
## any number. That is what decides whether a signal can call it.
##
## `elements` maps each typed container to what it holds: `class` is the element
## type of an `Array[T]` or the value type of a `Dictionary[K, V]`, and `label`
## is the declaration as written, for messages. A subscript steps through it the
## way a plain member steps through `types`.
##
## Answers are cached per type. Resolving a script class loads it, and loading a
## script runs its @tool static initializers, so this asks for as few as it can:
## ancestry is walked over the global class list, which needs no loading at all.

## Stops a cycle in the class list from hanging the ancestry walk.
const ANCESTRY_LIMIT := 50

## Member sets, keyed by type name. A native type is keyed "native:<name>" so it
## cannot collide with a script class of the same name.
var _cache := { }
## class_name -> res:// path, for classes declared by project scripts.
var _paths := { }
## class_name -> the base it declares, for walking ancestry without loading.
var _bases := { }


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
	var names := { }
	var types := { }
	var elements := { }
	var signals := { }
	var methods := { }

	for prop in script.get_script_property_list():
		# Drops the per-file category rows the property list interleaves.
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			names[prop.name] = true
			_record_type(types, elements, prop)
	for method in script.get_script_method_list():
		names[method.name] = true
		methods[method.name] = _arity_of(method)
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
		elements.merge(native_members.elements)
		signals.merge(native_members.signals)
		methods.merge(native_members.methods)

	return _members(names, types, elements, signals, methods)


func of_class(class_name_str: String) -> Dictionary:
	if _cache.has(class_name_str):
		return _cache[class_name_str]

	var resolved := _members({ }, { }, { }, { }, { })
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

	var names := { }
	var types := { }
	var elements := { }
	var signals := { }
	var methods := { }
	for prop in ClassDB.class_get_property_list(native):
		names[prop.name] = true
		_record_type(types, elements, prop)
	for method in ClassDB.class_get_method_list(native):
		names[method.name] = true
		methods[method.name] = _arity_of(method)
	for signal_info in ClassDB.class_get_signal_list(native):
		names[signal_info.name] = true
		signals[signal_info.name] = signal_info.args.size()
	for constant in ClassDB.class_get_integer_constant_list(native):
		names[constant] = true

	var resolved := _members(names, types, elements, signals, methods)
	_cache[cache_key] = resolved
	return resolved


static func _members(
	names: Dictionary,
	types: Dictionary,
	elements: Dictionary,
	signals: Dictionary,
	methods: Dictionary,
) -> Dictionary:
	return {
		"names": names,
		"types": types,
		"elements": elements,
		"signals": signals,
		"methods": methods,
	}


# The engine reports a method's parameters and, separately, the defaults for
# the trailing ones. Both the script and the ClassDB method lists use this shape.
func _arity_of(method: Dictionary) -> Dictionary:
	var total: int = method.get("args", []).size()
	var defaults: int = method.get("default_args", []).size()
	return {
		"required": total - defaults,
		"total": total,
		"vararg": bool(int(method.get("flags", 0)) & METHOD_FLAG_VARARG),
	}


func _record_type(types: Dictionary, elements: Dictionary, prop: Dictionary) -> void:
	var type: int = prop.get("type", TYPE_NIL)
	if type == TYPE_OBJECT:
		var declared := String(prop.get("class_name", ""))
		if not declared.is_empty():
			types[prop.name] = declared
	elif type == TYPE_ARRAY:
		var element := _element_class(prop)
		if not element.is_empty():
			elements[prop.name] = { "class": element, "label": "Array[%s]" % element }
	elif type == TYPE_DICTIONARY:
		var value := _element_class(prop)
		if not value.is_empty():
			var key := _decode_type(String(prop.get("hint_string", "")).get_slice(";", 0))
			elements[prop.name] = { "class": value, "label": "Dictionary[%s, %s]" % [key, value] }


# The element type of a typed container, or "" for an untyped one. The engine
# writes it into the hint string, and a `Dictionary[K, V]` carries both halves
# separated by `;`, of which the value is what a subscript yields.
func _element_class(prop: Dictionary) -> String:
	var hint: int = prop.get("hint", PROPERTY_HINT_NONE)
	var hint_string := String(prop.get("hint_string", ""))
	if hint == PROPERTY_HINT_ARRAY_TYPE or hint == PROPERTY_HINT_TYPE_STRING:
		return _decode_type(hint_string)
	if hint == PROPERTY_HINT_DICTIONARY_TYPE:
		return _decode_type(hint_string.get_slice(";", hint_string.count(";")))
	return ""


# A plain `var x: Array[Button]` says `Button`; an `@export` one says
# `24/34:Button`, which is `TYPE_OBJECT/PROPERTY_HINT_NODE_TYPE:Button`. Only an
# object element can have members, so any other leading type yields nothing, and
# a name that is not a class stops the walk downstream when it resolves to
# nothing.
func _decode_type(written: String) -> String:
	if not written.contains("/"):
		return written
	if int(written.get_slice("/", 0)) != TYPE_OBJECT:
		return ""
	return written.substr(written.find(":") + 1)


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
			return "" # two classes fit; naming either one would be a guess
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
	return (
		ClassDB.class_exists(current) and ClassDB.class_exists(ancestor)
		and ClassDB.is_parent_class(current, ancestor)
	)

# Names bound by a local, parameter or loop variable, keyed by the scope they are
# bound in. A chain rooted in one of these is skipped: the member of that name may
# not be what the line refers to.
