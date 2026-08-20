extends Node2D

## Godot calls methods by name from places that contain no code at all. These
## two are referenced only from scene data, one text and one binary, and both
## must count as alive.
##
## `never_wired_at_all` is the control. It sits in the same script, in the same
## scene, and is named by nothing: if the scan of those files ever stops
## finding anything, this file still reports one function and the fixture keeps
## passing on the strength of it. That is why the control is here.

signal pressed


func _on_pressed_from_editor() -> void:
	print("wired in the .tscn")


func _on_pressed_from_binary() -> void:
	print("wired in the .scn")


func never_wired_at_all() -> void:
	print("nothing names this one")
