# GDScript Linter - Command Line Interface

Run GDScript code analysis from the terminal using Godot's headless mode.

## Quick Start

```bash
# Analyze current project
godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd

# Analyze specific directories
godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- src/ scripts/

# Output as JSON
godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- --json

# Output as SARIF 2.1.0 (for GitHub code scanning / JetBrains)
godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- --sarif -o results.sarif
```

## Usage

```
godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- [options] [paths...]
```

**Note:** The `--` separator is required before any linter options to distinguish them from Godot's own arguments.

## Arguments

| Argument | Description |
|----------|-------------|
| `[paths...]` | Files or directories to analyze (default: `res://`) |

## Options

| Option | Description |
|--------|-------------|
| `--config <path>` | Path to config file (default: `gdlint.json`) |
| `--format <type>` | Output format: `console`, `json`, `sarif`, `clickable`, `html`, `github` |
| `--severity <level>` | Minimum severity to report: `info`, `warning`, `critical` |
| `--check <checks>` | Comma-separated list of checks to run |
| `--top <N>` | Show only top N issues sorted by priority |
| `--spaces <N>` | Indent width for `json`/`sarif` output (`0` = compact single line; default: tab) |
| `--json` | Shorthand for `--format json` |
| `--sarif` | Shorthand for `--format sarif` (SARIF 2.1.0) |
| `--clickable` | Shorthand for `--format clickable` (Godot Output panel format) |
| `--html` | Shorthand for `--format html` |
| `--github` | Shorthand for `--format github` (GitHub Actions annotations) |
| `--output, -o <file>` | Write output to a file instead of stdout (`--sarif`/`--json`/`--html`) |
| `--no-ignore` | Bypass all `gdlint:ignore` directives |
| `--check-members` | Load every script; report ones that fail to compile, `self.foo.bar` accesses that resolve to nothing, and signal arity at both the emit and the connect |
| `--check-unused-functions` | Report functions nothing in the project references |
| `--check-exports` | Report object-typed `@export` vars that nothing null-guards |
| `--check-node-paths` | Report `$Path`, `%Name` and `get_node("Path")` that name no node in any scene the script is attached to |
| `--help, -h` | Show help message |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | No issues found |
| 1 | Warnings found (no critical issues) |
| 2 | Critical issues found |

## Configuration

### Auto-Sync from Editor

When you change settings in the GDScript Linter dock in the Godot editor, they automatically sync to `gdlint.json` in your project root. The CLI reads this file by default, ensuring editor and CLI use the same settings.

### Config File Format

The linter uses `gdlint.json` in your project root.

Example `gdlint.json`:

```json
{
	"limits": {
		"file_lines_soft": 200,
		"file_lines_hard": 300,
		"function_lines": 30,
		"function_lines_critical": 60,
		"max_parameters": 4,
		"max_nesting": 3,
		"cyclomatic_warning": 10,
		"cyclomatic_critical": 15
	},
	"checks": {
		"file_length": true,
		"function_length": true,
		"parameters": true,
		"nesting": true,
		"todo_comments": true,
		"long_lines": true,
		"print_statements": true,
		"empty_functions": true,
		"magic_numbers": true,
		"commented_code": true,
		"missing_types": true,
		"cyclomatic_complexity": true,
		"god_class": true,
		"naming_conventions": true,
		"unused_variables": true,
		"unused_parameters": true,
		"missing_return_type": true
	},
	"scanning": {
		"respect_gdignore": true,
		"scan_addons": false,
		"included_addons": [],
		"excluded_addons": []
	},
	"exclude": {
		"paths": ["addons/", ".godot/", "tests/mocks/"]
	}
}
```

### Custom Configs

Use the "Export Config..." button in the editor to save custom configs (e.g., `gdlint-strict.json` for CI, `gdlint-lenient.json` for development).

```bash
# Use a strict config for CI
godot --headless --script ... -- --config gdlint-strict.json
```

## The formatter binary

`--check-members`, `--check-unused-functions`, `--check-exports` and
`--check-node-paths` read source structure from `gdscript-formatter index`, a
sub-command that exists only on
[this fork](https://github.com/nojaf/GDScript-formatter/tree/nojaf). Without it
those checks refuse to run and the process exits 3. They never fall back to
checking less, because a report with nothing in it looks exactly like a clean
project.

Clone the fork beside this repository and build it:

```
~/Projects/godot-gdscript-linter     <- this one
~/Projects/GDScript-formatter        <- the fork, on branch nojaf
```

```bash
git clone -b nojaf https://github.com/nojaf/GDScript-formatter
cd GDScript-formatter && cargo build --release
```

`scripts/install-formatter.sh` is the one place that resolves the binary: the
one named by `GDLINT_FORMATTER`, else the sibling checkout's release build, else
`gdscript-formatter` on PATH. It does not build or update it: the fork and this
linter are edited together, and whoever edits the formatter rebuilds it. The
index carries no version that the linter checks. A shape change the linter does
not know about fails loudly, and that is preferred over a number nobody bumps.

The script verifies the binary really has the `index` sub-command (GDQuest's
original has the same name and does not) and prints its path, which is all it
prints:

```bash
export GDLINT_FORMATTER="$(scripts/install-formatter.sh)"
```

The `lint.sh` that `copy.sh` generates calls it on every run. Disabling every
index-backed check through its `NO_*_CHECK=1` switch, which the generated
`lint.sh` lists at the top, skips the requirement entirely.

## Member Checking (`--check-members`)

A "will this actually run?" pass, intended right before launching the game. Unlike
every other check it asks the engine rather than reading text, so it needs the files
on disk to be current and the project to have been imported.

```bash
godot --headless --script ... -- --check-members
```

Everything it reports is CRITICAL (exit code 2):

| Check | What it catches |
|-------|-----------------|
| `script-load-failed` | The script does not compile, so nothing in it can be checked. Godot's parse error goes to **stderr**; the linter adds the structured finding. Equivalent to running `--check-only` on every file at once. |
| `unknown-member` | A name in a `self.foo.bar` chain is not a member of the type it is read from. |
| `wrong-argument-count` | A signal is emitted with the wrong number of arguments. |
| `wrong-parameter-count` | A signal is connected to a method that cannot take what it emits. |
| `method-not-called` | A method is used as a condition without being called. |

### Why this is needed

GDScript does not verify either of these at parse time. Both compile clean and fail
only when the line executes:

```gdscript
@onready var clock: Label = $Clock

func _process(_delta: float) -> void:
	clock_labl.text = "x"       # Parse Error: Identifier not declared
	self.clock_labl.text = "x"  # compiles clean -- property access through self
	                            # is resolved at runtime
	self.clock.ziggy = "x"      # compiles clean -- property writes on typed
	                            # object variables are not verified either
```

The first line is the only one Godot catches. A codebase that writes `self.` on
member access is opted out of even that.

### Signal emit arity

Adding a parameter to a signal does not update the places that emit it, and Godot
says nothing until the line runs:

```gdscript
signal stopped_walking(critter: Critter)

func park() -> void:
	self.stopped_walking.emit()   # emitted with 0 arguments, expected 1
```

Both `self.some_signal.emit(...)` and the unqualified `some_signal.emit(...)` are
checked, including signals belonging to another type reached through a chain
(`self.other.some_signal.emit(...)`). Argument lists that wrap across lines are
counted correctly; one that cannot be delimited yields no verdict.

**Method calls are deliberately not checked.** Godot's own parser already catches
those — `self.foo(1)`, bare `foo(1)`, and `self.typed_member.foo(1)` all fail to
compile with "Too few arguments" — and the script then shows up here as
`script-load-failed`. Only signal emits slip through, so only signal emits are
checked. The one case neither catches is a call through an untyped variable, which
nothing can resolve.

### Signal handler arity

The other end of the same change. A signal that gained a parameter still connects
to every handler written for the old shape, and the handler fails on the first
emit with "Method expected 1 arguments, but called with 2". Godot checks nothing at
the connect: not at parse, not with `--check-only`, not when the line runs.

```gdscript
signal selection_changed(previous: Critter, next: Critter)

func _ready() -> void:
	self.selection_changed.connect(self._on_selection_changed)  # calls it with 2

func _on_selection_changed(critter: Critter) -> void:  # takes 1
	...
```

The handler is resolved from what sits in the argument slot: `self._on_x`, the
unqualified `_on_x`, or a method reached through a typed member such as
`self.player.commit_slot` or a typed container such as `self.players[i].commit`,
each optionally followed by one `.bind(...)` or `.unbind(n)`. Bound arguments are added to what the signal emits and unbound ones
taken off, then the total has to fall between the method's required and total
parameter counts, so a trailing default parameter is fine. Signals and methods of
native classes count too, so `child_entered_tree.connect(self._reset)` is checked
against `Node`'s signal and `changed.connect(self.queue_free)` against `Object`'s
method.

No verdict is given for anything that is not a method this can look up: a lambda,
`Callable(self, "name")`, a local variable holding a Callable, a call that returns
one, or a chain the walk cannot follow, which includes a signal owned by an
untyped member or an untyped `Array`, and one reached through `$Path`.

### Methods used as conditions

Forgetting the parentheses on a predicate does not fail — the reference is a
`Callable`, which is always truthy, so the branch stops branching:

```gdscript
func any_enemy_walking() -> bool: ...

if self.critters.any_enemy_walking:    # always true -- the () is missing
	self._enter_wave_end()
```

Godot reports nothing here, in any form: through `self.`, unqualified, or through
a typed member. Flagged when a method appears in a truth test — after `if`,
`elif`, `while`, `and`, `or`, `not`, or inside `assert(`.

Passing a method around *without* calling it is normal and is not reported:

```gdscript
var cb := self.predicate                 # fine
button.pressed.connect(self._on_press)   # fine
```

Both `self.critters.any_enemy_walking` and the unqualified
`critters.any_enemy_walking` are checked — see below.

### Typed containers

A subscript on a typed container steps into what it holds: `self.slots[i].pressed`
reads `pressed` from `Button` when `slots` is declared `Array[Button]`, and a
`Dictionary[K, V]` yields its `V`. An untyped `Array` or `Dictionary` stops the
walk, as does a subscript on anything that is not a plain member, such as
`get_children()[0]`.

### Qualified and unqualified access

Every check here works with or without the `self.` prefix. For an unqualified
chain, the root identifier is resolved as a member of the enclosing script:

```gdscript
self.critters.any_enemy_walking   # checked
critters.any_enemy_walking        # also checked
```

A chain is skipped when its root name is bound by a local variable, parameter or
loop variable in the same function, because the script member of that name may not
be what the line refers to:

```gdscript
var target := "a string now"   # shadows the member `target`
print(target.length())         # not checked against the member's type
```

That guard is scoped per function, not per file. A file-wide set would mean one
`var result` in any function silently switching the check off for `result`
everywhere — the kind of failure that gets worse the more ordinary the name is.

### How it resolves

Member sets come from the engine, never from parsing declarations:
`get_script_property_list()` and friends for scripts (which already include members
inherited from base scripts), plus `ClassDB` for the native base class.

Chains are walked one hop at a time. Each step needs a declared type to continue —
the property list reports `Label` for `var clock: Label` and `Tide` for a script
class, and script classes are resolved to their files through the project's global
class list. The walk stops silently as soon as a type cannot be determined, so an
untyped `var thing` yields no verdict rather than a guess.

### Base types are reported on purpose

A member declared as a base class but holding a subtype is reported, even though it
works at runtime:

```gdscript
var widget: Node          # actually holds a Label

func _ready() -> void:
	self.widget = $Clock
	self.widget.text = "x"  # 'text' is not a member of Node
```

This is intended. The declaration is either missing a cast or naming a type wider
than what the member really holds, and both are worth fixing:

```gdscript
var widget: Label                    # say what it is, or
(self.widget as Label).text = "x"    # cast at the point of use
```

Suppress it with `# gdlint:ignore-line:unknown-member` when neither applies.

### Limitations

- Scripts overriding `_get_property_list`, `_set` or `_get` can answer to names that
  appear in no member list, so they are skipped entirely.
- Loading a script runs its `@tool` static initializers — the same exposure as
  launching the project, but not zero.
- A broken base script breaks everything extending it; only the root cause is
  reported, with a count of the dependents.
- A stale script class cache makes every script fail to load. Re-import first
  (`godot --headless --path <dir> --import`).

Suppress a false positive with the usual directives:

```gdscript
self.widget.text = "x"  # gdlint:ignore-line:unknown-member
```

## Unused Functions (`--check-unused-functions`)

Reports functions that nothing in the project references — the kind of rot that
accumulates quietly as code moves around.

```bash
godot --headless --script ... -- --check-unused-functions
```

Reported as WARNING, since dead code does not stop the game from running.

### What counts as a reference

Every occurrence of the name in code counts, so all of these keep a function alive:

```gdscript
demo.actually_called()                  # ordinary call
self.call("called_by_string")           # name inside a string
Callable(self, "called_by_callable")    # bare Callable reference
button.pressed.connect(self._on_press)  # connected without calling
```

```ini
# and in scene/resource data, where Godot calls methods by name rather than
# from any code -- signal connections wired in the editor:
[connection signal="pressed" from="Button" to="." method="_on_editor_wired"]

# ...and AnimationPlayer method tracks, which fire from the timeline:
"values": [{ "args": [], "method": &"spawn_wave" }]
```

### Which files are searched

| Kind | Extensions |
|------|------------|
| Text | `.gd`, `.tscn`, `.tres`, `.cs`, `.json`, `.cfg` |
| Binary | `.res`, `.scn` |

Binary matters more than it sounds: an animation living inside its scene is text
and readable, but the moment it is saved out to its own file it becomes a binary
`.res`, and a method track in it is the function's only caller. Godot stores
strings in these as plain UTF-8, so the identifier-shaped ASCII runs are extracted
directly from the bytes. Reading them can only ever *add* references, so a garbled
read makes the check quieter, never wrong.

A string only counts where the string actually names a method — as an argument to
`call`, `call_deferred`, `callv`, `call_group`, `has_method`, `rpc`, `rpc_id`,
`connect`, `disconnect`, `is_connected`, `emit_signal`, `Callable` or `bind`.
A string anywhere else is prose and does not:

```gdscript
print("all done")               # does NOT keep all() alive
self.call("really_called")      # does
```

Comments do **not** count either — a function mentioned only in prose is still
dead. Nor does a function naming *itself*: recursing, or returning its own name as
a string, is not somebody else calling it.

```gdscript
func unused_snowcat() -> String:
	return "unused_snowcat"   # still reported -- it is its own only mention
```

References are searched across the whole project regardless of which paths you are
analyzing, so narrowing the scan cannot manufacture a false positive.

`addons/` is excluded from that search unless an addon is itself what you are
analyzing. Addon code is third-party prose and identifiers, and it masks dead code
in your project: this linter's own installed copy contains ~80 standalone `all`
tokens, which was enough to hide a genuinely dead `all()` function.

### What is never reported

- **Engine virtuals.** `_ready`, `_process`, `_input` and friends are called by the
  engine, never by your code. They are identified by asking `ClassDB` what the
  native base class declares.
- **Placeholder bodies.** A function containing only `pass` is an intentional stub;
  the `empty-function` check already covers those.

### Limitations

The check errs toward silence: it would rather miss dead code than tell you to
delete something live.

- A name shared with anything else in the project — a variable, or a method of the
  same name on another class — counts as a reference, so the function is not
  reported.
- A method name built or stored indirectly (`var m := "foo"` then `obj.call(m)`)
  is not seen, and the function would be reported. Scene and resource files are
  still scanned in full, so editor wiring is unaffected.
- A script that fails to compile is skipped entirely, since its native base is
  unknown and every virtual override would otherwise look dead.

Suppress a finding with the usual directives:

```gdscript
# gdlint:ignore-next-line:unused-function
func kept_for_later() -> void:
```

## Unguarded Exports (`--check-exports`)

An `@export` holding an object reference is null until something wires it in the
editor, and nothing guarantees that happened. The failure surfaces at runtime, far
from the declaration:

```gdscript
@export var critters: Critters              # never wired

func _ready() -> void:
	self.critters.critter_tapped.connect(...)   # null
```

Reported as CRITICAL. Two ways to satisfy it, both explicit:

```gdscript
@export var critters: Critters
func _ready() -> void:
	assert(critters != null, "wire it on the Match scene")

@export var icon: Texture2D = null    # or: declare it optional
```

### What is checked

Only **object-typed** exports. Built-ins are never null — `@export var hp: int` is
`0`, not null — so `int`, `float`, `Color`, `Rect2`, typed arrays and the rest are
never reported. Exports are read from the engine's property list rather than
parsed, so `@export_range`, exports with setters, and every other annotation form
are recognized without special cases.

### Where the guard has to be

Depends on the base class, because that decides where the exports are actually
populated:

| Script extends | Guard must be in |
|----------------|------------------|
| `Node` (any descendant) | `_ready()` or `_enter_tree()` |
| anything else (`Resource`, `RefCounted`, …) | anywhere in the script |

A Node's exports are set as it enters the tree, so those two callbacks are the
places that run with them populated. A guard parked in a helper nobody calls
satisfies nothing:

```gdscript
extends Node

@export var critters: Critters

func _ready() -> void:
	self._validate()

func _validate() -> void:
	assert(critters != null, "...")   # still reported -- not a lifecycle callback
```

A `Resource` has neither callback, so any location counts for one.

### What counts as a guard

Anything that null-tests the name, within the scope above:

```gdscript
assert(x != null, "...")     # or the compound form, one term per line
assert(x, "...")
if x == null: return
if not x: return
if x: ...
if is_instance_valid(x): ...
```

The test has to be *about the reference*. A condition that merely mentions it —
`if self.critters.any_enemy_walking:` — is not a guard, and does not excuse it.

### Limitations

- Only guards in the same script count. If a parent or factory guarantees the
  wiring, the export is still reported; an assert is cheap, but this does push a
  particular style.
- For a Node, a guard in a lifecycle callback counts even if some path skips it.
  The check sees where the test is written, not that it ran.
- `= null` becomes load-bearing: it is the only way to say "optional".

```gdscript
# gdlint:ignore-next-line:unguarded-export
@export var wired_by_the_parent: Node
```

## Node Paths (`--check-node-paths`)

A scene gets reorganised in the editor and the script keeps the old path:

```gdscript
@onready var commit_button: Button = $Panel/CommitButton
# the button now lives at Panel/MarginContainer/Columns/Sidebar/CommitButton
```

Godot accepts this. The variable is null from the first frame, and the failure
lands wherever it is first used. Reported as CRITICAL:

```
dev/lab.gd:26: '$Panel/CommitButton' does not exist in dev/lab.tscn or
    dev/lab_capture.tscn (attached at the root); the only 'CommitButton' is at
    'Panel/MarginContainer/Columns/Sidebar/CommitButton'
```

### What is checked

`$Path`, `$"Path/With Spaces"`, `%Name` and `get_node("Path")`, wherever they
are written: `@onready` values, assignments, arguments, conditions, and the head
of a chain such as `$Panel/Button.pressed.connect(...)`.

`get_node_or_null`, `has_node` and `find_child` are left alone. They ask whether
a node is there and handle the answer, so a path they name is allowed to be
absent.

### Which scenes

Every scene in the project is read through the engine's `SceneState`, so
inherited scenes, instanced sub-scenes, instance placeholders and binary `.scn`
files are what Godot says they are rather than what a text parser makes of them.

A path is resolved from every node that carries the script, or a script deriving
from it: a scene that inherits another and swaps the root script for a subclass
still runs the base script's `@onready` lines. It is reported only when it
resolves in none of them. A node that exists in one inherited scene and not in
another is that scene's business.

Three things produce no verdict rather than a finding: a script no scene
attaches, which may build its children in code; a path that leaves the scene,
through `..` past the root or an absolute `/root/...`; and a path into an
instance placeholder, whose children do not exist until something loads them.

When a node of the same name exists somewhere else in the scene, the message says
where, written relative to the node the script sits on.

### Limitations

- Children added in code are not seen. A script that does `add_child` in
  `_init` and reads `$Child` in `_ready` is reported if a scene attaches it,
  even though it works. Silence it on the line.
- A path built from a variable is not a literal and is not checked.
- The node's type is not compared with the declared type. `@onready var b:
  Button = $Panel/Label` resolves, and is not reported.
- Reading a scene loads it, along with its scripts and resources. A scene that
  fails to load is skipped, and the scripts it attaches go unchecked there.

```gdscript
# gdlint:ignore-next-line:unknown-node-path
@onready var built_in_init: Node = $Child
```

## Output Formats

### Console (default)

Human-readable report with summary, top files, and categorized issues.

### JSON

Machine-parseable output for integration with other tools:

```bash
godot --headless --script ... -- --json -o report.json
```

### SARIF

Standard [SARIF 2.1.0](https://sarifweb.azurewebsites.net/) output. Integrates with GitHub code scanning, JetBrains IDEs, and other SARIF-aware tools:

```bash
godot --headless --script ... -- --sarif -o results.sarif
```

**Use `-o`, not a shell redirect.** Godot prints its version banner to *stdout*
before this script runs, so `--sarif > results.sarif` captures the banner too and
the file is not valid JSON. `--quiet` does not help — it silences the report along
with the banner. `-o` writes the payload straight to the file and never touches
stdout. The same applies to `--json`.

File paths are emitted repo-relative (the `res://` prefix is stripped) so alerts resolve against the repository. Severities map as CRITICAL→`error`, WARNING→`warning`, INFO→`note`.

### Clickable

Godot Output panel format with clickable file:line links:

```
res://scripts/player.gd:42: [warning] Function 'update_physics' exceeds 30 lines (45)
```

### GitHub Actions

Annotations that appear directly in GitHub PR diffs:

```bash
godot --headless --script ... -- --github
```

Output format:
```
::error file=scripts/player.gd,line=42::[high-complexity] Function has complexity 25 (max 15)
::warning file=scripts/player.gd,line=100::[long-function] Function exceeds 30 lines (45)
```

### HTML

Self-contained HTML report with interactive filtering:

```bash
godot --headless --script ... -- --html -o report.html
```

## CI/CD Integration

### GitHub Actions

```yaml
name: GDScript Lint

on: [push, pull_request]

jobs:
  lint:
	runs-on: ubuntu-latest
	steps:
	  - uses: actions/checkout@v4

	  - name: Setup Godot
		uses: chickensoft-games/setup-godot@v1
		with:
		  version: 4.2.1

	  - name: Run GDScript Linter
		run: |
		  godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- --format github
```

#### Upload to GitHub code scanning (SARIF)

```yaml
	  - name: Run GDScript Linter (SARIF)
		run: |
		  godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- --sarif -o results.sarif
		continue-on-error: true  # let the upload step run even when issues are found

	  - name: Upload SARIF
		uses: github/codeql-action/upload-sarif@v3
		with:
		  sarif_file: results.sarif
```

### GitLab CI

```yaml
lint:
  image: barichello/godot-ci:4.2.1
  script:
	- godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- --format json -o lint-report.json
  artifacts:
	reports:
	  codequality: lint-report.json
```

## Examples

### Analyze Multiple Directories

```bash
godot --headless --script ... -- src/ scripts/ autoload/
```

### Show Only Critical Issues

```bash
godot --headless --script ... -- --severity critical
```

### Show Top 10 Priority Issues

```bash
# Top 10 issues sorted by severity, then by "badness" (complexity, line count)
godot --headless --script ... -- --top 10

# Top 5 critical issues for quick CI summary
godot --headless --script ... -- --top 5 --severity critical --format github
```

### Run Specific Checks

```bash
# Only check for complexity and function length
godot --headless --script ... -- --check high-complexity,long-function
```

### Combine Options

```bash
# Strict CI check: critical issues only, specific checks, GitHub annotations
godot --headless --script ... -- \
	--config gdlint-ci.json \
	--severity critical \
	--check high-complexity,long-function,god-class \
	--format github \
	src/
```

## Available Check IDs

For use with `--check`:

| Check ID | Description |
|----------|-------------|
| `file-length` | Files exceeding line limits |
| `long-function` | Functions exceeding line limits |
| `long-line` | Lines exceeding max length |
| `todo-comment` | TODO, FIXME, HACK comments |
| `print-statement` | Debug print statements |
| `empty-function` | Functions with no implementation |
| `magic-number` | Hardcoded numeric values |
| `commented-code` | Commented-out code blocks |
| `missing-type-hint` | Variables without type hints |
| `missing-return-type` | Functions without return type |
| `too-many-params` | Functions with many parameters |
| `deep-nesting` | Excessive nesting depth |
| `high-complexity` | High cyclomatic complexity |
| `god-class` | Classes with too many members |
| `naming-class` | Class naming convention |
| `naming-function` | Function naming convention |
| `naming-signal` | Signal naming convention |
| `naming-const` | Constant naming convention |
| `naming-enum` | Enum naming convention |
| `unused-variable` | Local variables never used |
| `unused-parameter` | Function parameters never used |
| `script-load-failed` | Script does not compile (`--check-members` only) |
| `unknown-member` | A name in a `self.foo.bar` chain resolves to nothing (`--check-members` only) |
| `wrong-argument-count` | Signal emitted with the wrong argument count (`--check-members` only) |
| `wrong-parameter-count` | Signal connected to a method that cannot take what it emits (`--check-members` only) |
| `method-not-called` | Method used as a condition without being called (`--check-members` only) |
| `unused-function` | Function nothing in the project references (`--check-unused-functions` only) |
| `unguarded-export` | Object-typed `@export` with no null guard (`--check-exports` only) |
| `unknown-node-path` | `$Path`, `%Name` or `get_node("Path")` that no attached scene has (`--check-node-paths` only) |

## Common Mistakes

### Wrong: Passing a file path
```bash
# DON'T do this - CLI expects directories, not files
godot --headless --script ... -- src/player.gd
```

### Right: Pass a directory
```bash
# DO this - pass the directory containing .gd files
godot --headless --script ... -- src/
```

### Wrong: Forgetting the `--` separator
```bash
# DON'T do this - Godot will consume --top as its own arg
godot --headless --script ... --top 5
```

### Right: Use `--` before linter options
```bash
# DO this - the -- tells Godot "everything after is for the script"
godot --headless --script ... -- --top 5
```

### Wrong: Running from wrong directory
```bash
# DON'T do this if gdscript-linter isn't in this project
cd /some/other/project
godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd
```

### Right: Use --path for external projects
```bash
# DO this - run from the linter's project, use --path for target
cd /project-with-linter-installed
godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- --path /other/project
```

## For AI Assistants

When using this CLI:

1. **Always use `--` before any linter options** - required separator
2. **Pass directory paths, not file paths** - the linter scans directories recursively
3. **The script path is relative to the project with the linter installed** - use `--path` for external projects
4. **Targeting a specific addon** - pass its path as a positional argument (e.g. `-- addons/myaddon`) and it is automatically added to `included_addons` for that run

Example for analyzing an external project:
```bash
godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- --path "C:/path/to/project" --top 10
```

## Performance Notes

- Godot headless mode has ~2-3 second startup overhead
- For interactive use, consider running analysis from within the editor
- For CI/CD, the startup overhead is negligible compared to build times
