# GDScript Linter - Unit tests
# https://poplava.itch.io
extends SceneTree
## Assertions over the pure functions, which need no fixture project and run in
## about a second.
##
## GDLintDeclarationSyntax is the whole of it for now, and it earns the coverage:
## it is the one file that touches eight of the existing checkers, and every
## regression in it has been silent. A declaration it fails to recognise is not
## reported as an error, it is simply never checked.

var _checked := 0
var _failures := 0


func _init() -> void:
	_declaration_syntax()
	_wrapped_declarations()
	_code_only()
	# Printed so the caller can tell "everything passed" from "nothing ran".
	# Godot exits 0 when a script fails to load at all, so an exit code is not
	# evidence that any of this executed.
	print("unit: %d assertions, %d failed" % [_checked, _failures])
	quit(1 if _failures > 0 else 0)


func _check(actual, expected, label: String) -> void:
	_checked += 1
	if actual != expected:
		_failures += 1
		printerr("  %s\n    expected: %s\n    actual:   %s" % [label, expected, actual])


func _declaration_syntax() -> void:
	var syntax := GDLintDeclarationSyntax

	# Every annotation and modifier form Godot accepts in front of a keyword.
	# `begins_with("func ")` misses all but the first, silently.
	_check(syntax.declares("func plain() -> void:", "func"), true, "plain func")
	_check(syntax.declares("static func modified() -> void:", "func"), true, "static func")
	_check(syntax.declares("@abstract func may_target() -> bool", "func"), true, "@abstract func")
	_check(syntax.declares("@rpc(\"any_peer\") func net() -> void:", "func"), true, "@rpc func")
	_check(syntax.declares("@warning_ignore(\"x\") static func both() -> void:", "func"), true,
		"annotation and modifier")
	_check(syntax.declares("@export var speed: int = 5", "var"), true, "@export var")
	_check(syntax.declares("@export_range(0, 10) var ranged := 5", "var"), true, "@export_range var")
	_check(syntax.declares("@warning_ignore(\"unused_signal\") signal done", "signal"), true,
		"annotated signal")
	_check(syntax.declares("@icon(\"res://i.svg\") class_name Foo extends Node", "class_name"), true,
		"annotated class_name")
	_check(syntax.declares("static var shared := 1", "var"), true, "static var")

	# Things that only look like declarations.
	_check(syntax.declares("print(\"func plain()\")", "func"), false, "func inside a string")
	_check(syntax.declares("var functional := 1", "func"), false, "var whose name starts with func")
	_check(syntax.declares("funcy()", "func"), false, "identifier starting with func")

	# after_keyword is what the checkers slice names and parameter lists from.
	# Taken off the raw line, the first parenthesis can belong to an annotation:
	# that is how `@rpc("any_peer") func f(a, b)` came to report one parameter,
	# and how a parameter named `""` came to exist.
	_check(syntax.after_keyword("@rpc(\"any_peer\") func net(a: int, b: int) -> void:", "func"),
		"net(a: int, b: int) -> void:", "after_keyword past an annotation")
	_check(syntax.after_keyword("static func modified(a: int) -> void:", "func"),
		"modified(a: int) -> void:", "after_keyword past a modifier")
	_check(syntax.after_keyword("func plain() -> void:", "func"), "plain() -> void:",
		"after_keyword with no prefix")
	_check(syntax.after_keyword("var x := 1", "func"), "", "after_keyword on the wrong keyword")

	# An annotation argument can contain anything, including the keyword itself
	# and unbalanced-looking text inside strings.
	_check(syntax.strip_prefixes("@export_file(\"res://a.tscn\") var path := \"\""),
		"var path := \"\"", "annotation argument holding a res:// path")
	_check(syntax.strip_prefixes("@warning_ignore(\"unused\", \"shadowed\") func f():"),
		"func f():", "annotation with several arguments")
	_check(syntax.strip_prefixes("@onready var label: Label = $Label"),
		"var label: Label = $Label", "@onready")
	_check(syntax.strip_prefixes("func f():"), "func f():", "nothing to strip")

	_check(syntax.declares_abstract("@abstract func may_target() -> bool"), true, "abstract")
	_check(syntax.declares_abstract("func may_target() -> bool:"), false, "not abstract")


func _wrapped_declarations() -> void:
	var syntax := GDLintDeclarationSyntax

	# The ordinary case is one line and must stay that way.
	var flat := ["func move(target: Vector2) -> void:", "\tpass"]
	_check(syntax.declaration_at(flat, 0).text, "func move(target: Vector2) -> void:", "flat text")
	_check(syntax.declaration_at(flat, 0).span, 1, "flat span")

	# Wrapped: the `->` is on the closing line and the parameters are in between.
	var wrapped := [
		"func move(",
		"\ttarget: Vector2,",
		"\tspeed: float",
		") -> void:",
		"\tpass",
	]
	_check(syntax.declaration_at(wrapped, 0).text,
		"func move( target: Vector2, speed: float ) -> void:", "wrapped text")
	_check(syntax.declaration_at(wrapped, 0).span, 4, "wrapped span")
	_check(syntax.after_keyword(syntax.declaration_at(wrapped, 0).text, "func"),
		"move( target: Vector2, speed: float ) -> void:", "wrapped, prefixes stripped")

	# A parenthesis inside a string does not hold the scan open. Reading this one
	# line at a time, `(unset)` opens a group that the next line never closes.
	var stringy := ["func warn(message := \"(unset)\") -> void:", "\tpass"]
	_check(syntax.declaration_at(stringy, 0).span, 1, "parenthesis inside a string")

	# Nor does one inside a trailing comment.
	var commented := ["func warn() -> void:  # takes no arguments (yet)", "\tpass"]
	_check(syntax.declaration_at(commented, 0).span, 1, "parenthesis inside a comment")

	# An annotation's own parentheses close on the same line and change nothing.
	var annotated := ["@rpc(\"any_peer\") func net(a: int) -> void:", "\tpass"]
	_check(syntax.declaration_at(annotated, 0).span, 1, "annotated on one line")

	# Nested parentheses in a default value.
	var nested := ["func at(where := Vector2(1, 2)) -> void:", "\tpass"]
	_check(syntax.declaration_at(nested, 0).span, 1, "nested parentheses")

	# Source that never closes must not swallow the file.
	var broken := ["func oops("]
	for i in range(60):
		broken.append("\ta: int,")
	_check(syntax.declaration_at(broken, 0).span <= GDLintDeclarationSyntax.MAX_WRAPPED_LINES,
		true, "unbalanced source is bounded")


func _code_only() -> void:
	var visible := GDLintStyleChecker.without_strings
	var strip := GDLintStyleChecker.code_only
	var blank := func(n: int) -> String: return " ".repeat(n)

	# The quotes stay and the contents are blanked one character for one, so a
	# column in the result is the same column in the source.
	_check(visible.call("x = \"abc\""), "x = \"" + blank.call(3) + "\"", "string contents blanked")
	_check(visible.call("return \"%6.2f  %s\" % [seconds, line]"),
		"return \"" + blank.call(9) + "\" % [seconds, line]", "format specifier is not code")
	_check(visible.call("print(\'single\')"), "print(\'" + blank.call(6) + "\')", "single quotes too")
	_check(visible.call("var n = 42"), "var n = 42", "plain code is untouched")

	# `he said \"pay 500\" ok` is 22 characters once the escapes are counted as two.
	_check(visible.call("print(\"he said \\\"pay 500\\\" ok\")"),
		"print(\"" + blank.call(22) + "\")", "an escaped quote does not end the string")

	# without_strings keeps the comment, because a check looking for
	# commented-out code needs it. code_only drops it, because a digit in prose
	# is not a magic number.
	_check(visible.call("var kept := 1  #var removed := 2"), "var kept := 1  #var removed := 2",
		"the comment survives without_strings")
	_check(strip.call("var x = 7  # was 250"), "var x = 7  ", "code_only drops the comment")
	_check(strip.call("var url = \"res://a#b\"  # note"),
		"var url = \"" + blank.call(9) + "\"  ", "a hash inside a string is not a comment")
	_check(strip.call("print(\"#var x\")"), "print(\"" + blank.call(6) + "\")",
		"nor does a hash in a string start one for code_only")
