#!/usr/bin/env python3
"""Structural + parity validator for the GDScript linter's SARIF output.

Gates the SARIF implementation loop. Checks DoD items 3-9 from ANALYSIS.md
using only the Python standard library. Exits 0 when the file satisfies every
check, non-zero (printing each failure) otherwise.

Usage:
    python3 scripts/validate_sarif.py <file.sarif> [--json <file.json>]

The optional --json file is a `--json`-format run over the SAME paths/config;
when supplied, result-count parity and per-severity mapping are checked too.

This is a structural gate, NOT a full JSON-schema validation. For the final
green, also run: npx --yes @microsoft/sarif-multitool validate <file.sarif>
"""

import argparse
import json
import sys

VALID_LEVELS = {"error", "warning", "note"}
# GDLintIssue severity string -> required SARIF level (DoD item 9)
SEVERITY_TO_LEVEL = {"critical": "error", "warning": "warning", "info": "note"}


class Report:
    def __init__(self):
        self.errors = []

    def check(self, condition, message):
        if not condition:
            self.errors.append(message)
        return condition

    def fail(self, message):
        self.errors.append(message)


def load_json(path, report, label):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        report.fail("%s: file not found: %s" % (label, path))
    except json.JSONDecodeError as exc:
        # DoD item 3: output must be a single parseable JSON document.
        report.fail("%s: not valid JSON (%s)" % (label, exc))
    return None


def validate_top_level(sarif, report):
    """DoD items 4-5."""
    if not report.check(isinstance(sarif, dict), "top level is not a JSON object"):
        return None
    report.check("$schema" in sarif, "missing top-level '$schema'")
    report.check(sarif.get("version") == "2.1.0", "version must be exactly '2.1.0'")

    runs = sarif.get("runs")
    if not report.check(isinstance(runs, list) and len(runs) == 1,
                        "'runs' must be an array of length 1"):
        return None
    run = runs[0]

    driver = (run.get("tool") or {}).get("driver") or {}
    for field in ("name", "version", "informationUri"):
        report.check(bool(driver.get(field)),
                     "runs[0].tool.driver.%s is missing/empty" % field)
    report.check(isinstance(driver.get("rules"), list),
                 "runs[0].tool.driver.rules must be an array")
    return run


def validate_result(idx, res, report):
    """DoD items 7-8 for a single result. Returns level for later checks."""
    where = "results[%d]" % idx
    if not isinstance(res, dict):
        report.fail("%s is not an object" % where)
        return None

    report.check(bool(res.get("ruleId")), "%s.ruleId missing/empty" % where)

    level = res.get("level")
    report.check(level in VALID_LEVELS,
                 "%s.level must be one of %s (got %r)"
                 % (where, sorted(VALID_LEVELS), level))

    msg = res.get("message")
    report.check(isinstance(msg, dict) and bool(msg.get("text")),
                 "%s.message.text missing/empty" % where)

    locs = res.get("locations")
    if not report.check(isinstance(locs, list) and len(locs) >= 1,
                        "%s.locations must be a non-empty array" % where):
        return level

    phys = (locs[0] or {}).get("physicalLocation") or {}
    uri = (phys.get("artifactLocation") or {}).get("uri")
    if report.check(isinstance(uri, str) and uri != "",
                    "%s physicalLocation.artifactLocation.uri missing" % where):
        report.check(not uri.startswith("res://"),
                     "%s uri still has res:// prefix: %r" % (where, uri))
        report.check("\\" not in uri,
                     "%s uri contains a backslash: %r" % (where, uri))
        report.check(not uri.startswith("/"),
                     "%s uri is not repo-relative: %r" % (where, uri))

    region = phys.get("region") or {}
    start_line = region.get("startLine")
    report.check(isinstance(start_line, int) and start_line >= 1,
                 "%s region.startLine must be an int >= 1 (got %r)"
                 % (where, start_line))
    if "startColumn" in region:
        sc = region.get("startColumn")
        report.check(isinstance(sc, int) and sc >= 1,
                     "%s region.startColumn present but < 1 (got %r)" % (where, sc))
    return level


def validate_parity(run, json_doc, report):
    """DoD items 6 and 9, cross-checking against the --json run."""
    issues = json_doc.get("issues")
    if not isinstance(issues, list):
        report.fail("--json file has no 'issues' array; cannot check parity")
        return
    results = run.get("results") or []

    report.check(len(results) == len(issues),
                 "result parity: SARIF has %d results but --json has %d issues"
                 % (len(results), len(issues)))

    # Multiset of (ruleId, level) must match (check_id, mapped severity).
    def bag(pairs):
        out = {}
        for p in pairs:
            out[p] = out.get(p, 0) + 1
        return out

    sarif_bag = bag((r.get("ruleId"), r.get("level"))
                    for r in results if isinstance(r, dict))
    json_bag = bag((i.get("check_id"),
                    SEVERITY_TO_LEVEL.get(i.get("severity"), "?"))
                   for i in issues)
    if sarif_bag != json_bag:
        report.fail("ruleId/level distribution does not match --json "
                    "check_id/severity mapping (severity->level or a "
                    "dropped/duplicated finding)")


def main(argv):
    parser = argparse.ArgumentParser(description="Validate linter SARIF output.")
    parser.add_argument("sarif", help="path to the .sarif file")
    parser.add_argument("--json", dest="json_path",
                        help="matching --json output over the same run (parity check)")
    args = parser.parse_args(argv)

    report = Report()
    sarif = load_json(args.sarif, report, "sarif")
    if sarif is not None:
        run = validate_top_level(sarif, report)
        if run is not None:
            results = run.get("results")
            if report.check(isinstance(results, list),
                            "runs[0].results must be an array"):
                for idx, res in enumerate(results):
                    validate_result(idx, res, report)
            if args.json_path:
                json_doc = load_json(args.json_path, report, "json")
                if json_doc is not None and run is not None:
                    validate_parity(run, json_doc, report)

    if report.errors:
        print("SARIF validation FAILED (%d issue(s)):" % len(report.errors))
        for e in report.errors:
            print("  - %s" % e)
        return 1
    print("SARIF validation PASSED: %s" % args.sarif)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
