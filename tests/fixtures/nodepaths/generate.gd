extends SceneTree


## Writes the scenes the node-path check resolves against, so Godot serialises
## them rather than anyone hand-authoring the format.
##
## Three scenes. `sub.tscn` is a small scene with its own script. `base.tscn`
## instances it twice, once as a normal instance and once as a placeholder, and
## carries a unique-named node and a script on a non-root node. `child.tscn`
## inherits `base.tscn`, swaps the root script for a subclass, and adds a node
## of its own.
##
## The inherited scene is the one file written as text. Marking a packed root as
## inheriting another scene is editor-only and not exposed to scripts, so the
## engine cannot be asked to write it; the shape is the same one the editor
## saves for "New Inherited Scene".
func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scenes"))
	_write_sub()
	_write_base()
	_write_child()
	quit()


func _write_sub() -> void:
	var root := Node.new()
	root.name = "Sub"
	root.set_script(load("res://src/inner.gd"))
	_add(root, root, Node.new(), "Inner")
	_save(root, "res://scenes/sub.tscn")


func _write_base() -> void:
	var root := Node2D.new()
	root.name = "Base"
	root.set_script(load("res://src/base.gd"))

	var panel := _add(root, root, CanvasLayer.new(), "Panel")
	var box := _add(root, panel, VBoxContainer.new(), "Box")
	box.set_script(load("res://src/deep.gd"))
	_add(root, box, Button.new(), "Button")
	var facts := _add(root, panel, Label.new(), "Facts")
	facts.unique_name_in_owner = true

	var sub: PackedScene = load("res://scenes/sub.tscn")
	_add(root, root, sub.instantiate(), "Sub")
	var lazy := _add(root, root, sub.instantiate(), "Lazy")
	lazy.set_scene_instance_load_placeholder(true)

	_save(root, "res://scenes/base.tscn")


func _write_child() -> void:
	var text := """[gd_scene format=3]

[ext_resource type="PackedScene" path="res://scenes/base.tscn" id="1"]
[ext_resource type="Script" path="res://src/child.gd" id="2"]

[node name="Base" instance=ExtResource("1")]
script = ExtResource("2")

[node name="OnlyInChild" type="Node" parent="."]
"""
	var file := FileAccess.open("res://scenes/child.tscn", FileAccess.WRITE)
	assert(file != null, "could not write child.tscn")
	file.store_string(text)
	file.close()


func _add(owner: Node, parent: Node, node: Node, name: String) -> Node:
	node.name = name
	parent.add_child(node)
	node.owner = owner
	return node


func _save(root: Node, to: String) -> void:
	var packed := PackedScene.new()
	assert(packed.pack(root) == OK, "could not pack %s" % to)
	assert(ResourceSaver.save(packed, to) == OK, "could not save %s" % to)
	root.free()
