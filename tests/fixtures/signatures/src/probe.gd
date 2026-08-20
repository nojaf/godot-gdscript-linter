extends Node

## A declaration does not have to fit on one line, and the checks used to read
## only the first one. Every function here is written twice, on one line and
## then wrapped, and the two halves must report the same thing.
##
## Reading the first line alone gets all three of these wrong:
##   the `->` sits on the closing line, so a typed function looks untyped
##   the `(` never closes, so the parameter list measures as empty
##   which means a wrapped function can never be reported as having too many


func typed_flat() -> void:
	print("a")


func typed_wrapped(
	first: int,
	second: int
) -> void:
	print(first, second)


func untyped_flat():
	print("b")


func untyped_wrapped(
	first: int
):
	print(first)


func many_flat(a: int, b: int, c: int, d: int, e: int, f: int) -> void:
	print(a, b, c, d, e, f)


func many_wrapped(
	a: int,
	b: int,
	c: int,
	d: int,
	e: int,
	f: int
) -> void:
	print(a, b, c, d, e, f)


func unused_flat(used: int, never_flat: int) -> void:
	print(used)


func unused_wrapped(
	used: int,
	never_wrapped: int
) -> void:
	print(used)
