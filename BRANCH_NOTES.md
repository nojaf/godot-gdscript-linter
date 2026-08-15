# Branch notes — `sarif`

Local work on top of `graydwarf/godot-gdscript-linter`. This branch deviates from
`main` deliberately and is not tracking an upstream branch; this file is the record
of what was changed and why, so the deviation stays legible later.

Branch point: `aeeae7d` (tip of `main`).

## What is here

| Change | Commits | Upstreamable? |
|--------|---------|---------------|
| SARIF 2.1.0 output (`--sarif`), `--spaces <N>`, `scripts/validate_sarif.py` | `9b0d139` | Yes |
| `copy.sh` generates a `lint.sh` wrapper in the target project | `9b672f3` | No — local workflow |
| `--check-members`: verify `self.foo.bar` chains and signal emit arity | `021d408`, `c5ecf83` | Yes |
| `--check-unused-functions`: report functions nothing references | `0afb2e9`, `3a29a41`, `956129b` | Yes |
| `--check-exports`: object `@export` vars with no null guard | `83fc79d` | Yes |
| `--output` for `--sarif`/`--json` | see below | Yes |

Every feature is additive and behind an opt-in flag, so nothing changes for
existing users. `copy.sh` is purely local tooling and has no reason to go upstream.

**A theme worth stating once.** Several of these exist because Godot's own checking
is stricter than expected in some places and blind in others, and the only reliable
way to tell which was to test each case against the engine rather than reason about
it. Where the parser already covers something, these checks deliberately do not
duplicate it.

---

## SARIF output — `9b0d139`

`--sarif` / `--format sarif` emits SARIF 2.1.0 for GitHub code scanning and
JetBrains. Paths are repo-relative (`res://` stripped); severities map
CRITICAL→`error`, WARNING→`warning`, INFO→`note`. Exit codes unchanged.

`--spaces <N>` controls `json`/`sarif` indentation (`0` = compact, default tab).

`scripts/validate_sarif.py` is a stdlib-only structural and parity validator used
as the gate for the format.

### The stdout bug, and its fix

Originally shipped broken: the output was not valid JSON. Godot prints its version
banner to *stdout* before the script runs, so the documented
`--sarif > results.sarif` produced a file starting with `Godot Engine v4.7.1...`.
`--quiet` is not a fix — it silences the report along with the banner.

Fixed by making `--output/-o` work for `sarif` and `json` (it previously only
applied to `--html`), writing the payload straight to the file and never touching
stdout. The docs and CI examples now use `-o results.sarif` rather than a redirect.
Verified with `scripts/validate_sarif.py`, including result parity against `--json`.

---

## `copy.sh` generates `lint.sh` — `9b672f3`

Local workflow only. This project is developed with an external editor, so the
editor dock is not used and everything runs from the CLI.

`copy.sh <project>` installs the addon and writes a `lint.sh` into the target
project root that runs the linter over that project and forwards all arguments.

Three problems it solves, each worth knowing about:

**Godot is rarely on `PATH`.** The wrapper resolves `$GODOT`, then
`godot`/`godot4`/`godot-mono`/`godot4-mono`, then the macOS app bundles. The
Homebrew cask installs as `godot-mono`, which the first cut missed — it silently
fell through to a different Godot in `/Applications`.

**The script class cache goes stale.** The analyzer's checkers are `class_name`
globals that only resolve from `.godot/global_script_class_cache.cfg`, which
exists only after Godot has imported the project. With a stale cache every checker
fails to load *and the CLI still exits 0 with an empty report* — a silent
false-clean. `lint.sh` re-imports when the cache is missing or stale. Staleness is
driven by an `.installed-at` stamp because `rsync -a` preserves source mtimes, so
freshly copied files can look older than the cache.

**The `console` format hides most issues.** `_output_console` only lists critical,
`long-function`, pinned and TODO issues. A project whose findings fall outside
those lenses gets a summary count and nothing actionable. `lint.sh` therefore
defaults to `--clickable`, which lists everything; pass any explicit format
(including `--format console`) to override.

All three project-level checks are on by default, since the script exists to be
run before launching the game. `NO_MEMBER_CHECK=1`, `NO_UNUSED_CHECK=1` and
`NO_EXPORT_CHECK=1` skip them individually, `NO_LINT_SCRIPT=1` skips generating the
wrapper, and a hand-written `lint.sh` is never overwritten — only files carrying
the `generated-by:` marker are.

---

## `--check-members` — `021d408`, `c5ecf83`

A "will this actually run?" pass, intended right before launching the game.
Reports `script-load-failed`, `unknown-member` and `wrong-argument-count`, all
CRITICAL.

The motivating bug: `self.clock_label` where the member is `clock`. It compiles
clean and crashes on the first frame `_process` runs.

**Why the linter has to do this.** GDScript verifies none of these at parse time:

```gdscript
clock_labl.text = "x"        # Parse Error — caught
self.clock_labl.text = "x"   # clean — property access through self is runtime
self.clock.ziggy = "x"       # clean — property access on typed object vars
                             #         is not verified either
self.stopped_walking.emit()  # clean — signal emit arity is not verified
```

Only the first is caught. A codebase that writes `self.` on member access is opted
out of even that. Godot's `UNSAFE_PROPERTY_ACCESS` warning does not help — GDScript
warnings are editor-only, emitted neither by `--check-only` nor at runtime `load()`.

**How it resolves.** Member sets come from the engine, never from parsing
declarations: `get_script_property_list()` and friends (which already merge members
inherited from base scripts) plus `ClassDB` for the native base. Chains walk one
hop at a time using the declared type the property list reports — `Label` for
`var clock: Label`, `Tide` for a script class, resolved through the project's
global class list — and stop as soon as a type cannot be determined.

**Base types are reported on purpose.** `var widget: Node` holding a `Label`, then
`self.widget.text`, is flagged even though it runs. The declaration is either
missing a cast or wider than what it holds; both fixes keep the check working on
the narrower type.

**Method call arity is deliberately not checked**, and this was measured rather
than assumed. Godot's parser rejects `self.foo(1)`, bare `foo(1)` and
`self.typed_member.foo(1)` alike with "Too few arguments", which surfaces here as
`script-load-failed`. Only signal emits slip through — in both the `self.` and
unqualified forms — so only signal emits are checked. Signals have no default
arguments, so the expected count is exact. The one case neither catches is a call
through an untyped variable, which nothing can resolve.

**Limitations:** scripts overriding `_get_property_list`/`_set`/`_get` are skipped
entirely; loading runs `@tool` static initializers; a broken base script reports
only the root cause with a dependent count; a stale class cache makes everything
fail to load.

---

## `--check-unused-functions` — `0afb2e9`, `3a29a41`, `956129b`

Reports functions nothing in the project references, as a WARNING. Dead code does
not stop the game running, so it does not gate launching.

**Conservative by design.** Every occurrence of the name anywhere counts as a
reference — calls, bare `Callable` references, and names inside strings
(`call("foo")`). Comments are stripped first, so a function mentioned only in prose
is still dead. References are searched project-wide regardless of the analyzed
paths, so narrowing the scan cannot manufacture a false positive. The errors it
makes are misses, not bad advice to delete live code.

Never reported: engine virtuals, and placeholder bodies containing only `pass`
(the `empty-function` check covers those).

**Data-driven callers.** Godot calls methods by name from places that contain no
code: signal connections wired in the editor, and AnimationPlayer method tracks
firing from a timeline. Those live in `.tscn`/`.tres` while embedded, but become
binary `.res`/`.scn` once saved out — so binary files are scanned too, by pulling
identifier-shaped ASCII runs straight out of the bytes. That can only add
references, so a garbled read makes the check quieter rather than wrong.

**Self-references do not count** (`3a29a41`). Because names inside strings count,
a function returning its own name counted as its own caller and could never be
reported:

```gdscript
func unused_snowcat() -> String:
	return "unused_snowcat"
```

Mentions within a function's own body are now discounted, which also means a
function whose only caller is itself is correctly reported.

**The trap worth remembering:** `ClassDB.class_has_method("Node", "_ready")`
returns **false**, while `class_get_method_list("Node")` includes `_ready`.
`class_has_method` filters virtuals out. Using it here would have marked every
lifecycle override in the project as dead code.

Found four genuine dead functions in the addon itself — `get_location_string`,
`get_severity_icon` (`issue.gd`), `get_issues_for_file` (`analysis-result.gd`),
`_add_code_block` (`help-card-builder.gd`) — each appearing exactly once in the
whole repo. None in a real game project, no false positives in either.

---

## `--check-exports` — `83fc79d`

An `@export` holding an object reference is null until something wires it in the
editor. The failure lands at runtime, far from the declaration. CRITICAL.

Satisfied either by null-guarding the reference or by declaring it optional with
`= null`, so optionality is written down rather than inferred. Only object-typed
exports count — the engine's property list separates exported from plain members
and object types from built-ins, so `@export_range`, setters and every other
annotation form need no parsing, and `@export var hp: int` is 0, never null.

**Where the guard must live depends on the base class.** A Node's exports are
populated as it enters the tree, so the guard has to be in `_ready` or
`_enter_tree`; a guard in a helper nobody calls protects nothing. A `Resource` has
neither callback, so anywhere in the script counts.

**Guard detection matches the TEST, not the mention.** An earlier cut counted every
identifier in any `if` line, so `if self.critters.any_enemy_walking:` silently
excused `critters` forever. Recognized forms: `x != null`, `null != x`,
`assert(x, ...)`, `if x:`, `if not x:`, `is_instance_valid(x)`.

**Found by mutation testing, and worth repeating.** The fixtures missed that bug —
they only contained well-behaved guards. What caught it was copying a real project,
deleting two real asserts, and noticing only one of the two expected findings
appeared. For engine-backed checks, "reports nothing" and "is broken" look
identical, so both directions have to be proven.

---

## Testing

There is no test suite in this repo. These checks were verified against fixture
projects covering each way a construct can legitimately appear — inheritance
chains, native and script-class types, string-based and editor-wired references,
binary resources, multi-line argument lists, and the ignore directives — plus
dogfooding on the addon itself and on a real game project.

Keeping known-bad cases in the fixtures matters more than it sounds. Two separate
mistakes during this work produced *no findings at all* while still exiting
normally: a stale class cache, and a type-inference error in a new checker. Both
looked exactly like a clean run.

See `addons/gdscript-linter/docs/CLI.md` for the user-facing documentation.
