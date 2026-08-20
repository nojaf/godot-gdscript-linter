extends SceneTree
## Writes the scene files this fixture needs, so Godot serialises them rather
## than anyone hand-authoring the format.
##
## Connections need CONNECT_PERSIST. A plain connect() is a runtime connection
## and PackedScene does not store it, which produces a scene with no
## [connection] line and a fixture that silently tests nothing.


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scenes"))
	_write("_on_pressed_from_editor", "res://scenes/wired.tscn")
	_write("_on_pressed_from_binary", "res://scenes/wired.scn")
	quit()


func _write(method: String, to: String) -> void:
	var root := Node2D.new()
	root.name = "Root"
	root.set_script(load("res://src/wired.gd"))
	root.connect("pressed", Callable(root, method), Object.CONNECT_PERSIST)

	var packed := PackedScene.new()
	assert(packed.pack(root) == OK, "could not pack %s" % to)
	assert(ResourceSaver.save(packed, to) == OK, "could not save %s" % to)
	root.free()
