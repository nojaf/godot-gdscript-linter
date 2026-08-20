#@ascii_only
extends Node

## The ASCII check is opt-in per file. This file asks for it with the attribute
## above; text.gd contains a non-ASCII character too and is not reported,
## because it does not ask.


func arrows() -> void:
	print("this arrow → is not ASCII")


func quotes() -> void:
	print("these “smart quotes” are not either")
