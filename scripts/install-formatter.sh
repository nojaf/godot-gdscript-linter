#!/usr/bin/env bash
# install-formatter.sh: find the gdscript-formatter this linter depends on, check
# it can do the job, and print its path.
#
# The index-backed checks read source structure from `gdscript-formatter index`,
# a sub-command that only exists on the fork at
# <https://github.com/nojaf/GDScript-formatter/tree/nojaf>. Which checks those
# are is decided in analyzer/analyze-cli.gd, where the index is built.
#
# Building the formatter is not this script's business. It is a locally built
# binary that you keep current. The usual layout is both checkouts side by side:
#
#   ~/Projects/godot-gdscript-linter     <- this one
#   ~/Projects/GDScript-formatter        <- the fork, on branch nojaf
#
# and a `cargo build --release` there is all the install step there is.
#
# Usage:
#   GDLINT_FORMATTER="$(scripts/install-formatter.sh)"
#
# The binary path is the ONLY thing written to stdout. Errors go to stderr.
#
# Resolution order:
#   1. GDLINT_FORMATTER, if set
#   2. the sibling checkout's target/release/gdscript-formatter
#   3. gdscript-formatter on PATH
#
# Exit codes: 0 ready, 2 not found, 4 found but cannot `index`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIBLING="$PARENT_DIR/GDScript-formatter/target/release/gdscript-formatter"

die() { echo "install-formatter: error: $2" >&2; exit "$1"; }

# A binary from the wrong branch, or from GDQuest's original, has no `index`
# sub-command. It would otherwise fail later as a confusing parse error, so the
# capability is what gets tested rather than the version string.
#
# The exit code alone proves nothing: anything that ignores its arguments and
# exits 0, `/bin/echo` included, would pass. So the help text has to mention
# --project-root, which is the flag the addon actually passes.
supports_index() {
	"$1" index --help 2>/dev/null | grep -q -- '--project-root'
}

if [ -n "${GDLINT_FORMATTER:-}" ]; then
	BINARY="$GDLINT_FORMATTER"
	[ -x "$BINARY" ] || die 2 "GDLINT_FORMATTER is not executable: $BINARY"
elif [ -x "$SIBLING" ]; then
	BINARY="$SIBLING"
elif ! BINARY="$(command -v gdscript-formatter)"; then
	die 2 "no gdscript-formatter found.
  Looked for: $SIBLING, then PATH, and GDLINT_FORMATTER is not set.
  The linter needs the fork, branch nojaf, checked out beside this repository:
    cd $PARENT_DIR && git clone -b nojaf https://github.com/nojaf/GDScript-formatter
    cd GDScript-formatter && cargo build --release
  Or set GDLINT_FORMATTER=/path/to/gdscript-formatter."
fi

supports_index "$BINARY" \
	|| die 4 "$BINARY has no 'index' sub-command.
  That is either GDQuest's formatter or a build from the wrong branch.
  The linter needs the fork: https://github.com/nojaf/GDScript-formatter/tree/nojaf
    cd <checkout> && git checkout nojaf && cargo build --release"

printf '%s\n' "$BINARY"
