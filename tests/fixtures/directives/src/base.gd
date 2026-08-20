#@Sealed
class_name SealedBase
extends Node

## A class marked #@Sealed says nothing may extend it. The marker has to sit on
## the line directly above the class_name.


func do_something() -> void:
	print("a")
