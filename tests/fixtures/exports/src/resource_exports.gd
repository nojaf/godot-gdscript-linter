extends Resource

## A Resource has no _ready and no _enter_tree, so a guard anywhere in the script
## counts. The same code in a Node would be reported.
##
## The exported type is a Resource here because Godot rejects a Node-typed export
## on a Resource outright: "Node export is only supported in Node-derived
## classes".

@export var guarded_anywhere: ExportPayload
@export var never_guarded: ExportPayload


func use_it() -> void:
	assert(self.guarded_anywhere != null, "checked outside any lifecycle callback")
