extends Node

## Attached at the root of scenes/sub.tscn. Its own tree is one node deep, and
## the scene that instances it is not visible from here.
@onready var inner: Node = $Inner
@onready var outer: Node = $Panel
