extends Node

## A gdlint:ignore-function directive must suppress the function it names, and
## only that one.
##
## Upstream this is inverted for the first two pairs. The range is found by
## scanning for a line starting with `func `, so an annotated or `static`
## declaration is skipped, the search lands on the next plain function, and the
## directive silences a function it never named while reporting the one it did.
##
## Nothing closes a range but the next plain `func`, so a directive on the last
## annotated function in a file runs to the end of it.


# gdlint:ignore-function:print-statement
@rpc("any_peer") func annotated() -> void:
	print("suppressed: the directive names this one")


func after_annotated() -> void:
	print("reported: no directive covers this")


# gdlint:ignore-function:print-statement
static func modified() -> void:
	print("suppressed: directives bind above static too")


func after_static() -> void:
	print("reported: no directive covers this either")


# gdlint:ignore-function:print-statement
func plain() -> void:
	print("suppressed: the case that always worked")


func last_one() -> void:
	print("reported: nothing closes a range but the next plain func")
