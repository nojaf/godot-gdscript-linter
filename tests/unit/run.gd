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
