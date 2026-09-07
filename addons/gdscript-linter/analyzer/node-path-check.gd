# GDScript Linter - Node path check
# https://poplava.itch.io
class_name GDLintNodePathCheck
extends RefCounted
## Reports `$Path`, `%Name` and get_node("Path") that name no node in any scene
## the script is attached to.
##
## A scene gets reorganised in the editor and the script keeps the old path:
##
##     @onready var commit_button: Button = $Panel/CommitButton
##     # the button now lives at Panel/MarginContainer/Columns/Sidebar/CommitButton
##
## Godot accepts this. The variable is null from the first frame and the failure
## lands wherever it is first used.
##
## GDLintSourceIndex says where each path is written. GDLintSceneIndex says what
## each scene contains, and which script sits on which node. A path is checked
## from every node that carries the script or a script deriving from it, and is
## reported only when no such scene has it: a node that exists in one inherited
## scene but not another is that scene's business, not this check's.
##
## A script no scene attaches is not checked. It may build its children in code,
## or be attached in code, and either way there is nothing to check against.

const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")

const CHECK_UNKNOWN_NODE_PATH := "unknown-node-path"

## Calls whose first string argument is a node path this check verifies.
## get_node_or_null, has_node and find_child ask a question and handle the
## answer, so a path they name is allowed to be absent.
const STRICT_LOOKUP_CALLS := ["get_node"]

## Scenes listed in a message before the rest become "and N more".
const NAMED_SCENES_LIMIT := 3

var _ignore_handler := GDLintIgnoreHandler.new()
var _respect_ignores: bool = true
var _scenes := GDLintSceneIndex.new()
## res:// script path -> the paths of itself and every base script, nearest first.
var _ancestry := { }


## Run over the given res:// script paths, returning an Array of Issue.
func run(index: GDLintSourceIndex, file_paths: Array, p_respect_ignores: bool = true) -> Array:
	_respect_ignores = p_respect_ignores

	var include_addons := false
	for path: String in file_paths:
		if _is_addon_path(path):
			include_addons = true
			break
	_scenes.build(include_addons)

	var issues: Array = []
	for path: String in file_paths:
		issues.append_array(_check_file(index, path))
	return issues


func _check_file(index: GDLintSourceIndex, path: String) -> Array:
	var entry := index.file_records(path)
	if entry.is_empty() or entry.get("parse_error", false):
		return []

	var lookups := _lookups(entry)
	if lookups.is_empty():
		return []

	var attachments := _attachments_of(String(entry.get("path", path)))
	if attachments.is_empty():
		return []

	if _respect_ignores:
		_ignore_handler.initialize(_read_lines(path))

	var issues: Array = []
	for lookup: Dictionary in lookups:
		var missing := _missing_in(lookup, attachments)
		if missing.is_empty():
			continue

		var line := int(lookup["line"])
		if _respect_ignores and _ignore_handler.should_ignore(line, CHECK_UNKNOWN_NODE_PATH):
			continue

		issues.append(
			IssueClass.create(
				path,
				line,
				IssueClass.Severity.CRITICAL,
				CHECK_UNKNOWN_NODE_PATH,
				"'%s' does not exist in %s%s"
				% [lookup["written"], _where(missing), _hint(lookup, missing[0])],
			)
		)

	if _respect_ignores:
		_ignore_handler.clear()
	return issues


# Every place the file fetches a node by a literal path. `%Name` is kept as a
# `%` segment so that resolution treats it exactly as get_node("%Name") would.
func _lookups(entry: Dictionary) -> Array:
	var lookups: Array = []
	for record: Dictionary in entry.node_paths:
		var written_path := String(record.get("path", ""))
		if written_path.is_empty():
			continue
		var unique := bool(record.get("unique", false))
		lookups.append(
			{
				"path": "%" + written_path if unique else written_path,
				"unique": unique,
				"written": _sigil_form(written_path, unique),
				"line": GDLintSourceIndex.line_of(record),
			}
		)

	for literal: Dictionary in entry.string_literals:
		var argument_of: Dictionary = literal.get("argument_of", { })
		if int(argument_of.get("index", -1)) != 0:
			continue
		var callee := String(argument_of.get("callee", ""))
		if not STRICT_LOOKUP_CALLS.has(callee):
			continue
		var value := String(literal.get("value", ""))
		if value.is_empty():
			continue
		lookups.append(
			{
				"path": value,
				"unique": value.begins_with("%"),
				"written": "%s(\"%s\")" % [callee, value],
				"line": GDLintSourceIndex.line_of(literal),
			}
		)
	return lookups


# `$Panel/Button` when the path is plain, `$"Panel/With Space"` when it is not.
func _sigil_form(written_path: String, unique: bool) -> String:
	var sigil := "%" if unique else "$"
	for segment: String in written_path.split("/"):
		if not segment.is_empty() and not segment.is_valid_identifier():
			return "%s\"%s\"" % [sigil, written_path]
	return sigil + written_path


# The attachments where the path resolves to nothing, or none when it resolves
# somewhere, or nowhere could say.
func _missing_in(lookup: Dictionary, attachments: Array) -> Array:
	var missing: Array = []
	for attachment: Dictionary in attachments:
		match _scenes.resolve(attachment["scene"], attachment["node"], lookup["path"]):
			GDLintSceneIndex.Verdict.FOUND:
				return []
			GDLintSceneIndex.Verdict.MISSING:
				missing.append(attachment)
	return missing


# Every (scene, node) carrying this script or one deriving from it. A scene
# that inherits another and swaps the root script for a subclass still runs the
# base script's @onready lines, so the base script is attached there too.
func _attachments_of(script_path: String) -> Array:
	var found: Array = []
	for attachment: Dictionary in _scenes.attachments():
		if _ancestry_of(attachment["script"]).has(script_path):
			found.append(attachment)
	return found


# The engine walks the base chain; a script that fails to load is only itself.
func _ancestry_of(script_path: String) -> Array:
	if _ancestry.has(script_path):
		return _ancestry[script_path]
	var chain: Array = [script_path]
	var script := load(script_path) as Script
	while script != null:
		script = script.get_base_script()
		if script != null and not script.resource_path.is_empty():
			chain.append(script.resource_path)
	_ancestry[script_path] = chain
	return chain


# "dev/lab.tscn (attached at the root)", grouped so that two scenes attaching
# the script at the same node read as one clause.
func _where(missing: Array) -> String:
	var scenes_by_node := { }
	var order: Array = []
	for attachment: Dictionary in missing:
		var node := String(attachment["node"])
		if not scenes_by_node.has(node):
			scenes_by_node[node] = []
			order.append(node)
		scenes_by_node[node].append(_display(attachment["scene"]))

	var clauses: Array = []
	for node: String in order:
		var names: Array = scenes_by_node[node]
		var listed := names.slice(0, NAMED_SCENES_LIMIT)
		var text := " or ".join(listed)
		if names.size() > NAMED_SCENES_LIMIT:
			text = "%s and %d more" % [", ".join(listed), names.size() - NAMED_SCENES_LIMIT]
		var at := "the root" if node.is_empty() else "'%s'" % node
		clauses.append("%s (attached at %s)" % [text, at])
	return "; ".join(clauses)


# Where a node of that name actually is, when there is one. This is the whole
# message for the common case: the node moved and the path did not follow.
#
# Written relative to the node the script sits on, which is what the user would
# type. A script on Panel/Box reaching for Panel/Facts wants '../Facts', and the
# scene-root path would send it to Panel/Box/Panel/Facts.
func _hint(lookup: Dictionary, attachment: Dictionary) -> String:
	var name := String(lookup["path"]).get_file().trim_prefix("%")
	if name.is_empty() or name == "..":
		return ""
	var scene := String(attachment["scene"])
	var from := String(attachment["node"])
	var candidates: Array = []
	for candidate: String in _scenes.nodes_named(scene, name):
		candidates.append("'%s'" % _relative_to(from, candidate))
	if candidates.is_empty():
		return ""

	if bool(lookup["unique"]):
		return "; '%s' is at %s but not marked unique_name_in_owner" % [
			name,
			" and ".join(candidates),
		]
	if candidates.size() == 1:
		return "; the only '%s' is at %s" % [name, candidates[0]]
	return "; '%s' exists at %s" % [name, ", ".join(candidates.slice(0, NAMED_SCENES_LIMIT))]


# The path get_node would take from `from` to reach `target`, both relative to
# the scene root: "Panel/Box" to "Panel/Facts" is "../Facts".
func _relative_to(from: String, target: String) -> String:
	if from.is_empty():
		return target
	var from_segments := from.split("/")
	var target_segments := target.split("/") if not target.is_empty() else PackedStringArray()
	var shared := 0
	while shared < from_segments.size() and shared < target_segments.size() \
			and from_segments[shared] == target_segments[shared]:
		shared += 1
	var steps := PackedStringArray()
	for _i in range(from_segments.size() - shared):
		steps.append("..")
	for i in range(shared, target_segments.size()):
		steps.append(target_segments[i])
	return "/".join(steps) if not steps.is_empty() else "."


func _display(scene_path: String) -> String:
	return scene_path.trim_prefix("res://")


func _is_addon_path(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	if normalized.begins_with("res://"):
		normalized = normalized.substr(6)
	return normalized.begins_with("addons/")


func _read_lines(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var content := file.get_as_text()
	file.close()
	return Array(content.split("\n"))
