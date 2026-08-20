# Tests

```bash
bun test                    # everything, about ten seconds
bun test -t members         # one fixture
bun test --watch            # while working on a checker
```

The run prints which Godot and which formatter binary it used. Both matter, and
neither is obvious: the Godot found on `PATH` may not be the one you develop
against, and the formatter is rebuilt from a sibling checkout every run.

## What you need

- **Bun.** Nothing else from npm; there is no `package.json` and no install step.
- **Godot 4**, on `PATH` or as `/Applications/Godot.app`. Set `GODOT=/path/to/godot`
  to pin a specific one, which is worth doing if you have several installed.
- **The formatter**, checked out beside this repository. Three of the checks read
  source structure from `gdscript-formatter index` and cannot run without it, so
  the suite builds it rather than skipping them: a suite that quietly skips half
  its cases reports success while testing nothing. See
  `scripts/install-formatter.sh`, which the run calls for you and which explains
  itself if the checkout is missing.

Nothing needs importing first. Fixtures run in a fresh copy under a temporary
directory, and the repository is imported automatically if `.godot` is absent.

## Two kinds of test

**Unit** assertions live in `unit/run.gd` and run inside Godot, over the pure
functions in `GDLintDeclarationSyntax`. That file is the one eight checkers
depend on, and every regression in it has been silent: a declaration it fails to
recognise is not reported as an error, it is simply never checked.

**Fixtures** are small Godot projects under `fixtures/`. Each has a `config`
naming the flags to run, and its findings are held in a snapshot.

What each fixture is *for* is written in the fixture's own source, next to the
code that triggers it. Start there rather than here.

| Fixture | Pins |
|---|---|
| `declarations` | annotated and `static` declarations being skipped, and their contents being read off the raw line |
| `ignores` | an ignore directive suppressing a function it does not name |
| `broken` | a cascade of load failures folding into the script that broke |
| `members` | the wide-declaration fold, and the three cases that must not fold |
| `signatures` | a declaration wrapped across lines being read from its first line only |
| `exports` | every shape of null guard, and where a Node's guard has to live |
| `unused` | what keeps a function alive, including callers that are scene data rather than code |

## What is asserted, and what is snapshotted

The split is deliberate. Findings content is snapshotted, because it is long,
exact, and was hand-maintained badly before. The invariants are asserted
explicitly and are never generated:

- the exit code the fixture expects,
- stderr free of `SCRIPT ERROR` unless the fixture allows it,
- at least one finding.

That last one carries the weight. A snapshot of "nothing" is a perfectly good
snapshot, and the failure this project keeps hitting is a checker that throws,
collects nothing, exits 0 and looks exactly like a clean run. Every fixture is
written to produce findings, so producing none is a failure regardless of what
any snapshot says.

## When something fails

The runner reads the stored snapshot and reports what changed in the linter's
terms rather than as a text diff: which findings appeared, which disappeared,
and which kept their place but changed wording, each quoting the fixture line it
points at. It also prints the flags it ran.

If the new output is right, accept it:

```bash
bun test -t members -u
```

Read that diff before committing it. Regenerating an expectation is how a broken
check gets frozen into a suite, and `git diff` on the snapshot is the last place
anyone looks at it. It is also the only place: `-u` alongside `-t` rewrites the
whole snapshot file, so check what changed there rather than trusting the count
`bun test` prints.

To poke at the project a fixture ran against:

```bash
KEEP_WORK=1 bun test -t members     # prints the temporary directory, leaves it
```

## Adding a fixture

1. `mkdir fixtures/<name>`, and put an empty `project.godot` in it. Empty is
   correct — Godot fills in the rest on import.
2. Write the bad code under `src/`, and say in a comment there what should be
   reported and what should stay silent.
3. Write `config` with the flags. Narrow it with `--check <ids>` so the
   expectation is about the check under test rather than every style rule.
4. `bun test -t <name> -u` to record the findings, then **read them**. This is
   the step that decides what the test means.

If a fixture needs a scene or a binary resource, add a `generate.gd`. It runs
after the import and can build nodes and save them, so Godot writes those files
rather than anyone hand-authoring the format. Connections need
`Object.CONNECT_PERSIST` to survive packing.

Then break the thing on purpose and confirm the fixture fails. A test that has
never failed has not been tested.
