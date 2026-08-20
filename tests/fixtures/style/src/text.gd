extends Node

## Text-level checks. Each line below is reported for exactly one reason, so a
## check that stops working takes its own line with it.

# TODO: this comment is what todo-comment looks for
#var commented_out := 1
#func commented_out_function() -> void:


func long_line() -> void:
	print("a line well past the default hundred and twenty character limit, padded out here with filler so that it definitely crosses it")


func non_ascii_without_the_attribute() -> void:
	# Not reported: ascii.gd opts in with #@ascii_only and this file does not.
	print("this arrow → is not ASCII")


func indented_commented_code() -> void:
	#var was_here := 1
	print("d")


func trailing_commented_code() -> void:
	var kept := 1  #var removed := 2
	print(kept)


func hash_inside_a_string() -> void:
	print("the docs mention #var x as an example")


func prose_is_not_code() -> void:
	# This sentence mentions a function and a variable without being either.
	print("c")
