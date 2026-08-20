extends FoldBasePanel

## What --check-members reports, and just as importantly what it declines to.
##
## Reported:
##   the `settings` declaration below, once, folded from three reads through it
##   `self.clock_labl`, a misspelling of this script's own member
##   `self.label.txt` and `self.label.tex`, two misspellings sharing one variable
##   `self.panel_ready.emit()`, a signal emitted with the wrong arity
##   `if self.helper:`, a method used as a condition without being called
##
## Silent, and each one is a rule worth breaking loudly if it changes:
##   `self.settings.volume` and its two neighbours, folded into the declaration
##   `self.clock.text`, which resolves
##   `self.title`, inherited from FoldBasePanel
##   `self.untyped_thing.whatever`, which has no declared type to check
##   `label.length()` at the end, where `label` is a local shadowing the member

# Wider than what it holds. Every read through it fails for one reason, so it is
# reported once, here, naming the class it should have been.
var settings: Resource

# Correctly typed. Two misspellings through it are two bugs that happen to share
# a variable, and must stay two findings.
var label: Label

var clock: Label

var untyped_thing


func _ready() -> void:
	self.clock_labl = null
	print(self.settings.volume)
	print(self.settings.brightness)
	print(self.settings.difficulty)
	print(self.label.txt)
	print(self.label.tex)
	print(self.clock.text)
	print(self.title)
	print(self.untyped_thing.whatever)
	self.panel_ready.emit()
	if self.helper:
		print("a Callable is always true")
	var label := "a local that shadows the member"
	print(label.length())


func helper() -> bool:
	return true
