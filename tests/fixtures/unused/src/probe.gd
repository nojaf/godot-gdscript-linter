extends Node

## Functions nothing in the project references.
##
## What keeps one alive is deliberately narrow. An occurrence in code counts. A
## string counts only where the string names a method: an argument to call,
## connect, Callable and their siblings. A string anywhere else is prose, so
## print("all done") must not keep all_done() alive.
##
## Two kinds are never reported. Engine virtuals are identified by asking
## ClassDB what the native base class declares, so _ready is not dead code.
## A body of nothing but `pass` is an intentional stub, left to empty-function.


func _ready() -> void:
	called_directly()
	self.called_through_self()
	self.call("called_by_string")
	self.call_deferred("called_deferred_by_string")
	var handler := Callable(self, "called_through_callable")
	handler.call()
	if self.has_method("called_by_has_method"):
		print("present")
	self.rpc("called_by_rpc")
	print("all_done")


func _process(_delta: float) -> void:
	pass


func called_directly() -> void:
	print("a")


func called_through_self() -> void:
	print("b")


func called_by_string() -> void:
	print("c")


func called_deferred_by_string() -> void:
	print("d")


func called_through_callable() -> void:
	print("e")


func called_by_has_method() -> void:
	print("g")


@rpc("any_peer")
func called_by_rpc() -> void:
	print("h")


func all_done() -> void:
	print("named only inside a string that is prose")


func never_mentioned_anywhere() -> void:
	print("f")


func stub_left_to_empty_function() -> void:
	pass
