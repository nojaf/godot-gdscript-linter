# GDScript Linter - Style checker (magic numbers, commented code, type hints)
# https://poplava.itch.io
class_name GDLintStyleChecker
extends RefCounted

var config


func _init(p_config) -> void:
	config = p_config


# Performs all line-level style checks in one pass
func check_line(line: String, trimmed: String, line_num: int, file_result) -> Array:
	var issues: Array = []

	_append_issue(issues, _check_long_line(line, line_num))
	_append_issue(issues, _check_todo_comments(trimmed, line_num))
	_append_issue(issues, _check_print_statements(trimmed, line_num))
	_track_metadata(trimmed, file_result)
	_append_issue(issues, _check_magic_numbers(trimmed, line_num))
	_append_issue(issues, _check_commented_code(trimmed, line_num))
	_append_issue(issues, _check_type_hints(trimmed, line_num))

	return issues


func _append_issue(issues: Array, issue) -> void:
	if issue:
		issues.append(issue)


func _check_long_line(line: String, line_num: int) -> Variant:
	if not config.check_long_lines:
		return null
	if line.length() <= config.max_line_length:
		return null
	return {
		"line": line_num,
		"severity": "info",
		"check_id": "long-line",
		"message": "Line exceeds %d chars (%d)" % [config.max_line_length, line.length()],
	}


func _check_todo_comments(trimmed: String, line_num: int) -> Variant:
	if not config.check_todo_comments:
		return null
	return check_todo_comments(trimmed, line_num)


func _check_print_statements(trimmed: String, line_num: int) -> Variant:
	if not config.check_print_statements:
		return null
	return check_print_statements(trimmed, line_num)


func _check_magic_numbers(trimmed: String, line_num: int) -> Variant:
	if not config.check_magic_numbers:
		return null
	return check_magic_numbers(trimmed, line_num)


func _check_commented_code(trimmed: String, line_num: int) -> Variant:
	if not config.check_commented_code:
		return null
	return check_commented_code(trimmed, line_num)


func _check_type_hints(trimmed: String, line_num: int) -> Variant:
	if not config.check_missing_types:
		return null
	return check_variable_type_hints(trimmed, line_num)


func _track_metadata(trimmed: String, file_result) -> void:
	# Track signals
	if GDLintDeclarationSyntax.declares(trimmed, "signal"):
		var signal_name := GDLintDeclarationSyntax.after_keyword(trimmed, "signal").split("(")[0].strip_edges()
		file_result.signals_found.append(signal_name)

	# Track dependencies
	if trimmed.begins_with("preload(") or trimmed.begins_with("load("):
		var dep := _extract_string_arg(trimmed)
		if dep:
			file_result.dependencies.append(dep)


func _extract_string_arg(line: String) -> String:
	var start := line.find("\"")
	var end := line.rfind("\"")
	if start >= 0 and end > start:
		return line.substr(start + 1, end - start - 1)
	return ""


# Returns issue dictionary or null
## A line with the contents of its string literals blanked out, one character for
## one, so a column in the result is the same column in the source. Both quotes
## stay, so a string is still visible as one.
##
## What a string says is text, never code. `print("the docs mention #var x")`
## holds no commented-out code, and `"%6.2f"` holds no magic number.
static func without_strings(text: String) -> String:
	var out := ""
	var quote := ""
	var i := 0
	while i < text.length():
		var character := text[i]
		if not quote.is_empty():
			if character == "\\" and i + 1 < text.length():
				out += "  " # an escaped character cannot close the string
				i += 1
			elif character == quote:
				out += character # both quotes stay, so the string is still visible
				quote = ""
			else:
				out += " "
		elif character == "\"" or character == "'":
			quote = character
			out += character # the quote itself stays, so positions still line up
		else:
			out += character
		i += 1
	return out


## `without_strings`, with the comment dropped as well.
##
## A digit in a comment is prose rather than a number the program uses. A check
## that cares about the comment itself wants `without_strings`, since this
## throws it away.
static func code_only(text: String) -> String:
	var visible := without_strings(text)
	var comment := visible.find("#")
	return visible if comment < 0 else visible.substr(0, comment)


func check_magic_numbers(line: String, line_num: int) -> Variant:
	# Skip comments, const declarations, and common safe patterns
	if line.begins_with("#") or GDLintDeclarationSyntax.declares(line, "const"):
		return null
	if "enum " in line or "@export" in line:
		return null

	# Numbers are looked for in the code, not in the text it carries. This used
	# to scan the whole line and skip only a digit directly after a quote, which
	# meant `"%6.2f"` reported 6 while `"6 things"` was let through.
	var code := code_only(line)

	var regex := RegEx.new()
	regex.compile("(?<![a-zA-Z_])(-?\\d+\\.?\\d*)(?![a-zA-Z_\\d])")

	for regex_match in regex.search_all(code):
		var num_str: String = regex_match.get_string()
		var num_val: float = float(num_str)

		# Skip allowed numbers
		if num_val in config.allowed_numbers:
			continue

		return {
			"line": line_num,
			"severity": "info",
			"check_id": "magic-number",
			"message": "Magic number %s (consider using a named constant)" % num_str,
		}

	return null


# Returns issue dictionary or null
func check_commented_code(line: String, line_num: int) -> Variant:
	# The comment is the point here, so string contents are blanked and the
	# comment kept. Matched anywhere in the line rather than only at its start,
	# because a commented-out statement trailing real code is still commented-out
	# code. Writing an example of one in this comment would report this line,
	# which is a limitation rather than a bug: prose that quotes code and code
	# that has been commented out are the same thing to a pattern match.
	var visible := without_strings(line)
	for pattern in config.commented_code_patterns:
		if visible.begins_with(pattern) or ("\t" + pattern) in visible or (" " + pattern) in visible:
			return {
				"line": line_num,
				"severity": "info",
				"check_id": "commented-code",
				"message": "Commented-out code detected",
			}
	return null


# Returns issue dictionary or null
func check_variable_type_hints(line: String, line_num: int) -> Variant:
	# Check for untyped variable declarations
	if not GDLintDeclarationSyntax.declares(line.strip_edges(), "var"):
		return null

	# Skip @onready and inferred types from literals
	if "@onready" in line:
		return null

	# Everything after `var`, with any annotations and modifiers removed. The raw
	# line cannot be tested for a type annotation: the colon in
	# `@export_file("res://x.tscn") var path = ""` belongs to the annotation's
	# argument, and testing the whole line skips a variable that has no type.
	var after_var := GDLintDeclarationSyntax.after_keyword(line.strip_edges(), "var")

	# Skip if it has a type annotation
	if ":" in after_var.split("=")[0]:
		return null

	var var_name := after_var.split("=")[0].split(":")[0].strip_edges()

	return {
		"line": line_num,
		"severity": "info",
		"check_id": "missing-type-hint",
		"message": "Variable '%s' has no type annotation" % var_name,
	}


# Returns issue dictionary or null
func check_todo_comments(trimmed: String, line_num: int) -> Variant:
	for pattern in config.todo_patterns:
		if pattern in trimmed:
			var severity := "info" if pattern == "TODO" else "warning"
			var comment_text := trimmed.substr(trimmed.find(pattern) + pattern.length()).strip_edges()
			if comment_text.begins_with(":"):
				comment_text = comment_text.substr(1).strip_edges()
			return {
				"line": line_num,
				"severity": severity,
				"check_id": "todo-comment",
				"message": "%s: %s" % [pattern, comment_text],
			}
	return null


# Returns issue dictionary or null
func check_print_statements(trimmed: String, line_num: int) -> Variant:
	var is_whitelisted := false
	for whitelist_item in config.print_whitelist:
		if whitelist_item in trimmed:
			is_whitelisted = true
			break

	if not is_whitelisted:
		for pattern in config.print_patterns:
			if pattern in trimmed and not trimmed.begins_with("#"):
				return {
					"line": line_num,
					"severity": "warning",
					"check_id": "print-statement",
					"message": "Debug print statement: %s"
					% trimmed.substr(0, mini(60, trimmed.length())),
				}
	return null
