extends Node

## An @export holding an object is null until something wires it in the editor,
## and nothing guarantees that happened. Reported unless the script either
## null-guards it or says it is optional with `= null`.
##
## For a Node the guard has to be in _ready or _enter_tree, because that is when
## exports are populated. A guard anywhere else protects nothing, which is why
## `guarded_too_late` below is still reported.

@export var unguarded: ExportCritters
@export var guarded_by_assert: ExportCritters
@export var guarded_by_not_equal: ExportCritters
@export var guarded_by_null_first: ExportCritters
@export var guarded_by_if: ExportCritters
@export var guarded_by_if_not: ExportCritters
@export var guarded_by_is_instance_valid: ExportCritters
@export var guarded_too_late: ExportCritters
@export var mentioned_not_tested: ExportCritters
@export var optional: ExportCritters = null

## Built-ins are never reported: an int export is 0, not null.
@export var speed: int = 5
@export var title: String = ""

## Not exported at all, so not this check's business.
var plain: ExportCritters


func _ready() -> void:
	assert(self.guarded_by_assert != null, "wire it in the editor")
	if self.guarded_by_not_equal != null:
		print("ok")
	if null != self.guarded_by_null_first:
		print("ok")
	if self.guarded_by_if:
		print("ok")
	if not self.guarded_by_if_not:
		return
	if is_instance_valid(self.guarded_by_is_instance_valid):
		print("ok")
	# Names it without testing it, which must not count as a guard.
	if self.mentioned_not_tested.critter_tapped:
		print("ok")


func some_helper() -> void:
	# The right shape in the wrong place. Nothing calls this, and exports are
	# already needed by the time _ready runs.
	assert(self.guarded_too_late != null, "too late")
