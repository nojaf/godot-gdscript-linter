extends Node


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
