# GDScript Linter - Wide read fold
# https://poplava.itch.io
class_name GDLintWideReadFold
extends RefCounted
## Decides how unknown members read THROUGH another member's declared type are
## reported. Members read off a script's own type never come here: a script's own
## type is exactly itself and can never be too wide, so every unknown member
## there is a genuine unknown member.
##
## One unknown member on a variable is a typo, and that is the bug --check-members
## was written for. Many distinct unknown members on the SAME variable is not many
## typos: it is one declaration whose type is wider than what it holds, and every
## access through it fails for that single reason. Reported per access it buries
## the finding that matters under dozens that share a cause. On this addon's own
## source that was 95 CRITICAL findings from four declarations, none of which can
## fail at runtime.
##
## A group folds only when a class can be found that has ALL of the members being
## read. That evidence is what separates the two cases: with it, the object
## demonstrably holds something the declaration failed to name, so the annotation
## is the bug. Without it, the names belong to nothing in the project and are far
## more likely to be misspellings, so they stay where they are and stay loud. Two
## typos on one correctly typed variable must not go quiet just for sharing a
## variable.
##
## Severity splits the same way. A folded group is a WARNING, because the code
## runs: the object really does have those members. Everything else is CRITICAL.

const IssueClass = preload("res://addons/gdscript-linter/analyzer/issue.gd")

## How many member names a folded finding lists before summarising the rest.
const MEMBERS_LISTED := 3

var _types: GDLintMemberTypes
var _check_id: String
var _reads: Array = []


func _init(types: GDLintMemberTypes, check_id: String) -> void:
	_types = types
	_check_id = check_id


func clear() -> void:
	_reads.clear()


## `owner_label` is the declaration as written and `owner_class` the type the
## member is read from. They differ for a typed container: `slots[0].txt` reads
## from `Button`, and the declaration to narrow is `Array[Button]`.
func defer(
	line: int,
	member: String,
	owner: Array,
	owner_label: String,
	owner_class: String,
	near: String,
) -> void:
	_reads.append(
		{
			"line": line,
			"member": member,
			"owner_path": ".".join(owner),
			"owner_label": owner_label,
			"owner_class": owner_class,
			"near": near,
		}
	)


func issues(path: String, entry: Dictionary) -> Array:
	var groups := { }
	for read: Dictionary in _reads:
		var key: String = read.owner_path + " " + read.owner_label
		if not groups.has(key):
			groups[key] = []
		groups[key].append(read)

	var issues: Array = []
	for key: String in groups:
		var reads: Array = groups[key]
		var members := { }
		for read: Dictionary in reads:
			members[read.member] = true
		var names: Array = members.keys()
		names.sort()
		var candidate := _types.type_with_all_members(String(reads[0].owner_class), names)

		if names.size() == 1 or candidate.is_empty():
			for read: Dictionary in reads:
				issues.append(_lone_unknown_member(path, read, candidate))
			continue
		issues.append(_wide_declaration(path, entry, reads, names, candidate))
	return issues


func _lone_unknown_member(path: String, read: Dictionary, candidate: String):
	var message := "'%s' is not a member of %s" % [read.member, read.owner_class]
	if not String(read.near).is_empty():
		message += " (did you mean '%s'?)" % read.near
	elif not candidate.is_empty():
		message += " (%s has it; is '%s' declared too wide?)" % [candidate, read.owner_path]
	return IssueClass.create(path, read.line, IssueClass.Severity.CRITICAL, _check_id, message)


func _wide_declaration(
	path: String,
	entry: Dictionary,
	reads: Array,
	names: Array,
	candidate: String,
):
	var owner_path: String = reads[0].owner_path
	var owner_label: String = reads[0].owner_label
	var owner_class: String = reads[0].owner_class

	var line: int = reads[0].line
	if not owner_path.contains("."):
		var declared_at := _declaration_line(entry, owner_path)
		if declared_at > 0:
			line = declared_at

	var shown: Array = names.slice(0, MEMBERS_LISTED)
	var listed := ", ".join(shown)
	if names.size() > shown.size():
		listed += ", and %d more" % (names.size() - shown.size())

	var message := (
		"'%s' is declared as %s, but %d members are read from it that %s "
		+ "does not have (%s). %s has all of them: narrow the declaration to it, "
		+ "or cast at the use sites."
	) % [owner_path, owner_label, names.size(), owner_class, listed, candidate]

	return IssueClass.create(path, line, IssueClass.Severity.WARNING, _check_id, message)


# Where a class-level member is written, so a wide declaration is reported where
# it is fixed rather than at an arbitrary use of it.
func _declaration_line(entry: Dictionary, member: String) -> int:
	for declaration: Dictionary in entry.declarations:
		if String(declaration.get("kind", "")) != "variable":
			continue
		if not String(declaration.get("scope", "")).is_empty():
			continue # a local, not the member being read from
		if String(declaration.get("name", "")) == member:
			return GDLintSourceIndex.line_of(declaration)
	return 0
