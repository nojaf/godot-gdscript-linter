extends Node

## Threshold checks, measured against limits.json rather than the defaults, so
## the cases can be short enough to read.
##
## This file is 30 lines, past the hard limit of 26, so its file-length finding
## is critical. complex.gd and god.gd sit between the soft 20 and the hard 26,
## so theirs are warnings: the same check, both branches.


func short_enough() -> void:
	print("a")
	print("b")


func too_long() -> void:
	print("1")
	print("2")
	print("3")
	print("4")
	print("5")
	print("6")
	print("7")


func nested_too_deep(a: int, b: int, c: int) -> void:
	if a > 0:
		if b > 0:
			if c > 0:
				print("three levels, limit is two")
