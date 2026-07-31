# Branch notes — `sarif`

Local work on top of `graydwarf/godot-gdscript-linter`. This branch deviates from
`main` deliberately and is not tracking an upstream branch; this file is the record
of what was changed and why, so the deviation stays legible later.

Branch point: `aeeae7d` (tip of `main`).

## What is here

| Commit | Change | Upstreamable? |
|--------|--------|---------------|
| `9b0d139` | SARIF 2.1.0 output (`--sarif`), `--spaces <N>`, `scripts/validate_sarif.py` | Yes |
| `9b672f3` | `copy.sh` generates a `lint.sh` wrapper in the target project | No — local workflow |
| `021d408` | `--check-members`: verify `self.foo.bar` chains resolve | Yes |

The two feature commits are additive and off by default (`--sarif` and
`--check-members` are opt-in flags), so they change nothing for existing users.
`copy.sh` is purely local tooling and has no reason to go upstream.

---

## `9b0d139` — SARIF output

`--sarif` / `--format sarif` emits SARIF 2.1.0 for GitHub code scanning and
JetBrains. Paths are repo-relative (`res://` stripped); severities map
CRITICAL→`error`, WARNING→`warning`, INFO→`note`. Exit codes unchanged.

`--spaces <N>` controls `json`/`sarif` indentation (`0` = compact, default tab).

`scripts/validate_sarif.py` is a stdlib-only structural and parity validator used
as the gate for the format.

**Known bug, unfixed:** the output is not valid JSON. Godot writes its version
banner to *stdout*, so the documented `--sarif > results.sarif` produces a file
starting with `Godot Engine v4.7.1...`. Reproduces without any other flag, so it
shipped with the feature. `--quiet` is not a fix — it silences the report too.
Needs either an `--output` path for SARIF or banner stripping in the caller.

---

## `9b672f3` — `copy.sh` generates `lint.sh`

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

Also defaults to `--check-members` (see below). `NO_MEMBER_CHECK=1` skips it,
`NO_LINT_SCRIPT=1` skips generating the wrapper, and a hand-written `lint.sh` is
never overwritten — only files carrying the `generated-by:` marker are.

---

## `021d408` — `--check-members`

A "will this actually run?" pass, intended right before launching the game.
Reports `script-load-failed` and `unknown-member`, both CRITICAL.

The motivating bug: `self.clock_label` where the member is `clock`. It compiles
clean and crashes on the first frame `_process` runs.

**Why the linter has to do this.** GDScript verifies neither case at parse time:

```gdscript
clock_labl.text = "x"       # Parse Error — caught
self.clock_labl.text = "x"  # clean — property access through self is runtime
self.clock.ziggy = "x"      # clean — property access on typed object vars
                            #         is not verified either
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

**Limitations:** scripts overriding `_get_property_list`/`_set`/`_get` are skipped
entirely; loading runs `@tool` static initializers; a broken base script reports
only the root cause with a dependent count; a stale class cache makes everything
fail to load.

See `addons/gdscript-linter/docs/CLI.md` for the user-facing documentation.

---

## Untracked local files

`local-docs/` is gitignored and holds working plans (e.g. `sarif-plan.md`).
