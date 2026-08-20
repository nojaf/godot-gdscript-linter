extends Node

## A magic number is a literal in code. A digit inside a string is text, and a
## digit inside a comment is prose, and neither is a number the program uses.
##
## The check already meant to skip strings; it looked at the single character
## before the digit, which skips `"6 things"` and not `"%6.2f"`.

const MILLISECONDS_PER_SECOND := 1000.0
const LOG_LINES := 25


func formatting(seconds: float, line: String) -> String:
	# A width and a precision in a format specifier are not magic numbers.
	return "%6.2f  %s" % [seconds, line]


func clock(minutes: int, seconds: int) -> String:
	return "%02d:%02d" % [minutes, seconds]


func prose() -> void:
	print("saved 3 of 7 entries")


func paths() -> void:
	print("res://levels/level_3.tscn")


func indented_comment() -> void:
	# Tuned to 42 after playtesting, do not change without measuring.
	print("done")


func trailing_comment(speed: float) -> float:
	return speed * MILLISECONDS_PER_SECOND  # was 250 before playtesting


func quote_inside_a_string() -> void:
	print("he said \"pay 500 gold\" and left")


func real_magic(health: int) -> int:
	return health * 37


func real_magic_after_a_string(label: String) -> int:
	print(label)
	return 99


func allowed_by_config(scale: float) -> float:
	return scale * 2.0
