# GDScript Linter - Scene index
# https://poplava.itch.io
class_name GDLintSceneIndex
extends RefCounted
## Every scene in the project, as the tree it instantiates to.
##
## Read through the engine's SceneState rather than by parsing .tscn text. The
## engine already knows what a scene file means: which nodes an inherited scene
## takes from its base, which nodes an instanced sub-scene brings with it, which
## instance is a placeholder that loads nothing until asked, and which script
## sits on which node. Asking it keeps this the engine's answer, and it covers
## binary .scn files, which text parsing would not.
##
## A relative path here is what `$` resolves against: "" is the scene root and
## "Panel/Box" is two levels below it.

enum Verdict {
	FOUND,
	MISSING,
	UNKNOWN,
}

const SCENE_EXTENSIONS := ["tscn", "scn"]

## Scenes instancing scenes instancing scenes. Godot refuses a cycle, so this
## only bounds a pathological project.
const INSTANCE_DEPTH_LIMIT := 32

## res:// scene path -> { "nodes": { relative path: node }, "unique": { name: relative path } }
##
## Each node is { "script": res:// path or "", "placeholder": bool,
## "from_instance": bool, "unique": bool }. `from_instance` marks a node an
## instanced sub-scene brought with it: it is owned by that sub-scene's root, so
## its unique name is not visible from the outer scene.
var scenes := { }


## Read every scene under res://. Addon scenes are skipped unless an addon is
## what is being analyzed, the same rule the other checks apply.
func build(include_addons: bool) -> void:
	scenes.clear()
	for path: String in _collect_scene_files("res://"):
		if not include_addons and _is_addon_path(path):
			continue
		var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
		if packed == null:
			continue # a scene that does not load has no tree to check against
		var nodes := _tree_of(packed.get_state(), 0)
		scenes[path] = { "nodes": nodes, "unique": _unique_names(nodes) }


## Every (scene, node) that carries a script, as
## { "scene": res:// path, "node": relative path, "script": res:// path }.
func attachments() -> Array:
	var found: Array = []
	for scene_path: String in scenes:
		var nodes: Dictionary = scenes[scene_path]["nodes"]
		for node_path: String in nodes:
			var script := String(nodes[node_path]["script"])
			if script.is_empty():
				continue
			found.append({ "scene": scene_path, "node": node_path, "script": script })
	return found


## Resolve `written` the way get_node would from the node at `from`.
##
## UNKNOWN is for paths this scene cannot answer: an absolute path, a `..` that
## climbs out of the scene, or a path that enters an instance placeholder,
## whose children do not exist until something loads them.
func resolve(scene_path: String, from: String, written: String) -> Verdict:
	if not scenes.has(scene_path):
		return Verdict.UNKNOWN
	var nodes: Dictionary = scenes[scene_path]["nodes"]
	var unique: Dictionary = scenes[scene_path]["unique"]
	if written.begins_with("/"):
		return Verdict.UNKNOWN

	var current := from
	for segment: String in written.split("/"):
		if segment.is_empty() or segment == ".":
			continue
		if segment == "..":
			if current.is_empty():
				return Verdict.UNKNOWN
			current = current.get_base_dir()
			continue
		if segment.begins_with("%"):
			var name := segment.substr(1)
			if not unique.has(name):
				return Verdict.MISSING
			current = String(unique[name])
			continue
		if nodes.has(current) and bool(nodes[current]["placeholder"]):
			return Verdict.UNKNOWN
		current = segment if current.is_empty() else current + "/" + segment
		if not nodes.has(current):
			return Verdict.MISSING
	return Verdict.FOUND


## Relative paths of every node in the scene whose name is `name`, for saying
## where the node the path was probably meant for actually is.
func nodes_named(scene_path: String, name: String) -> Array:
	var found: Array = []
	if not scenes.has(scene_path):
		return found
	for node_path: String in scenes[scene_path]["nodes"]:
		if node_path.get_file() == name:
			found.append(node_path)
	found.sort()
	return found


func is_unique(scene_path: String, node_path: String) -> bool:
	if not scenes.has(scene_path):
		return false
	var nodes: Dictionary = scenes[scene_path]["nodes"]
	return nodes.has(node_path) and bool(nodes[node_path]["unique"]) \
			and not bool(nodes[node_path]["from_instance"])


# An inherited scene starts as its base and overlays its own nodes on top,
# which is also the order the engine builds it in.
func _tree_of(state: SceneState, depth: int) -> Dictionary:
	var nodes := { }
	if depth > INSTANCE_DEPTH_LIMIT:
		return nodes
	var base := state.get_base_scene_state()
	if base != null:
		nodes = _tree_of(base, depth + 1)

	for i in state.get_node_count():
		var path := _relative(state.get_node_path(i))
		if state.is_node_instance_placeholder(i):
			_node_at(nodes, path)["placeholder"] = true
		else:
			var instance := state.get_node_instance(i)
			# The root of an inherited scene reports its base as an instance,
			# and the base was merged above.
			if instance != null and not (i == 0 and base != null):
				_merge_instance(nodes, path, _tree_of(instance.get_state(), depth + 1))

		var node := _node_at(nodes, path)
		for p in state.get_node_property_count(i):
			var property := state.get_node_property_name(i, p)
			if property == "script":
				var value = state.get_node_property_value(i, p)
				node["script"] = value.resource_path if value is Script else ""
			elif property == "unique_name_in_owner":
				node["unique"] = bool(state.get_node_property_value(i, p))
	return nodes


func _node_at(nodes: Dictionary, path: String) -> Dictionary:
	if not nodes.has(path):
		nodes[path] = {
			"script": "",
			"placeholder": false,
			"from_instance": false,
			"unique": false,
		}
	return nodes[path]


# The instanced node itself belongs to the outer scene. Only what it brings
# with it is internal to the sub-scene.
func _merge_instance(nodes: Dictionary, prefix: String, sub: Dictionary) -> void:
	for key: String in sub:
		var entry: Dictionary = sub[key].duplicate()
		if key.is_empty():
			entry["unique"] = false
			nodes[prefix] = entry
			continue
		entry["from_instance"] = true
		nodes[prefix + "/" + key] = entry


func _unique_names(nodes: Dictionary) -> Dictionary:
	var unique := { }
	for path: String in nodes:
		if bool(nodes[path]["unique"]) and not bool(nodes[path]["from_instance"]):
			unique[path.get_file()] = path
	return unique


# SceneState spells the root "." and everything below it "./Panel/Box".
func _relative(node_path: NodePath) -> String:
	var written := String(node_path)
	if written == ".":
		return ""
	return written.trim_prefix("./")


func _is_addon_path(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	if normalized.begins_with("res://"):
		normalized = normalized.substr(6)
	return normalized.begins_with("addons/")


func _collect_scene_files(root: String) -> Array:
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
			elif SCENE_EXTENSIONS.has(entry.get_extension().to_lower()):
				found.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	found.sort()
	return found
