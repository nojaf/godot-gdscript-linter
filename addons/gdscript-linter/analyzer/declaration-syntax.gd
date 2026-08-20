# GDScript Linter - Declaration syntax
# https://poplava.itch.io
class_name GDLintDeclarationSyntax
extends RefCounted
## One place that answers "does this line start a declaration".
##
## A declaration can carry annotations and modifiers before its keyword, all on
## the same line, and all of these are valid GDScript:
##
##     @abstract func may_target(candidate: Node) -> bool
##     @rpc("any_peer") func net_call() -> void:
##     static func helper() -> void:
##     @export_range(0, 10) var speed: int = 5
##     @warning_ignore("unused_signal") signal done
##     @icon("res://i.svg") class_name Foo extends Node
##
## Testing `trimmed.begins_with("func ")` misses every one of them. That failure
## is silent and, for range-based directives, actively harmful: a
## `gdlint:ignore-function` looking for the next `func ` runs past an annotated
## or static function and suppresses whatever it finds later instead.

## Modifiers that may sit between the annotations and the keyword.
const MODIFIERS := ["static"]

## Stops an unbalanced parenthesis from swallowing the rest of a file.
const MAX_WRAPPED_LINES := 40


## A declaration as one line, however many it was written across, and how many
## lines it occupies. Returns `{"text": String, "span": int}`, with a span of 1
## for the ordinary case.
##
## A parameter list may be wrapped:
##
##     func move(
##         target: Vector2,
##         speed: float
##     ) -> void:
##
## Read one line at a time that is `func move(`: the `->` appears to be missing,
## the parameter list appears to be empty, and both are wrong. A check that
## reports what it sees then invents a missing return type and overlooks every
## parameter, which is three defects from one cause.
##
## Parentheses inside strings and comments do not count, so a default value like
## `msg := "(unset)"` does not hold the scan open.
static func declaration_at(lines: Array, index: int) -> Dictionary:
	var text := String(lines[index]).strip_edges()
	var depth := _paren_depth(text)
	var span := 1
	while depth > 0 and index + span < lines.size() and span < MAX_WRAPPED_LINES:
		var next := String(lines[index + span]).strip_edges()
		text += " " + next
		depth += _paren_depth(next)
		span += 1
	return {"text": text, "span": span}


# Net change in parenthesis depth, skipping quoted text and trailing comments.
static func _paren_depth(text: String) -> int:
	var depth := 0
	var quote := ""
	var i := 0
	while i < text.length():
		var character := text[i]
		if not quote.is_empty():
			if character == "\\":
				i += 1  # an escaped character cannot close the string
			elif character == quote:
				quote = ""
		elif character == "\"" or character == "'":
			quote = character
		elif character == "#":
			break  # a comment runs to the end of the line
		elif character == "(":
			depth += 1
		elif character == ")":
			depth -= 1
		i += 1
	return depth


## The line with any leading annotations and modifiers removed, so the keyword
## is first. Returns the input unchanged when there is nothing to strip.
static func strip_prefixes(trimmed: String) -> String:
	var rest := trimmed
	while true:
		if rest.begins_with("@"):
			rest = _skip_annotation(rest)
			continue
		var modifier := _leading_modifier(rest)
		if modifier.is_empty():
			break
		rest = rest.substr(modifier.length()).strip_edges(true, false)
	return rest


## True when the line declares `keyword`, whatever precedes it.
static func declares(trimmed: String, keyword: String) -> bool:
	return strip_prefixes(trimmed).begins_with(keyword + " ")


## Everything after `keyword` on a declaration line, with any annotations and
## modifiers already removed. Returns "" when the line does not declare it.
##
## Callers used to slice by a fixed offset, `line.substr(5)` for "func ", which
## assumes the keyword starts the line. With a prefix present that cuts into the
## annotation instead and yields a name like "ract func may_target".
static func after_keyword(trimmed: String, keyword: String) -> String:
	var rest := strip_prefixes(trimmed)
	if not rest.begins_with(keyword + " "):
		return ""
	return rest.substr(keyword.length() + 1)


## True when the declaration is marked @abstract. Such a declaration has no body
## at all, so checks about what a body contains do not apply to it: it is neither
## an empty function nor a function that fails to use its parameters.
static func declares_abstract(trimmed: String) -> bool:
	return trimmed.strip_edges().begins_with("@abstract")


# Steps over one annotation, including a parenthesised argument list that may
# itself contain strings with parentheses in them.
static func _skip_annotation(text: String) -> String:
	var i := 1  # past the '@'
	while i < text.length() and (text[i] == "_" or text[i].is_valid_identifier()):
		i += 1

	if i < text.length() and text[i] == "(":
		var depth := 0
		var quote := ""
		while i < text.length():
			var ch := text[i]
			if not quote.is_empty():
				if ch == quote:
					quote = ""
			elif ch == "\"" or ch == "'":
				quote = ch
			elif ch == "(":
				depth += 1
			elif ch == ")":
				depth -= 1
				if depth == 0:
					i += 1
					break
			i += 1

	return text.substr(i).strip_edges(true, false)


static func _leading_modifier(text: String) -> String:
	for modifier: String in MODIFIERS:
		if text.begins_with(modifier + " "):
			return modifier + " "
	return ""
