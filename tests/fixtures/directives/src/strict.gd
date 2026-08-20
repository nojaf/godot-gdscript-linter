# gdlint:strict-file:file-length=12
extends Node

## A gdlint:strict directive sets a tighter limit than the global one, and its
## findings are critical rather than warnings.
##
## Three things about it are easy to get wrong, and each is pinned here.
##
## It tightens an existing check rather than being one of its own, so it only
## fires when that check is enabled. A run filtered down to strict-limit alone
## reports nothing.
##
## A strict-file directive is only read from the first ten lines of a file,
## which is why the one above sits at the very top rather than beside this
## explanation.
##
## And it is only consulted once the GLOBAL limit is already exceeded, because
## the override is read from inside the branch that had already decided to
## report. A value under the global limit and over the strict one is reported by
## neither, which is the case a stricter limit exists for.
## `under_global_over_strict` below pins that: it is silent today, and a fix
## would show up here as a new finding rather than as nothing changing.


# gdlint:strict-function:long-function=3
func over_the_strict_limit() -> void:
	print("1")
	print("2")
	print("3")
	print("4")
	print("5")
	print("6")
	print("7")
	print("8")
	print("9")
	print("10")


# gdlint:strict-function:long-function=2
func under_global_over_strict() -> void:
	print("a")
	print("b")


func under_both() -> void:
	print("c")
