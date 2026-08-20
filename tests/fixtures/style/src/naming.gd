class_name badly_Named_Class
extends Node

## Naming and text checks that need no threshold set.
##
## Reported: this class_name is not PascalCase, and BadlyNamedFunction below is
## not snake_case.


func BadlyNamedFunction() -> void:
	print("a")


func properly_named_function() -> void:
	print("b")
