extends Node

## A body of nothing but `pass` is an empty function. A local nothing reads is an
## unused variable.


func empty_stub() -> void:
	pass


func has_an_unused_local() -> void:
	var used := 1
	var never_read := 2
	print(used)


func everything_used() -> void:
	var counted := 3
	print(counted)
