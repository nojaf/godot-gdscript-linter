#!/usr/bin/env python3
"""Run the linter's test suite.

    tests/run.py                 everything
    tests/run.py members broken  only the named fixtures
    tests/run.py --update        rewrite expectations, showing the diff first

Two kinds of test:

  unit      pure functions, asserted from inside Godot, no fixture project
  fixtures  a small Godot project each, linted, compared against `expect`

Every fixture expects a non-zero number of findings on purpose. A case whose
expectation is "nothing" passes just as well when the check under test is
broken, which is the failure this repository keeps hitting: a checker that
throws collects nothing, exits 0 and looks exactly like a clean project. For
the same reason stderr is asserted to be free of SCRIPT ERROR unless the
fixture says otherwise, because that is where the throw goes.

Fixtures run in a fresh copy under a temporary directory. Nothing is imported
in place, so a stale script class cache cannot make a run look clean.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(REPO, "tests", "fixtures")
ADDON = os.path.join(REPO, "addons", "gdscript-linter")
ANALYZER = "res://addons/gdscript-linter/analyzer/analyze-cli.gd"

GODOT_CANDIDATES = [
    "godot", "godot4", "godot-mono", "godot4-mono", "Godot",
    "/Applications/Godot.app/Contents/MacOS/Godot",
    os.path.expanduser("~/Applications/Godot.app/Contents/MacOS/Godot"),
    "/Applications/Godot_mono.app/Contents/MacOS/Godot",
]


class Failure(Exception):
    pass


def find_godot():
    if os.environ.get("GODOT"):
        return os.environ["GODOT"]
    for candidate in GODOT_CANDIDATES:
        found = shutil.which(candidate) if "/" not in candidate else (
            candidate if os.access(candidate, os.X_OK) else None)
        if found:
            return found
    raise Failure("no Godot binary found; put godot on PATH or set GODOT")


def find_formatter():
    """The formatter is a hard requirement, not something to skip around.

    Three of the checks cannot run without it, and a suite that quietly skips
    them reports success while testing nothing.
    """
    installer = os.path.join(REPO, "scripts", "install-formatter.sh")
    result = subprocess.run([installer], capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise Failure("scripts/install-formatter.sh failed; the suite needs the "
                      "formatter binary for the index-backed checks")
    return result.stdout.strip()


def parse_expect(path):
    """`expect` is directives, then one `<file>:<line> <check-id>` per line.

        # flags: --check-members
        # target: res://src
        # exit: 2
        # allow-script-errors: yes
        src/probe.gd:7 unknown-member
        src/probe.gd:4 unknown-member ~ FoldSettings has all of them

    A `~` suffix asserts the message contains that text, for the cases where
    the wording is the feature rather than incidental.
    """
    config = {
        "flags": [],
        "target": "res://src",
        "exit": None,
        "allow_script_errors": False,
    }
    findings = []
    with open(path) as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("#"):
                directive = line.lstrip("#").strip()
                if ":" not in directive:
                    continue
                key, _, value = directive.partition(":")
                key, value = key.strip(), value.strip()
                if key == "flags":
                    config["flags"] = value.split()
                elif key == "target":
                    config["target"] = value
                elif key == "exit":
                    config["exit"] = int(value)
                elif key == "allow-script-errors":
                    config["allow_script_errors"] = value.lower() in ("yes", "true", "1")
                continue
            where, _, rest = line.partition(" ")
            check, _, message = rest.partition("~")
            findings.append((where, check.strip(), message.strip()))
    return config, findings


def format_findings(findings):
    lines = []
    for where, check, message in findings:
        lines.append(f"{where} {check}" + (f" ~ {message}" if message else ""))
    return lines


def actual_findings(report):
    """Findings as (file:line, check-id), stripped of res:// and sorted.

    Fixture sources barely change, so a line number is real information here:
    if a finding moves, something moved it. That is the opposite of the self
    lint, where line numbers shift constantly and only counts are stable.
    """
    out = []
    for issue in report["issues"]:
        path = issue["file_path"].replace("res://", "")
        out.append((f"{path}:{issue['line']}", issue["check_id"], issue["message"]))
    out.sort(key=lambda item: (item[0].rsplit(":", 1)[0],
                               int(item[0].rsplit(":", 1)[1]), item[1]))
    return out


def run_fixture(name, godot, formatter, update):
    fixture = os.path.join(FIXTURES, name)
    expect_path = os.path.join(fixture, "expect")
    if not os.path.isfile(expect_path):
        raise Failure(f"{name}: no expect file")
    config, expected = parse_expect(expect_path)

    work = tempfile.mkdtemp(prefix=f"gdlint-test-{name}-")
    try:
        for entry in os.listdir(fixture):
            if entry in ("expect", "generate.gd"):
                continue
            source = os.path.join(fixture, entry)
            target = os.path.join(work, entry)
            if os.path.isdir(source):
                shutil.copytree(source, target)
            else:
                shutil.copy2(source, target)
        os.makedirs(os.path.join(work, "addons"), exist_ok=True)
        shutil.copytree(ADDON, os.path.join(work, "addons", "gdscript-linter"))

        env = dict(os.environ, GDLINT_FORMATTER=formatter)
        subprocess.run([godot, "--headless", "--path", work, "--import"],
                       capture_output=True, text=True, env=env)

        # A generator runs after the import so it can load scripts, and writes
        # scenes and binary resources with Godot's own serialisation rather
        # than any hand-authored idea of those formats.
        generator = os.path.join(fixture, "generate.gd")
        if os.path.isfile(generator):
            shutil.copy2(generator, os.path.join(work, "generate.gd"))
            made = subprocess.run(
                [godot, "--headless", "--path", work, "--script", "res://generate.gd"],
                capture_output=True, text=True, env=env)
            if made.returncode != 0:
                raise Failure(f"{name}: generate.gd failed\n{made.stderr}")
            subprocess.run([godot, "--headless", "--path", work, "--import"],
                           capture_output=True, text=True, env=env)

        report_path = os.path.join(tempfile.gettempdir(), f"gdlint-report-{name}.json")
        # Written outside the project on purpose: a report left inside it is
        # scanned by the next run, and its messages name the very functions
        # --check-unused-functions is looking for, which keeps them alive.
        result = subprocess.run(
            [godot, "--headless", "--path", work, "--script", ANALYZER, "--",
             *config["flags"], "--json", "-o", report_path, config["target"]],
            capture_output=True, text=True, env=env)

        problems = []
        if config["exit"] is not None and result.returncode != config["exit"]:
            problems.append(f"exit code {result.returncode}, expected {config['exit']}")
        if not config["allow_script_errors"] and "SCRIPT ERROR" in result.stderr:
            first = next(line for line in result.stderr.splitlines()
                         if "SCRIPT ERROR" in line)
            problems.append(f"stderr has SCRIPT ERROR: {first.strip()}")
        if not os.path.isfile(report_path):
            raise Failure(f"{name}: no report written\n{result.stderr[-2000:]}")

        with open(report_path) as handle:
            actual = actual_findings(json.load(handle))

        if update:
            lines = [f"{where} {check}" for where, check, _ in actual]
            return "update", config, lines, problems

        if not actual and not problems:
            problems.append("no findings at all; a check that collects nothing "
                            "looks exactly like a clean project")

        wanted = {(w, c) for w, c, _ in expected}
        got = {(w, c) for w, c, _ in actual}
        for missing in sorted(wanted - got):
            problems.append(f"missing:   {missing[0]} {missing[1]}")
        for extra in sorted(got - wanted):
            problems.append(f"unexpected: {extra[0]} {extra[1]}")

        by_key = {(w, c): m for w, c, m in actual}
        for where, check, message in expected:
            if not message:
                continue
            found = by_key.get((where, check), "")
            if message not in found:
                problems.append(
                    f"message:   {where} {check}\n"
                    f"             wanted to contain: {message}\n"
                    f"             actual:            {found}")
        return ("fail" if problems else "pass"), config, None, problems
    finally:
        if os.environ.get("KEEP_WORK"):
            print(f"    work kept at {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


def run_unit(godot):
    result = subprocess.run(
        [godot, "--headless", "--path", REPO, "--script", "res://tests/unit/run.gd"],
        capture_output=True, text=True)
    body = "\n".join(line for line in result.stdout.splitlines()
                     if not line.startswith("Godot Engine") and line.strip())
    return result.returncode == 0, body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*", help="fixtures to run; default all")
    parser.add_argument("--update", action="store_true",
                        help="rewrite expectations after showing the diff")
    parser.add_argument("--no-unit", action="store_true")
    args = parser.parse_args()

    try:
        godot = find_godot()
        formatter = find_formatter()
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        return 3

    failed = []

    if not args.no_unit and not args.names:
        ok, body = run_unit(godot)
        print(f"unit  {'pass' if ok else 'FAIL'}")
        if not ok:
            print(body)
            failed.append("unit")

    names = args.names or sorted(
        entry for entry in os.listdir(FIXTURES)
        if os.path.isdir(os.path.join(FIXTURES, entry)))

    for name in names:
        try:
            status, config, lines, problems = run_fixture(name, godot, formatter, args.update)
        except Failure as error:
            print(f"{name}  FAIL\n    {error}")
            failed.append(name)
            continue

        if status == "update":
            path = os.path.join(FIXTURES, name, "expect")
            old_config, old = parse_expect(path)
            before = set((w, c) for w, c, _ in old)
            after = set(tuple(line.split(" ", 1)) for line in lines)
            print(f"{name}  update")
            for gone in sorted(before - after):
                print(f"    -{gone[0]} {gone[1]}")
            for new in sorted(after - before):
                print(f"    +{new[0]} {new[1]}")
            if before == after:
                print("    (no change)")
                continue
            print("    ^ review these before committing: regenerating an "
                  "expectation is how a broken check gets frozen into the suite")
            header = []
            with open(path) as handle:
                for raw in handle:
                    if raw.strip().startswith("#"):
                        header.append(raw.rstrip("\n"))
            with open(path, "w") as handle:
                handle.write("\n".join(header + lines) + "\n")
            continue

        print(f"{name}  {'pass' if status == 'pass' else 'FAIL'}")
        if status != "pass":
            failed.append(name)
            for problem in problems:
                print(f"    {problem}")

    if failed:
        print(f"\n{len(failed)} failed: {', '.join(failed)}")
        return 1
    print("\nall passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
