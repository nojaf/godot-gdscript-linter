# Branch notes — `nojaf`

This branch collects several additions to `graydwarf/godot-gdscript-linter`. It is
a fork branch, kept as one piece so the work can be read in context. It is not a
pull request, and nothing here is meant to land as-is.

I wrote this file for the maintainer. It states what each change does, why I think
the linter is the right place for it, and what it costs. The table below marks
which changes are offered upstream. The `copy.sh` tooling is local to my workflow
and is not.

Branch point: `aeeae7d`, the tip of `main` at the time.

## Disclosure: this was written by an AI agent

Claude (Anthropic's coding agent) wrote all of the code on this branch, the
fixture projects, the documentation, and this file. Every commit carries a
`Co-Authored-By: Claude` trailer.

My role was product owner, not implementer. I said what I wanted, supplied the
bugs from my own game project that motivated each check, set constraints, pushed
back on designs I did not like, and approved what shipped. I did not write the
implementation.

I am stating this plainly because it changes how you should review it. Treat this
as code from a contributor whose reasoning you cannot interrogate directly. The
design decisions below are documented precisely so you can judge them on their
merits rather than on trust, and every claim about engine behavior was checked
against Godot rather than asserted. If you would rather not take AI-written code
into this project at all, that is a reasonable position and I would rather hear it
now than after a pull request.

## How to try it

```bash
git clone -b nojaf https://github.com/nojaf/godot-gdscript-linter
# copy addons/gdscript-linter/ into a Godot project, then:
godot --headless --path <project> --import
godot --headless --path <project> --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- \
    --check-members --check-unused-functions --check-exports --clickable
```

The `--import` step matters. The checks below read type information from the
engine, and that requires the project's script class cache to exist.

## What is here

| Change | Commits | Offered upstream |
|--------|---------|------------------|
| `--sarif`: SARIF 2.1.0 output, plus `--spaces` and `--output` for machine formats | `9b0d139`, `e7a2f8d` | Yes |
| `--check-members`: verify member access, signal emit arity, uncalled predicates | `021d408`, `c5ecf83`, `e094370`, `c9e5012` | Yes |
| `--check-unused-functions`: report functions nothing references | `0afb2e9`, `3a29a41`, `956129b`, `365c50b`, `c250b8d` | Yes |
| `--check-exports`: object `@export` vars with no null guard | `83fc79d` | Yes |
| `copy.sh`: install the addon into a project and generate a `lint.sh` wrapper | `9b672f3` | No, local workflow |

Every check is behind its own opt-in flag and off by default. No existing output,
exit code, config key or dock behavior changes. A user who does not pass the new
flags sees exactly what they saw before.

The checks are CLI-only. None of them appear in the editor dock, because I
develop this project from an external editor and never open the dock. Wiring them
into the dock is work I have not done.

## Why these checks exist

GDScript checks less at parse time than I expected, and more than I expected in
other places. Each check below covers a case I confirmed the engine does not catch,
and deliberately skips cases it does. I tested each one against Godot rather than
reasoning about it, because my guesses were wrong in both directions.

Two of these bugs cost me real debugging time in a game project before I wrote the
check. Both compiled cleanly and failed at runtime.

---

## `--sarif`

`--sarif` and `--format sarif` emit SARIF 2.1.0, which imports into GitHub code
scanning and JetBrains IDEs. Paths are repo-relative, with `res://` stripped.
Severities map CRITICAL to `error`, WARNING to `warning`, INFO to `note`. Exit
codes do not change.

`--spaces <N>` sets indentation for `json` and `sarif`. `0` produces one compact
line. The default is a tab.

`scripts/validate_sarif.py` checks the structure and compares the result count
against a `--json` run over the same paths. It uses the standard library only.

### One thing to know about stdout

Godot writes its version banner to stdout before any script runs. A redirect like
`--sarif > results.sarif` therefore captures the banner, and the file is not valid
JSON. `--quiet` does not help, because it silences the report as well.

I extended `--output/-o` to cover `sarif` and `json`. It previously applied to
`--html` only. The payload goes straight to the file, so stdout is never involved.
The docs and CI examples now use `-o results.sarif`.

---

## `--check-members`

Reports `script-load-failed`, `unknown-member`, `wrong-argument-count` and
`method-not-called`. All are CRITICAL.

The bug that started this: `self.clock_label` where the member is named `clock`.
It compiled, and crashed on the first frame `_process` ran.

### What the engine does not catch

```gdscript
clock_labl.text = "x"        # Parse Error, caught by Godot
self.clock_labl.text = "x"   # clean: property access through self is dynamic
self.clock.ziggy = "x"       # clean: property writes on typed object vars
                             #        are not verified either
self.stopped_walking.emit()  # clean: signal emit arity is not verified
if self.any_enemy_walking:   # clean: a Callable is always true
```

Godot catches the first line only. A codebase that writes `self.` on member access
loses even that. `UNSAFE_PROPERTY_ACCESS` does not help, because GDScript warnings
are editor-only. They are emitted neither by `--check-only` nor by a runtime
`load()`.

### How it resolves names

Member sets come from the engine, not from parsing declarations.
`get_script_property_list()` and its siblings already merge members inherited from
base scripts, and `ClassDB` covers the native base class. This means
`@export_range`, setters, and every other annotation form need no special handling.

Chains walk one hop at a time. The property list reports the declared type of each
member: `Label` for `var clock: Label`, or a script class name, which resolves to a
file through the project's global class list. The walk stops as soon as a type
cannot be determined, so an untyped member produces no verdict.

Chains work with or without the `self.` prefix. For an unqualified chain, the root
identifier must be a member of the script, and must not be shadowed by a local,
parameter or loop variable in the same function.

### Deliberate design decisions

**A declared base type that is too wide is reported.** `var widget: Node` holding a
`Label`, then `self.widget.text`, is reported even though it runs. The declaration
is either missing a cast or wider than what it holds. Both fixes keep the check
working against the narrower type.

**Method call arity is not checked.** Godot's own parser rejects `self.foo(1)`,
bare `foo(1)` and `self.typed_member.foo(1)` with "Too few arguments", and that
surfaces here as `script-load-failed`. Only signal emits pass the parser, so only
signal emits are checked. Signals have no default arguments, so the expected count
is exact.

**A method used as a condition is reported.** `if self.any_enemy_walking:` is a
`Callable`, so the branch is always taken. Only truth tests are reported, which
leaves the normal uses alone: assigning a `Callable`, or connecting a signal.

### Limits

- Scripts overriding `_get_property_list`, `_set` or `_get` are skipped.
- Loading a script runs its `@tool` static initializers.
- A broken base script reports the root cause with a count of its dependents.
- A stale script class cache makes every script fail to load.
- A call through an untyped variable cannot be resolved, by this or by Godot.

---

## `--check-unused-functions`

Reports functions that nothing in the project references, as a WARNING. Dead code
does not stop a game from running, so it does not gate anything.

Reference counting is deliberate about what it believes. Occurrences in code count.
A name inside a string counts only where the string names a method: arguments to
`call`, `call_deferred`, `callv`, `has_method`, `rpc`, `connect`, `Callable` and
similar. A string anywhere else is prose, so `print("all done")` does not keep
`all()` alive. Comments are stripped for the same reason.

References are searched across the whole project, whatever paths are being
analyzed, so narrowing the scan cannot produce a false positive. `addons/` is
excluded unless an addon is what is being analyzed. Addon text otherwise masks dead
code in the project under analysis: this addon's own source contains about 80
standalone `all` tokens, which was enough to hide a genuinely dead `all()`.

Two things are never reported. Engine virtuals are identified by asking `ClassDB`
what the native base class declares. Placeholder bodies containing only `pass` are
left to the existing `empty-function` check.

### Callers that are data, not code

Godot calls methods by name from places that contain no code. Signal connections
wired in the editor and AnimationPlayer method tracks both live in `.tscn` and
`.tres` while embedded, and become binary `.res` or `.scn` once saved separately.
Binary files are scanned by pulling identifier-shaped ASCII runs out of the bytes,
which works because Godot stores strings in a plain UTF-8 table. Reading them can
only add references, so a garbled read makes the check quieter rather than wrong.

### One API note

`ClassDB.class_has_method("Node", "_ready")` returns **false**, while
`ClassDB.class_get_method_list("Node")` includes `_ready`. `class_has_method`
filters virtuals out. Using it to detect lifecycle callbacks marks every `_ready`
and `_process` override in a project as dead code.

### Results

Four genuinely dead functions in this addon: `get_location_string` and
`get_severity_icon` in `issue.gd`, `get_issues_for_file` in `analysis-result.gd`,
and `_add_code_block` in `help-card-builder.gd`. Each appears exactly once in the
repository, at its own declaration.

### Limits

- A name shared with a variable, or with a method on an unrelated class, counts as
  a reference. The function is then not reported.
- A method name built or stored indirectly, such as `var m := "foo"` followed by
  `obj.call(m)`, is not seen. The function would be reported.

---

## `--check-exports`

An `@export` that holds an object reference is null until something wires it in the
editor. Nothing guarantees that happened, and the failure lands at runtime, far
from the declaration. Reported as CRITICAL.

Two ways to satisfy it, both explicit. Null-guard the reference, or declare it
optional with `= null`. Optionality has to be written down rather than inferred.

Only object-typed exports are considered. The engine's property list separates
exported members from plain ones, and object types from built-ins, so
`@export var hp: int` is 0 and never reported.

**Where the guard must live depends on the base class.** A Node's exports are
populated as it enters the tree, so the guard must be in `_ready` or `_enter_tree`.
A guard in a helper that nothing calls protects nothing. A `Resource` has neither
callback, so any location in the script counts.

**Guard detection matches the test, not the mention.** A condition that merely
mentions the name, such as `if self.critters.any_enemy_walking:`, is not a guard.
Recognized forms are `x != null`, `null != x`, `assert(x, ...)`, `if x:`,
`if not x:` and `is_instance_valid(x)`.

### Limits

- Only guards in the same script count. If a parent or factory guarantees the
  wiring, the export is still reported.
- `= null` becomes load-bearing. It is the only way to say "optional".

---

## Testing

This repository has no test suite, so I built fixture projects instead. They cover
each way a construct can legitimately appear: inheritance chains, native and
script-class types, string-based and editor-wired references, binary resources,
multi-line argument lists, and the ignore directives. Each check also runs against
this addon and against a real game project.

Fixtures containing known-bad cases did most of the work. Three separate mistakes
during this work produced no findings at all while still exiting 0: a stale script
class cache, a type-inference error in a new checker, and a guard rule that was too
generous. All three looked exactly like a clean run.

For the same reason, one check was verified by mutation: I copied a real project,
deleted two real asserts, and confirmed both reappeared as findings. For a check
that reads type information from the engine, "reports nothing" and "is broken"
produce identical output, so both directions have to be proven.

## What I would like

I am not asking for a merge of this branch. If any of the checks look worth having,
I will open a focused pull request per check against `main`, without the
`copy.sh` tooling and with whatever changes you want first. I would rather agree on
the shape before writing that.

That includes agreeing on whether you want AI-written contributions here at all.
See the disclosure at the top.

I also opened issue #14 about `file-length` counting comments and blank lines,
which is unrelated to this branch.

User-facing documentation for everything here is in
`addons/gdscript-linter/docs/CLI.md`.
