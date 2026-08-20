extends FoldBasePanel

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
