#!/usr/bin/env bash
# install-formatter.sh — build the gdscript-formatter this linter depends on, and
# print the path to the binary.
#
# Three of the checks (--check-members, --check-unused-functions, --check-exports)
# read source structure from `gdscript-formatter index`, a sub-command that only
# exists on the fork at <https://github.com/nojaf/GDScript-formatter/tree/nojaf>.
# The two repositories are one system in two languages, so this makes the coupling
# explicit rather than leaving each caller to guess where the binary lives.
#
# The default assumption is that both repositories sit in the same parent folder:
#
#   ~/Projects/godot-gdscript-linter     <- this one
#   ~/Projects/GDScript-formatter        <- the formatter fork
#
# Usage:
#   GDLINT_FORMATTER="$(scripts/install-formatter.sh)"    # build, then use it
#   scripts/install-formatter.sh --no-build               # verify only
#
# The binary path is the ONLY thing written to stdout, so the command above works.
# Progress and errors go to stderr.
#
# Environment:
#   GDLINT_FORMATTER       pin a binary; it is verified but never rebuilt
#   GDLINT_FORMATTER_REPO  where the formatter checkout lives
#
# Exit codes: 0 ready, 1 usage, 2 checkout missing, 3 cannot build, 4 wrong build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(dirname "$REPO_ROOT")"
CANDIDATE_NAMES=("GDScript-formatter" "gdscript-formatter")

BUILD=1
case "${1:-}" in
	--no-build) BUILD=0 ;;
	"") ;;
	*) echo "usage: $0 [--no-build]" >&2; exit 1 ;;
esac

say() { echo "install-formatter: $*" >&2; }
die() { echo "install-formatter: error: $2" >&2; exit "$1"; }

# A binary from the wrong branch, or from GDQuest's original, has no `index`
# sub-command. It would otherwise fail later as a confusing parse error, so the
# capability is what gets tested rather than the version string.
#
# The exit code alone proves nothing: anything that ignores its arguments and
# exits 0, `/bin/echo` included, would pass. So the help text has to mention
# --project-root, which is the flag the addon actually passes.
verify_supports_index() {
	"$1" index --help 2>/dev/null | grep -q -- '--project-root'
}

# A pinned binary is taken as given, beyond checking it can do the job. Whoever
# set the variable knows something this script does not.
if [ -n "${GDLINT_FORMATTER:-}" ]; then
	[ -x "$GDLINT_FORMATTER" ] || die 4 "GDLINT_FORMATTER is not executable: $GDLINT_FORMATTER"
	verify_supports_index "$GDLINT_FORMATTER" \
		|| die 4 "GDLINT_FORMATTER has no 'index' sub-command: $GDLINT_FORMATTER
  That is either GDQuest's formatter or a build from the wrong branch.
  The linter needs the fork: https://github.com/nojaf/GDScript-formatter/tree/nojaf"
	say "using pinned GDLINT_FORMATTER, not rebuilding"
	printf '%s\n' "$GDLINT_FORMATTER"
	exit 0
fi

find_checkout() {
	if [ -n "${GDLINT_FORMATTER_REPO:-}" ]; then
		printf '%s\n' "${GDLINT_FORMATTER_REPO%/}"
		return 0
	fi
	local name
	for name in "${CANDIDATE_NAMES[@]}"; do
		if [ -d "$PARENT_DIR/$name" ]; then
			printf '%s\n' "$PARENT_DIR/$name"
			return 0
		fi
	done
	return 1
}

if ! FORMATTER_REPO="$(find_checkout)"; then
	die 2 "no formatter checkout found beside this repository.
  Looked in: ${CANDIDATE_NAMES[*]/#/$PARENT_DIR/}
  Clone it as a sibling of $REPO_ROOT:
    git clone -b nojaf https://github.com/nojaf/GDScript-formatter
  Or point GDLINT_FORMATTER_REPO at an existing checkout."
fi

[ -d "$FORMATTER_REPO" ] || die 2 "not a directory: $FORMATTER_REPO"

# Confirm this is the formatter and not some other sibling that happens to match
# the name, before running cargo inside it.
CARGO_TOML="$FORMATTER_REPO/Cargo.toml"
[ -f "$CARGO_TOML" ] || die 2 "no Cargo.toml in $FORMATTER_REPO — is that the formatter checkout?"
grep -q '^name *= *"gdscript-formatter"' "$CARGO_TOML" \
	|| die 2 "$FORMATTER_REPO does not look like gdscript-formatter (Cargo.toml names a different package)"

BINARY="$FORMATTER_REPO/target/release/gdscript-formatter"

if [ "$BUILD" -eq 1 ]; then
	command -v cargo >/dev/null 2>&1 \
		|| die 3 "cargo not found on PATH, needed to build $FORMATTER_REPO
  Install Rust from https://rustup.rs, or pass --no-build to use an existing binary."
	say "building $FORMATTER_REPO (release)"
	# Building on every run is deliberate. The index format is versioned by policy
	# rather than by a number that moves (schema stays at 1), so the guard against
	# a mismatched producer is that both sides are rebuilt together. An up-to-date
	# build costs about two tenths of a second.
	( cd "$FORMATTER_REPO" && cargo build --release ) >&2 \
		|| die 3 "cargo build failed in $FORMATTER_REPO"
fi

[ -x "$BINARY" ] || die 3 "no binary at $BINARY
  Run this script without --no-build, or build it by hand:
    cd $FORMATTER_REPO && cargo build --release"

verify_supports_index "$BINARY" \
	|| die 4 "$BINARY has no 'index' sub-command.
  The checkout at $FORMATTER_REPO is probably on the wrong branch.
  The linter needs the 'nojaf' branch:
    cd $FORMATTER_REPO && git checkout nojaf && cargo build --release"

say "ready: $BINARY"
printf '%s\n' "$BINARY"
