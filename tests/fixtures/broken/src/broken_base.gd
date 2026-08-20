## The script the whole cascade comes from. Four others fail because of this
## one, and they are folded into its finding rather than reported each.
##
## Godot prints its own parse errors to stderr for this fixture, so SCRIPT ERROR
## is expected here and forbidden everywhere else.
class_name CascadeBase
extends Node

var wrong: NoSuchTypeAnywhere = null
