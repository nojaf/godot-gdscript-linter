#!/usr/bin/env bash
# install-formatter.sh — build the gdscript-formatter this linter depends on, and
# print the path to the binary.
#
# The index-backed checks read source structure from `gdscript-formatter index`,
# a sub-command that only exists on the fork at
# <https://github.com/nojaf/GDScript-formatter/tree/nojaf>. Which checks those
# are is decided in analyzer/analyze-cli.gd, where the index is built.
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

# The crate is edition 2024, which needs rustc 1.85 or newer. A distro package
# named rustc is frequently older, and the cargo error for that names no remedy.
rustc_at_least() {
	local have="$1" want="$2"
	local h_major="${have%%.*}" h_minor="${have#*.}"; h_minor="${h_minor%%.*}"
	local w_major="${want%%.*}" w_minor="${want#*.}"; w_minor="${w_minor%%.*}"
	[ "$h_major" -gt "$w_major" ] && return 0
	[ "$h_major" -eq "$w_major" ] && [ "$h_minor" -ge "$w_minor" ]
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
  Install Rust: rustup (https://rustup.rs) or mise (mise use -g rust).
  Or pass --no-build to use an existing binary."

	# tree-sitter compiles C sources, so a linker and compiler are needed even
	# though nothing here is written in C. Minimal Linux images and CI
	# containers often ship without one.
	if ! command -v cc >/dev/null 2>&1 \
		&& ! command -v gcc >/dev/null 2>&1 \
		&& ! command -v clang >/dev/null 2>&1; then
		die 3 "no C compiler on PATH, needed to build tree-sitter
  Debian/Ubuntu: sudo apt install build-essential
  Fedora: sudo dnf install gcc
  Arch: sudo pacman -S gcc
  macOS already has one with the Xcode command line tools."
	fi

	RUSTC_VERSION="$(rustc --version 2>/dev/null | awk '{print $2}')" || RUSTC_VERSION=""
	case "$RUSTC_VERSION" in
		[0-9]*.[0-9]*)
			rustc_at_least "$RUSTC_VERSION" 1.85 \
				|| die 3 "rustc $RUSTC_VERSION is too old: gdscript-formatter is edition 2024 and needs 1.85+
  Run: rustup update stable, or with mise: mise use -g rust@1.85
  A distro rustc package is usually older than the edition needs.
  Or pass --no-build to use an existing binary." ;;
		*)
			die 3 "rustc not found or unreadable, although cargo is.
  Install a matching toolchain: rustup update stable, or mise use -g rust@1.85" ;;
	esac

	say "building $FORMATTER_REPO (release)"
	# Building on every run is deliberate. The index format is versioned by policy
	# rather than by a number that moves (schema stays at 1), so the guard against
	# a mismatched producer is that both sides are rebuilt together. An up-to-date
	# build costs about two tenths of a second.
	# --bin limits that rebuild to the CLI the linter runs, skipping the
	# gdextension member (the in-editor distribution) and the benchmark and
	# release-helper binaries, which this script's contract says nothing about.
	( cd "$FORMATTER_REPO" && cargo build --release --bin gdscript-formatter ) >&2 \
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
