extends Node2D

## Attached at the root of scenes/base.tscn, and at the root of scenes/child.tscn
## through child.gd, which extends this script. A path is reported only when it
## resolves in neither scene.
##
## The tree base.tscn has: Panel, Panel/Box (script deep.gd), Panel/Box/Button,
## Panel/Facts (unique), Sub (instance of sub.tscn, with Sub/Inner) and Lazy
## (a placeholder instance of the same scene). child.tscn adds OnlyInChild.

## The button moved under Box and the path did not follow: reported, with the
## place the only Button actually is.
@onready var moved: Button = $Panel/Button
@onready var found: Button = $Panel/Box/Button
@onready var quoted: Button = $"Panel/Box/Button"

## Facts is marked unique; Button is not, so %Button is reported with that hint.
@onready var unique: Label = %Facts
@onready var not_unique: Button = %Button
@onready var no_such_unique: Node = %Nothing

## get_node asserts the path. get_node_or_null asks about it, and is left alone.
@onready var by_call: Node = get_node("Panel/Box")
@onready var by_call_missing: Node = get_node("Panel/Missing")
@onready var by_call_tolerant: Node = get_node_or_null("Panel/Missing")

## Paths into an instanced sub-scene resolve against what it brings with it.
@onready var in_sub: Node = $Sub/Inner
@onready var not_in_sub: Node = $Sub/Nope

## A placeholder has no children until something loads it: no verdict either
## way. Were the placeholder read as a plain instance, $Lazy/Nope would be
## reported, so its silence is what proves the placeholder is seen.
@onready var lazy: Node = $Lazy/Inner
@onready var lazy_missing: Node = $Lazy/Nope

## Leaves the scene, which nothing here can see: no verdict.
@onready var above: Node = $"../Above"

## Exists in child.tscn and not in base.tscn. One scene having it is enough.
@onready var only_in_child: Node = $OnlyInChild

var late: Button


func _ready() -> void:
	# The assignment form, which the index used to leave invisible.
	self.late = $Panel/Gone
	# The chain form. One finding, not one per record that mentions it.
	$Panel/Box/Buton.pressed.connect(self._on_pressed)
	if self.has_node("Panel/Maybe"):
		print("asked, not asserted")
	# gdlint:ignore-next-line:unknown-node-path
	var ignored: Node = $Panel/Ignored
	print(ignored)


func _on_pressed() -> void:
	pass
