# GDScript Linter - Source index
# https://poplava.itch.io
class_name GDLintSourceIndex
extends RefCounted
## Structural facts about the project's source, obtained by running the
## `gdscript-formatter index` sub-command and parsing its JSONL output.
##
## The engine answers what things MEAN: members, inherited members, declared
## types, arity, which exports can be null, which methods are engine virtuals.
## It cannot say where any of it is written. This supplies the other half:
## declarations, references, member chains, string literals, comparisons and
## comments, each with a source range.
##
## Everything here used to be regular expressions over lines, and every bug found
## in those checks came from that. Annotations in front of a declaration, locals
## shadowing members, strings counted as references, inner classes.
##
## Requires the `gdscript-formatter` binary. Set GDLINT_FORMATTER to point at it.
## A missing or unusable binary is a hard error: reporting nothing looks exactly
## like a clean project, so this must never fall back to guessing.

## Bumped by the producer when record shapes change in a breaking way.
const SUPPORTED_SCHEMA := 1

const BINARY_ENV := "GDLINT_FORMATTER"
const BINARY_NAMES := ["gdscript-formatter"]

## Per-file records, keyed by res:// path.
var files := {}
## Set when the index could not be built. Callers must check this first.
var error := ""


## Index the project. `excluded` holds absolute paths to skip.
func build(excluded: Array = []) -> bool:
	files.clear()
	error = ""

	var binary := _find_binary()
	if binary.is_empty():
		error = ("gdscript-formatter not found. Set %s to its path, "
			+ "or put it on PATH.") % BINARY_ENV
		return false

	var project_root := ProjectSettings.globalize_path("res://").rstrip("/")
	var arguments := ["index", "--project-root", project_root]
	for path: String in excluded:
		arguments.append("-x")
		arguments.append(path)
	arguments.append(project_root)

	var output: Array = []
	var exit_code := OS.execute(binary, arguments, output, true)
	if output.is_empty():
		error = "gdscript-formatter produced no output (exit %d)" % exit_code
		return false

	return _parse(String(output[0]))


# Records arrive as one JSON object per line, each file's records following its
# header. A line that does not parse is fatal rather than skipped: a partially
# read index would silently under-report.
func _parse(text: String) -> bool:
	var current: Dictionary = {}

	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or not trimmed.begins_with("{"):
			continue  # the binary writes progress lines to stderr, but be safe

		var record = JSON.parse_string(trimmed)
		if typeof(record) != TYPE_DICTIONARY:
			error = "could not parse index output near: %s" % trimmed.substr(0, 80)
			return false

		if record.get("record", "") == "file":
			current = _start_file(record)
			if not error.is_empty():
				return false
			continue

		if current.is_empty():
			continue  # a record before any header; nothing to attach it to
		_append(current, record)

	return true


func _start_file(header: Dictionary) -> Dictionary:
	var schema := int(header.get("schema", -1))
	if schema != SUPPORTED_SCHEMA:
		error = ("index schema %d is not supported (expected %d). "
			+ "Rebuild gdscript-formatter or update the addon.") % [schema, SUPPORTED_SCHEMA]
		return {}

	var path := String(header.get("path", ""))
	var entry := {
		"path": path,
		"parse_error": bool(header.get("parse_error", false)),
		"declarations": [],
		"references": [],
		"member_chains": [],
		"string_literals": [],
		"comparisons": [],
		"comments": [],
	}
	files[path] = entry
	return entry


const RECORD_BUCKETS := {
	"declaration": "declarations",
	"reference": "references",
	"member_chain": "member_chains",
	"string_literal": "string_literals",
	"comparison": "comparisons",
	"comment": "comments",
}


func _append(entry: Dictionary, record: Dictionary) -> void:
	var bucket: String = RECORD_BUCKETS.get(record.get("record", ""), "")
	if bucket.is_empty():
		return  # an unknown record kind is additive, not an error
	entry[bucket].append(record)


func _find_binary() -> String:
	var configured := OS.get_environment(BINARY_ENV)
	if not configured.is_empty() and FileAccess.file_exists(configured):
		return configured

	for name: String in BINARY_NAMES:
		var found := _which(name)
		if not found.is_empty():
			return found
	return ""


func _which(name: String) -> String:
	var output: Array = []
	if OS.execute("/usr/bin/env", ["which", name], output, false) != 0:
		return ""
	var path := String(output[0]).strip_edges()
	return path if FileAccess.file_exists(path) else ""


## Records for one file, or an empty Dictionary. Analyzed paths arrive with or
## without the res:// prefix depending on how the target was given on the command
## line, while the index always keys on res://. Looking up the raw path silently
## misses every file and reports nothing, which is indistinguishable from a clean
## project, so every lookup goes through here.
func file_records(path: String) -> Dictionary:
	if files.has(path):
		return files[path]
	var normalized := path.replace("\\", "/")
	if not normalized.begins_with("res://"):
		normalized = "res://" + normalized.lstrip("/")
	return files.get(normalized, {})


## The line a record starts on, one-based, matching what issues report.
static func line_of(record: Dictionary) -> int:
	return int(record.get("range", {}).get("start_row", 1))


## Segment names of a member chain. Stops at the first segment that is not a
## plain identifier or `self`, because past that point hop-by-hop resolution is
## no longer valid: `self.get_thing().field` says nothing about `get_thing`'s
## type, and `$Clock.text` is not a member of the enclosing script.
static func resolvable_segments(chain: Dictionary) -> Array:
	var names: Array = []
	for segment: Dictionary in chain.get("segments", []):
		var kind := String(segment.get("kind", ""))
		if kind != "self" and kind != "identifier":
			break
		names.append(String(segment.get("name", "")))
	return names
