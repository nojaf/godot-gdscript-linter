extends Node

## Cyclomatic complexity counts branches. The warning limit here is 3.


func simple(a: int) -> int:
	if a > 0:
		return 1
	return 0


func branchy(a: int, b: int, c: int, d: int) -> int:
	if a > 0:
		return 1
	if b > 0:
		return 2
	if c > 0:
		return 3
	if d > 0:
		return 4
	return 0
