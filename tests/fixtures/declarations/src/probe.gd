## Upstream issue #15: a declaration carrying an annotation or `static` was
## skipped by the checks entirely. Every construct here is written twice, plain
## and then decorated, and the two halves must report the same thing.
##
## The messages matter as much as the lines. The checks recognised the
## declaration and then read its contents off the raw line, where the first `(`
## belongs to the annotation:
##   annotated_many    reported 1 parameter, measuring @rpc("any_peer")'s list
##   annotated_unused  reported a parameter named `""`, the remains of "any_peer"
##   pathy_untyped     was skipped, the `:` in "res://levels/x.tscn" read as a type
class_name DeclProbe
extends Node

signal plain_bad_Signal
@warning_ignore("unused_signal") signal annotated_bad_Signal

var plain_untyped = 1
@export var exported_untyped = 2
@export_range(0, 10) var ranged_untyped = 3
@export_file("res://levels/x.tscn") var pathy_untyped = ""
static var static_untyped = 4

@export var typed_ok: int = 5
@export_file("res://levels/x.tscn") var typed_path: String = ""
static var static_typed: int = 6

const plain_bad_Const := 1
@warning_ignore("unused_private_class_variable") const annotated_bad_Const := 2

enum plain_bad_Enum { A }


func plain_many(a: int, b: int, c: int, d: int, e: int, f: int) -> void:
	print(a, b, c, d, e, f)


@rpc("any_peer") func annotated_many(a: int, b: int, c: int, d: int, e: int, f: int) -> void:
	print(a, b, c, d, e, f)


static func static_many(a: int, b: int, c: int, d: int, e: int, f: int) -> void:
	print(a, b, c, d, e, f)


@warning_ignore("unused_parameter") static func both_many(a: int, b: int, c: int, d: int, e: int, f: int) -> void:
	print(a, b, c, d, e, f)


func plain_unused(used_a: int, never_a: int) -> void:
	print(used_a)


@rpc("any_peer") func annotated_unused(used_b: int, never_b: int) -> void:
	print(used_b)
