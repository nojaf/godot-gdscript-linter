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

My role was product owner, not implementer. I said what I wanted. I supplied
the bugs from my own game project that motivated each check. I set constraints,
rejected designs I did not like, and approved what shipped. I did not write the
implementation.

I am stating this plainly because it changes how you should review it. Treat
this as code from a contributor whose reasoning you cannot interrogate
directly. This file documents each design decision, so you can judge it on the
merits rather than on trust. I also checked every claim about engine behavior
against Godot.

You can also decide that this project does not accept AI-written code. That is
a reasonable position. I would rather hear it now than after a pull request.

## How to try it

The three checks need a second tool. They read source structure from
`gdscript-formatter index`, a sub-command of a fork of GDQuest's formatter:
<https://github.com/nojaf/GDScript-formatter/tree/nojaf>. Build that first, then:

```bash
git clone -b nojaf https://github.com/nojaf/godot-gdscript-linter
# copy addons/gdscript-linter/ into a Godot project, then:
export GDLINT_FORMATTER=/path/to/gdscript-formatter
godot --headless --path <project> --import
godot --headless --path <project> --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- \
    --check-members --check-unused-functions --check-exports --clickable
```

The `--import` step matters. The checks read type information from the engine,
and that requires the project's script class cache to exist.

Without the binary the run stops with exit 3 and says so. It never falls back to
checking less, because reporting nothing looks exactly like a clean project.

## What is here

| Change | Commits | Offered upstream |
|--------|---------|------------------|
| `--sarif`: SARIF 2.1.0 output, plus `--spaces` and `--output` for machine formats | `9b0d139`, `e7a2f8d` | Yes |
| `--check-members`: verify member access, signal emit arity, uncalled predicates | `021d408`, `c5ecf83`, `e094370`, `c9e5012` | Yes |
| `--check-unused-functions`: report functions nothing references | `0afb2e9`, `3a29a41`, `956129b`, `365c50b`, `c250b8d` | Yes |
| `--check-exports`: object `@export` vars with no null guard | `83fc79d` | Yes |
| `copy.sh`: install the addon into a project and generate a `lint.sh` wrapper | `9b672f3` | No, local workflow |
| `GDLintSourceIndex`: take source structure from `gdscript-formatter index` rather than regular expressions | `acfe210`, `7371318` | No, adds a dependency |
| `GDLintDeclarationSyntax`: recognise annotated and `static` declarations across the existing checkers | `92a5aa3`, `bfcf2fe` | Yes |

Every check is behind its own opt-in flag and off by default. No existing output,
exit code, config key or dock behavior changes. A user who does not pass the new
flags sees exactly what they saw before.

**The external binary changes the upstream story.** The three checks were written
against regular expressions first and later moved onto the index, which removed 26
regular expressions and fixed several classes of bug. That move also made them
depend on a Rust binary, which is not something this project should carry. Offering
any of them upstream means either restoring a text-based implementation, which
reintroduces the bugs listed above, or upstream accepting the dependency. That
question is open and worth settling before writing a pull request.

`GDLintDeclarationSyntax` is the exception and stands alone. It fixes existing
checkers, needs no binary, and matches what was reported in upstream issue #15.

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

Chains work with or without the `self.` prefix. For an unqualified chain, the root identifier must be a member of the script. A
local variable, a parameter or a loop variable in the same function must not
shadow it.

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

Declarations are matched with any annotations in front of them. `@abstract func
may_target(...)` on one line has to register, and a pattern anchored at `func`
misses it silently: the declaration never counts, while its text still counts as a
reference that keeps every implementation looking alive. Adding `@abstract` to a
project would otherwise make those methods permanently exempt.

A name declared in several places is reported once, at the first declaration, with
the number of sites. An `@abstract` declaration plus its implementations is one
dead contract, not one warning per file.

Two things are never reported. Engine virtuals are identified by asking `ClassDB`
what the native base class declares. Placeholder bodies containing only `pass` are
left to the existing `empty-function` check.

### Callers that are data, not code

Godot calls methods by name from places that contain no code. Signal connections wired in the editor and AnimationPlayer method tracks live
in `.tscn` and `.tres` while embedded. Saved separately, they become binary
`.res` or `.scn` files.
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

## The two-repo split

Structure and meaning come from different places, and keeping that straight is the
main thing to understand before changing any check.

`gdscript-formatter index` knows where everything is written: declarations with
their annotations and modifiers, member chains with a `kind` per segment, argument
lists, string literals with the call they are an argument of, comparisons,
comments, each with a range and a dotted `scope` such as `Inner._ready`, and what
each file extends. It knows nothing about types.

The Godot engine knows what things mean: every member of a class including
inherited ones, declared types, signal arity, which exports can hold null, which
methods are engine virtuals, whether a script compiles. It knows none of it by
line number.

A check joins the two. `unknown-member` needs the member set from the engine and
the chain position from the index. Neither half alone is enough, and the half that
used to be faked with regular expressions is where every bug came from.

The split is not always this clean. A script that fails to compile has structure
and no meaning at all: the engine cannot say what it extends, or what it is
called, because there is no compiled script to ask. `script-load-failed` reads the
base from the index for that reason, and the class name from the project's global
class list, which the engine keeps whether or not the script compiles.

Design and open requirements for the index live in the formatter fork at
`docs/specification_index.md`.

### Where requirement 7 leaves things

Requirement 7 is implemented. `extends` now appears in two places, holding the
base as written:

```jsonl
{"record": "file",        "schema": 1, "path": "res://hud/hud.gd", "extends": "Node"}
{"record": "declaration", "kind": "class", "name": "Hud", "extends": "Node", ...}
```

The producer described this as a breaking change while leaving `schema` at 1. It
was rechecked here field by field and end to end: every field the checks read is
unchanged, a real game project matches its baseline exactly, the addon's
member-check findings are unchanged at 95, and neither run produces a
`SCRIPT ERROR`. For this consumer the change was additive.

Requirement 8 was filed as a result and is now settled, as policy rather than as a
bump. `schema` stays at 1 by decision: the silent-wrong-answer failure needs a
consumer running an older build, and there is not one, since both sides are
rebuilt together and neither is in production. The spec records the rule for when
to bump, the conditions that end the current arrangement, and a table of every
shape change made under version 1 so an unexpected build can be diagnosed.

**What that means in practice.** The addon's version guard is deliberately inert
for now. `SUPPORTED_SCHEMA` is 1 and will keep matching across incompatible
changes, so it cannot be relied on to catch a mismatched build. Until the number
starts moving, the real safety net is rechecking after every formatter change:
assert the fields the checks read, diff findings against a saved baseline, and
confirm stderr is free of `SCRIPT ERROR`. That was done for both requirement 7 and
requirement 8, and both came back identical.

**What that unlocked.** `member-check.gd` has no regular expressions left in it.
The last two, `_declared_class_name` and `_declared_base`, folded cascading load
failures into their root cause, and both are gone.

`_declared_base` was the straightforward half. `GDLintSourceIndex._start_file`
now keeps the header's `extends`, and `file_extends()` hands it back with the
quotes taken off an `extends "res://enemy.gd"`. That alone fixed a bug. The old
pattern matched the first `extends` anywhere in the file, comments and strings
included, so a script that mentioned the word above its real header line was
reported as its own root cause instead of being folded into the script that
actually broke.

`_declared_class_name` could not come from the index, and this is the part of
requirement 7 that did not land. `class_name Foo` and a file-level `class Foo`
both arrive as `kind: "class"` with `scope: ""`, and no field separates them, so
asking the index which name the file declares has no reliable answer. The engine
has one: `ProjectSettings.get_global_class_list()` still lists the class name of
a script that fails to compile, which was the whole reason for reading text here.
That map was already being built a few lines above, as `_global_classes`, and is
now what the fold reads.

The trade is worth writing down. The global class list comes from the import
cache, so a `class_name` added since the last `--import` is not in it, and the
fold then reports each failure separately. Noisier, never wrong. The text scan
read the current file and had no such gap, but it also counted `class_name` in a
comment.

Verified the usual way. A fixture project of cascading failures produces the same
findings except the comment case above, which is the intended fix and moves one
root cause from four dependents to five. This addon and a second real project run
all three checks with identical findings, including that project's five
pre-existing load failures, and no new `SCRIPT ERROR` on either.

## Testing

This repository has no test suite, so I built fixture projects instead. They cover
each way a construct can legitimately appear: inheritance chains, native and
script-class types, string-based and editor-wired references, binary resources,
multi-line argument lists, and the ignore directives. Each check also runs against
this addon and against a real game project.

Fixtures containing known-bad cases did most of the work. Several mistakes during
this work produced no findings at all while still exiting 0: a stale script class
cache, a type-inference error in a new checker, a guard rule that was too generous,
a path-prefix mismatch between `res://foo.gd` and `foo.gd`, and a method name that
collided with a built-in. All of them looked exactly like a clean run.

**Verify by diffing findings against a saved baseline, and check stderr.** Both
halves are needed. The name collision threw on every function line, so a checker
silently collected nothing, and the finding diff still matched its baseline
because a check that collects nothing produces nothing to differ. The error was
printed the whole time to the stream the diff was discarding. A verification run
should assert that stderr contains no `SCRIPT ERROR` as well as comparing
findings.

For the same reason, one check was verified by mutation: I copied a real project,
deleted two real asserts, and confirmed both reappeared as findings. For a check
that reads type information from the engine, "reports nothing" and "is broken"
produce identical output, so both directions have to be proven.

## Open items

Nothing here is blocking. Ordered by how ready each is to pick up.

1. **Ask the index to tell a `class_name` apart from an inner `class`.** Both
   arrive as `kind: "class"` with `scope: ""`, and nothing on the record says
   which is which, so the index cannot answer which name a file declares.
   Requirement 7 was filed to retire the consumer's text scan for `class_name`
   and `extends`; it settled `extends` and left this half. Nothing is blocked by
   it, because the name now comes from the engine's global class list instead,
   and that is arguably the better source anyway. A marker on the record, or a
   separate `kind`, would close it. Worth filing as requirement 9 on the
   formatter.

2. **Add the over-suppression detail to upstream issue #15.** The issue reports
   that `gdlint:ignore-function` fails to bind above an annotated or `static`
   function. What was found afterwards is worse: the directive's range runs past
   the unrecognised declaration to the next plain `func`, so it suppresses a
   function it does not name. A fixture with three directives and four print
   statements reported none of them, including the one no directive covered. That
   is a stronger case than what was filed and belongs in a comment.

3. **Decide the upstream story for the three checks.** They now depend on the
   `gdscript-formatter` binary, which this project should not carry. Offering any
   of them means restoring a text implementation, which reintroduces the bugs
   listed above, or upstream accepting the dependency. `GDLintDeclarationSyntax`
   is unaffected and can be offered on its own.

4. **The editor dock still does not know about any of this.** All three checks are
   CLI-only, by choice, because this project is developed from an external editor.
   Anyone wanting them in the dock has that work ahead.

5. **Watch for a schema that never moves.** `SUPPORTED_SCHEMA` is 1 and the
   producer keeps it there across incompatible changes on purpose. Recheck after
   every formatter change rather than trusting the guard: assert the fields the
   checks read, diff findings against a saved baseline, confirm stderr has no
   `SCRIPT ERROR`.

## What I would like

I am not asking for a merge of this branch. If any of the checks look worth having, I will open one pull request per check
against `main`. Each would exclude the `copy.sh` tooling and include the
changes you ask for. I would rather agree on
the shape before writing that.

That includes agreeing on whether you want AI-written contributions here at all.
See the disclosure at the top.

I also opened issue #14 about `file-length` counting comments and blank lines,
which is unrelated to this branch.

User-facing documentation for everything here is in
`addons/gdscript-linter/docs/CLI.md`.
