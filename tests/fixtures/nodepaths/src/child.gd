extends "res://src/base.gd"

## Attached at the root of scenes/child.tscn only, which inherits base.tscn.
## The inherited tree is visible, and so is the node the child adds.
@onready var here: Node = $OnlyInChild
@onready var inherited: Button = $Panel/Box/Button
@onready var wrong_here_too: Button = $Panel/Button
