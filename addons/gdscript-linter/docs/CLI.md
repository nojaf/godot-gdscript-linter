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
godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- --sarif > results.sarif
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
| `--sarif` | Shorthand for `--format sarif` (SARIF 2.1.0, printed to stdout) |
| `--clickable` | Shorthand for `--format clickable` (Godot Output panel format) |
| `--html` | Shorthand for `--format html` |
| `--github` | Shorthand for `--format github` (GitHub Actions annotations) |
| `--output, -o <file>` | Output file path (for `--html`) |
| `--no-ignore` | Bypass all `gdlint:ignore` directives |
| `--check-members` | Load every script; report ones that fail to compile and `self.foo.bar` accesses that resolve to nothing |
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

## Member Checking (`--check-members`)

A "will this actually run?" pass, intended right before launching the game. Unlike
every other check it asks the engine rather than reading text, so it needs the files
on disk to be current and the project to have been imported.

```bash
godot --headless --script ... -- --check-members
```

It reports two things, both CRITICAL (exit code 2):

| Check | What it catches |
|-------|-----------------|
| `script-load-failed` | The script does not compile, so nothing in it can be checked. Godot's parse error goes to **stderr**; the linter adds the structured finding. Equivalent to running `--check-only` on every file at once. |
| `unknown-member` | A name in a `self.foo.bar` chain is not a member of the type it is read from. |

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

## Output Formats

### Console (default)

Human-readable report with summary, top files, and categorized issues.

### JSON

Machine-parseable output for integration with other tools:

```bash
godot --headless --script ... -- --json > report.json
```

### SARIF

Standard [SARIF 2.1.0](https://sarifweb.azurewebsites.net/) output, printed to stdout. Integrates with GitHub code scanning, JetBrains IDEs, and other SARIF-aware tools:

```bash
godot --headless --script ... -- --sarif > results.sarif
```

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
		  godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- --sarif > results.sarif
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
	- godot --headless --script res://addons/gdscript-linter/analyzer/analyze-cli.gd -- --format json > lint-report.json
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
