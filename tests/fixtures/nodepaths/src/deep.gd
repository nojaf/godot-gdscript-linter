extends Node

## Attached at Panel/Box in scenes/base.tscn, so `..` climbs within the scene.
@onready var button: Button = $Button
@onready var sibling: Button = $"../Box/Button"
@onready var back_down: Node = $"../../Panel"
@onready var too_far: Node = $"../../../Up"
@onready var missing_sibling: Node = $"../Missing"
