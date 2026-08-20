# Branch notes — `nojaf`

This branch collects several additions to `graydwarf/godot-gdscript-linter`. It
started as work to offer upstream. It is not that any more, and this file was
rewritten to say so.

**This file is for us.** It records what each change does, why the linter is the
right place for it, and what it costs, so the reasoning survives being months
old. Two things still depend on it. Reapplying this work on a newer upstream
means knowing which of their files we touch and why, which is below. And if the
upstream conversation is ever worth reopening, this is the document that would
make it possible, so it is written to stay legible to someone who has never seen
the branch.

Branch point: `aeeae7d`, the tip of upstream `main` at the time.

## Written by an AI agent

Claude (Anthropic's coding agent) wrote all of the code on this branch, the
fixture projects, the documentation, and this file. Every commit carries a
`Co-Authored-By: Claude` trailer.

My role was product owner, not implementer. I said what I wanted. I supplied the
bugs from my own game project that motivated each check. I set constraints,
rejected designs I did not like, and approved what shipped. I did not write the
implementation.

This is recorded rather than buried because it changes how the branch should be
read: as code from a contributor whose reasoning cannot be interrogated directly.
Hence the design decisions written down throughout, and hence every claim about
engine behaviour being checked against Godot rather than reasoned about. If this
ever goes to the maintainer, they get to decide whether the project accepts
AI-written code at all, and that is a reasonable thing for them to refuse.

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

The last column is a judgment about each change on its own merits, kept from when
this was aimed upstream. It no longer means anything is going to be offered, only
how far each piece sits from something that could be.

| Change | Commits | Could stand alone upstream |
|--------|---------|------------------|
| `--sarif`: SARIF 2.1.0 output, plus `--spaces` and `--output` for machine formats | `9b0d139`, `e7a2f8d` | Yes |
| `--check-members`: verify member access, signal emit arity, uncalled predicates | `021d408`, `c5ecf83`, `e094370`, `c9e5012` | Only with the binary |
| `--check-unused-functions`: report functions nothing references | `0afb2e9`, `3a29a41`, `956129b`, `365c50b`, `c250b8d` | Only with the binary |
| `--check-exports`: object `@export` vars with no null guard | `83fc79d` | Only with the binary |
| `copy.sh`: install the addon into a project and generate a `lint.sh` wrapper | `9b672f3` | No, local workflow |
| `GDLintSourceIndex`: take source structure from `gdscript-formatter index` rather than regular expressions | `acfe210`, `7371318` | No, adds a dependency |
| `GDLintDeclarationSyntax`: recognise annotated and `static` declarations across the existing checkers | `92a5aa3`, `bfcf2fe`, `af84866` | Yes |

Every check is behind its own opt-in flag and off by default. No existing output,
exit code, config key or dock behavior changes. A user who does not pass the new
flags sees exactly what they saw before. That discipline is worth keeping now for
a different reason than the one it was adopted for: it is what makes reapplying
this branch on a newer upstream a mechanical job rather than a merge.

**The external binary is what settled it.** The three checks were written against
regular expressions first and later moved onto the index, which removed 26 regular
expressions and fixed several classes of bug. That move also made them depend on a
Rust binary, which is not something the upstream project should carry. The only
ways to offer them were to restore a text implementation, reintroducing the bugs,
or to ask upstream to accept the dependency. Neither is worth doing, which is most
of why the branch stays a fork.

`GDLintDeclarationSyntax` is the exception and stands alone. It fixes existing
checkers, needs no binary, and matches what was reported in upstream issue #15.
If any single piece here ever moves, it is that one.

The checks are CLI-only. None of them appear in the editor dock, because this
project is developed from an external editor and the dock never gets opened.

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

**A declared base type that is too wide is reported, once.** `var widget: Node`
holding a `Label`, then `self.widget.text`, is reported even though it runs: the
declaration is either missing a cast or wider than what it holds, and both fixes
keep the check working against the narrower type.

Reported per access, this drowns everything else. The addon's own source produced
95 CRITICAL findings from four declarations, none of which can fail at runtime,
and two of which carry the real type in a comment beside the wide annotation.
That is the check burying the bug it exists to find.

So findings for members read *through* another member's declared type are held
back and grouped by that member. The rule for what happens next is evidence, not
a threshold: every project class deriving from the declared type is scored by how
many of the unknown members it has, and the group folds only when exactly one
class has **all** of them. Then the object demonstrably holds something the
declaration failed to name, so one WARNING is reported at the declaration, naming
the class to narrow to. The 95 became 4.

```
dock.gd:88: 'settings_manager' is declared as RefCounted, but 27 members are read
            from it that RefCounted does not have (claude_code_command,
            claude_code_enabled, claude_custom_instructions, and 24 more).
            GDLintSettingsManager has all of them: narrow the declaration to it,
            or cast at the use sites.
```

Everything else stays exactly as it was, at CRITICAL, on its own line. A member
read off the script's own type is never folded, because a script's own type is
never too wide, which is what keeps `self.clock_labl` loud. Neither is a group
that no class explains: two misspellings on one correctly typed variable are two
bugs that happen to share a variable, not evidence of anything. And a lone
unknown member cannot be told apart from a typo at all, so it stays CRITICAL and
merely mentions the candidate type if one exists.

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

## `GDLintDeclarationSyntax`

One place answers "does this line start a declaration", and it tolerates
annotations and `static` in front of the keyword. Sixteen checks tested
`trimmed.begins_with("func ")` or the equivalent, so `@export var speed = 5` and
`@abstract func may_target(...)` were skipped silently. That is upstream issue
#15.

**Recognising the declaration turned out to be half of it.** Three checks then
read the declaration's contents off the raw line, where the first `(` or `:` can
belong to an annotation rather than to the declaration. Each one had been
unreachable while the declaration was being skipped, so fixing the recognition is
what exposed them:

- `too-many-params` counted `@rpc("any_peer") func handler(a, b, c, d, e, f)` as
  having one parameter, by measuring the annotation's argument list.
- `unused-parameter` reported `Parameter '""' is declared but never used` on the
  same line, that being what is left of `"any_peer"` after string literals are
  removed.
- `missing-type-hint` skipped `@export_file("res://levels/x.tscn") var p = ""`
  entirely. It tests for a colon before the `=` to decide whether a type was
  written, and the colon in `res://` answers yes.

The first two mean the repro in issue #15 was still not fully fixed here: its
`annotated_many_params` reported nothing where its plain twin reported six
parameters. All three now measure `GDLintDeclarationSyntax.after_keyword(...)`,
which has the prefix already removed.

Verified with matched pairs, each construct written plain and then annotated:
parameter counts and unused parameters agree across `@rpc("any_peer")`, `static`
and `@warning_ignore(...) static`, and all six untyped variable forms report while
all three typed ones stay silent. The addon is unchanged at 618 findings and a
game project at 23, neither with a `SCRIPT ERROR`.

### The ignore directive, still unreported upstream

A `# gdlint:ignore-function` above an annotated or `static` function does worse
than fail. `_find_function_range` scans forward for the next line starting with
`func `, and again from there to close the range, so on upstream the search runs
past the function the directive names and suppresses the next plain `func`
instead. Reproduced against 3.3.0: the named function is reported and a function
no directive mentions is silenced. Nothing closes the range but another plain
`func`, so if what follows is annotated or `static`, it runs to the end of the
file and takes those with it.

A comment saying so was drafted for issue #15 and not posted, before the wider
decision to leave upstream alone. It is worth knowing that this detail is not on
the issue, in case the conversation is ever reopened: what was filed describes a
directive that fails to bind, not one that binds to the wrong function. This
branch fixes both through the same helper, and all three shapes were rechecked
here to confirm it.

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
called, because there is no compiled script to ask. `script-load-failed` takes
both from the index for that reason. The one place the engine still wins is
resolving a member's declared type, where the script has to load for its members
to be read at all.

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

`_declared_class_name` could not come from the index at first, and that became
requirement 9. `class_name Foo` and a file-level `class Foo` both arrived as
`kind: "class"` with `scope: ""`, with no field separating them, so asking the
index which name a file declares had no reliable answer. The engine had one:
`ProjectSettings.get_global_class_list()` still lists the class name of a script
that fails to compile, and that map was already being built a few lines above as
`_global_classes`.

Verified the usual way. A fixture project of cascading failures produces the same
findings except the comment case above, which is the intended fix and moves one
root cause from four dependents to five. This addon and a second real project run
all three checks with identical findings, including that project's five
pre-existing load failures, and no new `SCRIPT ERROR` on either.

### Requirement 9, and the last thing the engine was doing here

The producer now marks the file's own class with `is_file_class`, and inner
classes no longer report the file's `extends` as their own. `declared_classes()`
builds the name-to-path map off that marker, and the fold reads it instead of the
engine's list.

This closes a gap that was real rather than theoretical. The global class list is
built at import, so a `class_name` written since the last `--import` is not in it.
Two new scripts, a broken `class_name NewBase` and a child extending it, added
without reimporting, reported as two unrelated failures. The same run now folds
them into one, no import needed. The index reads the files as they are on disk.

`is_file_class` is load-bearing rather than decorative, and it was checked by
removing it: with every `class` record registered, a script writing `extends
Ghost` folds into whichever file happens to contain an inner class of that name,
which is a fold Godot itself would never make.

`_global_classes` stays, for the other question. Resolving `var enemy: Enemy` to a
file means loading that file to read its members, so a class missing from the
import cache is unresolvable there whatever the index says. Two maps, two
questions: what a broken script is called, and what a working one contains.

The index skips `res://addons` unless an addon is the analysis target, so a base
class declared by an addon no longer folds. That is deliberate. Addon code is not
the code under analysis, and the cost is one extra finding rather than a wrong
one.

## Testing

`bun test` runs the suite, and `tests/README.md` says how to run it, what it
needs, and how to add a fixture. Unit assertions over the pure functions execute
inside Godot; four fixture projects each carry a `config` naming the flags to run
and a snapshot holding their findings. About ten seconds for all of it, and
`bun test --watch` while working on a checker.

The split between what is snapshotted and what is asserted is the design. The
invariants are explicit and never generated: the exit code, stderr free of
`SCRIPT ERROR`, and at least one finding. A snapshot of "nothing" is a perfectly
good snapshot, which is exactly the failure that has to stay impossible. Only
the content of the findings is snapshotted, because that is the part that was
hand-maintained badly: the `ignores` fixture was committed asserting three
findings exist at three lines and nothing about what they said.

A snapshot mismatch prints a diff of two blobs, which says the strings differ
rather than what changed. On failure the runner reads the stored snapshot and
reports which findings appeared, disappeared or changed wording, quoting the
fixture line each one points at, along with the flags it ran and how to accept
or inspect the result.

Each fixture pins a bug this project shipped: annotated and `static` declarations
being skipped, an ignore directive suppressing a function it does not name, a
cascade of load failures folding into its root cause, and the wide-declaration
fold together with the three cases that must not fold.

Two rules hold the suite up. Every fixture expects a non-zero number of findings,
and a run producing none fails outright, because an expectation of "nothing"
passes just as well when the check is broken. And stderr is asserted free of
`SCRIPT ERROR`, because that is where a throw goes while the report still looks
clean.

The suite was checked for teeth by reintroducing three real bugs one at a time.
Each fails exactly one fixture and no others. It then earned that immediately:
splitting `member-check.gd` broke three separate ways, and every one produced a
run that exited 0 with no findings.

The fixtures came out of the older habit described below, which is what the suite
replaces.

This repository had no test suite, so I built fixture projects instead. They cover
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

1. **Rebase onto a newer upstream, every few months.** The surface is nine
   modified files, seven of them one-line swaps to `GDLintDeclarationSyntax`. See
   "The rebase surface" below for the list and for how far upstream has moved.
   Nothing to do while it stays one unrelated commit ahead.

2. **The editor dock still does not know about any of this.** All three checks are
   CLI-only, by choice, because this project is developed from an external editor.
   Wiring them into the dock is work nobody has done.

3. **Watch for a schema that never moves.** `SUPPORTED_SCHEMA` is 1 and the
   producer keeps it there across incompatible changes on purpose. Recheck after
   every formatter change rather than trusting the guard: assert the fields the
   checks read, diff findings against a saved baseline, confirm stderr has no
   `SCRIPT ERROR`.

## Where this is going

**Not to the maintainer.** The branch has drifted too far to arrive as a
contribution: three of the checks need an external Rust binary, the checks are
CLI-only by choice, and `copy.sh` is a local workflow. Offering any of it would
mean a conversation about the dependency before a line of it could land. That
conversation is not happening, and pretending otherwise was shaping this document
badly. Two issues were filed upstream before that decision and stand on their
own: #15 on annotated declarations being skipped, and #14 on `file-length`
counting comments and blank lines.

**Staying on our own fork, rebased occasionally.** The expectation is to reapply
this work on a newer upstream every few months rather than to merge it anywhere.
That makes the divergence surface the thing to keep small and known, so it is
recorded here.

### The rebase surface

Nine upstream files are modified. Everything else we own outright, and a rebase
cannot conflict with it:

| Upstream file | What we changed |
|---------------|-----------------|
| `analyzer/analyze-cli.gd` | new flags, index construction, the three check entry points |
| `analyzer/checkers/function-checker.gd` | `GDLintDeclarationSyntax`, parameter counting |
| `analyzer/checkers/naming-checker.gd` | `GDLintDeclarationSyntax` |
| `analyzer/checkers/style-checker.gd` | `GDLintDeclarationSyntax`, the type-hint test |
| `analyzer/checkers/unused-checker.gd` | `GDLintDeclarationSyntax`, parameter extraction |
| `analyzer/code-analyzer.gd` | `GDLintDeclarationSyntax` |
| `analyzer/ignore-handler.gd` | `GDLintDeclarationSyntax` |
| `analyzer/strict-handler.gd` | `GDLintDeclarationSyntax` |
| `docs/CLI.md` | documents the new flags |

Seven of the nine are one-line-per-site swaps to `GDLintDeclarationSyntax`, which
makes them cheap to reapply and easy to spot if upstream rewrites the same lines.
`analyze-cli.gd` is the only one with real surgery in it. Files we add, and which
no rebase touches: `source-index.gd`, `member-check.gd`, `unused-function-check.gd`,
`export-check.gd`, `declaration-syntax.gd`, `copy.sh`,
`scripts/validate_sarif.py`, and this file.

As of the last rebase check, upstream `main` is one commit ahead of our branch
point (`e45b640`), and it adds a `project.json` we do not touch. Nothing to do
yet.

User-facing documentation for everything here is in
`addons/gdscript-linter/docs/CLI.md`.
