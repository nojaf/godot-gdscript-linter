# GDScript Linter - Claude Context

A fork of `graydwarf/godot-gdscript-linter` on branch `nojaf`. `BRANCH_NOTES.md`
says what this branch adds and why each piece is the way it is; read the section
for a check before changing it. `addons/gdscript-linter/docs/CLI.md` is the
user-facing reference for every flag and check id.

## Two repositories, one system

Source structure comes from `gdscript-formatter index`, a sub-command of the
sibling checkout at `../GDScript-formatter` (branch `nojaf`). Its record shapes,
and every requirement this linter has filed against it, are in
`../GDScript-formatter/docs/specification_index.md`. Types, members, signals and
scenes come from the Godot engine at run time. A check joins the two. Nothing on
this branch parses GDScript with regular expressions any more, and a new check
must not start.

If a check needs a fact about the source that the index does not carry, add it
on the formatter side first: a requirement in the spec, a collector under
`src/index/collectors/`, an exact-output test. Then consume it here through
`GDLintSourceIndex`. `scripts/install-formatter.sh` resolves the binary, by
default the release build in the sibling checkout, and never builds it: after a
formatter change, `cargo build --release` there before running the suite here.
There is no index version to bump: a shape change this side does not know about
fails a fixture, and that is the intended signal.

## Where things are

| Path | What |
|------|------|
| `addons/gdscript-linter/analyzer/analyze-cli.gd` | entry point: flags, help text, and one `_run_*` per index-backed check. The `if` that builds the index is the list of which checks need the formatter |
| `analyzer/checkers/*.gd` | upstream's line-based checks |
| `analyzer/*-check.gd` | this branch's checks |
| `analyzer/source-index.gd` | the index consumer; one bucket per record kind |
| `analyzer/scene-index.gd` | scenes read through the engine's `SceneState` |
| `analyzer/declaration-syntax.gd` | the one place that recognises a declaration line, shared by the upstream checkers |
| `tests/` | `bun test`; one fixture project per area under `tests/fixtures/<name>/`, findings in the snapshot. `tests/README.md` says how it works and how to add one |
| `copy.sh` | installs the addon into a game project and writes its `lint.sh`, which carries the default flags and a `NO_*_CHECK=1` switch per check |

## Adding a check

`export-check.gd` is the smallest and the template. The full surface a check
touches, so nothing is forgotten:

1. `analyzer/<name>-check.gd`: the check id as a constant, ignore-directive
   support, a `run(index, file_paths, respect_ignores)` entry.
2. `analyze-cli.gd`: the flag, its help line, the index-building `if`, a `_run_*`.
3. `tests/fixtures/<name>/`: `config`, a `src/` whose comments say what is
   reported and what stays silent, `generate.gd` if it needs scenes. Every
   deliberate silence should turn into a finding if its branch broke. Record
   with `bun test -t <name> -u`, then read the snapshot. `-u` with `-t`
   rewrites the whole snapshot file: restore it from git and run the full suite
   with `-u` instead.
4. `docs/CLI.md`: an options row, a section, a check-id row.
5. `copy.sh`: the default flag and its `NO_<X>_CHECK=1` switch in `lint.sh`.
6. `BRANCH_NOTES.md`: a section saying what the check catches, what it
   deliberately skips, and its limits; a row in the table; the file in the
   rebase surface.

Do not write counts of checks or fixtures into prose. They rot.

## Formatting

Every `.gd` file is formatted with the sibling `gdscript-formatter`, and the
test suite fails on drift. `.editorconfig` at the root carries the style and
excludes fixture sources, whose exact shape is what they test. After editing
GDScript:

```bash
"$(scripts/install-formatter.sh)" --verify-structure .
```

`--verify-structure` matters. The formatter refuses to write a file when its
output would parse differently, and two constructs in this codebase trigger
that: a lambda passed inline as an argument that is long enough to wrap, and a
method chain long enough to wrap with backslash continuations. Both are
formatter bugs, and both are avoided by writing the code differently: bind the
lambda to a local `Callable` first, and split a long chain over a local
variable. When a file "fails to format", that is what to look for.

## Verifying a change

Run the suite. Then install into a real game project with `copy.sh` and diff its
findings against the previous addon's, with all checks on. Read stderr for
`SCRIPT ERROR`: a check that throws collects nothing and its report looks clean.
Commit only in this repository, never in the game project.

## Ignore Directives

When adding gdlint:ignore directives, see
`addons/gdscript-linter/docs/IGNORE_RULES.md` for correct syntax and available
directive types.
