extends Node

## What wrong-parameter-count reports, and what it declines to.
##
## Reported, one finding per line:
##   `self.emitter.changed.connect(self._one)`, two emitted, one taken
##   `own_changed.connect(_none)`, unqualified on both sides, one emitted, none taken
##   `self.emitter.fired.connect(self._one)`, none emitted, one taken
##   `self.emitter.fired.connect(self.emitter.act.bind(1))`, a method of another
##     class: none emitted plus one bound, two taken
##   `self.emitter.changed.connect(self._one.unbind(2))`, two emitted minus two
##     unbound, one taken
##   `self.child_entered_tree.connect(self._none)`, a native signal, one emitted
##   `self.emitter.changed.connect(self.queue_free)`, a native method, none taken
##   `self.slots[0].pressed.connect(self._one)`, a signal through a typed array
##   `emitters[0].changed.connect(self._one)`, unqualified, through an exported
##     array of a script class
##   `self.by_name["a"].fired.connect(self.emitters[0].act)`, both the signal and
##     the handler through a typed container
##
## Silent, and each one is a rule worth breaking loudly if it changes:
##   `self._two`, which takes exactly what is emitted
##   `self._optional`, whose second parameter has a default
##   `self._optional.bind(1)`, none emitted plus one bound, one to two taken
##   `self._one.unbind(1)`, two emitted minus one unbound, one taken
##   `self.emitter.act_optional.bind(1)`, the same through another class
##   a lambda, which the index does not describe as a method
##   `Callable(self, "_one")`, a name in data
##   `callback`, a local, and `self._make_handler()`, a call: neither is a method
##   `self.untyped.changed`, whose owner has no declared type
##   `self.emitter.fired.connect(self._none)`, none emitted, none taken
##   `self.slots[0].pressed.connect(self._none)`, the array case with the right arity
##   `self.untyped_array[0].changed`, whose element type nobody declared
##   the last line, silenced by an ignore directive

signal own_changed(value: int)

var emitter: HandlerEmitter
var untyped
var slots: Array[Button]
@export var emitters: Array[HandlerEmitter]
var by_name: Dictionary[String, HandlerEmitter]
var untyped_array: Array


func _ready() -> void:
	self.emitter.changed.connect(self._one)
	own_changed.connect(_none)
	self.emitter.fired.connect(self._one)
	self.emitter.fired.connect(self.emitter.act.bind(1))
	self.emitter.changed.connect(self._one.unbind(2))
	self.child_entered_tree.connect(self._none)
	self.emitter.changed.connect(self.queue_free)
	self.slots[0].pressed.connect(self._one)
	emitters[0].changed.connect(self._one)
	self.by_name["a"].fired.connect(self.emitters[0].act)

	self.emitter.changed.connect(self._two)
	self.emitter.changed.connect(self._optional)
	self.emitter.fired.connect(self._optional.bind(1))
	self.emitter.changed.connect(self._one.unbind(1))
	self.emitter.fired.connect(self.emitter.act_optional.bind(1))
	self.emitter.changed.connect(func(previous: int, next: int) -> void: print(previous, next))
	self.emitter.changed.connect(Callable(self, "_one"))
	var callback: Callable = self._two
	self.emitter.changed.connect(callback)
	self.emitter.changed.connect(self._make_handler())
	self.untyped.changed.connect(self._one)
	self.emitter.fired.connect(self._none)
	self.slots[0].pressed.connect(self._none)
	self.untyped_array[0].changed.connect(self._one)
	self.emitter.changed.connect(self._one)  # gdlint:ignore-line:wrong-parameter-count


func _none() -> void:
	pass


func _one(value: int) -> void:
	print(value)


func _two(previous: int, next: int) -> void:
	print(previous, next)


func _optional(value: int, extra: int = 0) -> void:
	print(value, extra)


func _make_handler() -> Callable:
	return self._two
