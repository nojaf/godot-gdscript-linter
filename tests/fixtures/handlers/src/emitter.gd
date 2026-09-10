class_name HandlerEmitter
extends Node

signal changed(previous: int, next: int)
signal fired


func act(index: int, extra: int) -> void:
	print(index, extra)


func act_optional(index: int, extra: int = 0) -> void:
	print(index, extra)
