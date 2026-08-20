/**
 * The linter's test suite.
 *
 *   bun test                     everything
 *   bun test -t members          one fixture
 *   bun test --watch             while working on a checker
 *   UPDATE=1 bun test -t members rewrite that fixture's expectations
 *   KEEP_WORK=1 bun test         leave the temporary project behind to inspect
 *
 * Two kinds of test. Unit assertions run inside Godot, over the pure functions
 * (tests/unit/run.gd). Fixtures are small Godot projects, linted and compared
 * against an `expect` file.
 *
 * Every fixture expects a non-zero number of findings on purpose. A case whose
 * expectation is "nothing" passes just as well when the check under test is
 * broken, which is the failure this repository keeps hitting: a checker that
 * throws collects nothing, exits 0, and looks exactly like a clean project. For
 * the same reason stderr is asserted free of SCRIPT ERROR unless the fixture
 * says otherwise, since that is where the throw goes.
 *
 * Fixtures run in a fresh copy under a temporary directory. Nothing is imported
 * in place, so a stale script class cache cannot make a run look clean.
 */
import { $ } from "bun";
import { describe, expect, test } from "bun:test";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const REPO = join(import.meta.dir, "..");
const FIXTURES = join(REPO, "tests", "fixtures");
const ADDON = join(REPO, "addons", "gdscript-linter");
const ANALYZER = "res://addons/gdscript-linter/analyzer/analyze-cli.gd";

const GODOT_CANDIDATES = [
  "godot",
  "godot4",
  "godot-mono",
  "godot4-mono",
  "/Applications/Godot.app/Contents/MacOS/Godot",
  `${process.env.HOME}/Applications/Godot.app/Contents/MacOS/Godot`,
  "/Applications/Godot_mono.app/Contents/MacOS/Godot",
];

async function findGodot(): Promise<string> {
  if (process.env.GODOT) return process.env.GODOT;
  for (const candidate of GODOT_CANDIDATES) {
    if (candidate.includes("/")) {
      if (existsSync(candidate)) return candidate;
    } else {
      const found = Bun.which(candidate);
      if (found) return found;
    }
  }
  throw new Error("no Godot binary found; put godot on PATH or set GODOT");
}

/**
 * The formatter is a hard requirement, not something to skip around. Three of
 * the checks cannot run without it, and a suite that quietly skips them reports
 * success while testing nothing.
 */
async function findFormatter(): Promise<string> {
  const installer = join(REPO, "scripts", "install-formatter.sh");
  const result = await $`${installer}`.quiet().nothrow();
  if (result.exitCode !== 0) {
    throw new Error(
      `scripts/install-formatter.sh failed:\n${result.stderr.toString()}`,
    );
  }
  return result.text().trim();
}

const GODOT = await findGodot();
process.env.GDLINT_FORMATTER = await findFormatter();

type Expectation = { where: string; check: string; message: string };
type Config = {
  flags: string[];
  target: string;
  exit: number | null;
  allowScriptErrors: boolean;
};

/**
 * `expect` is directives, then one `<file>:<line> <check-id>` per line.
 *
 *     # flags: --check-members
 *     # exit: 2
 *     src/probe.gd:7 unknown-member
 *     src/probe.gd:4 unknown-member ~ FoldSettings has all of them
 *
 * A `~` suffix asserts the message contains that text, for the cases where the
 * wording is the feature rather than incidental.
 */
function parseExpect(path: string): { config: Config; expected: Expectation[] } {
  const config: Config = {
    flags: [],
    target: "res://src",
    exit: null,
    allowScriptErrors: false,
  };
  const expected: Expectation[] = [];

  for (const raw of readFileSync(path, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("#")) {
      const directive = line.replace(/^#+\s*/, "");
      const at = directive.indexOf(":");
      if (at < 0) continue;
      const key = directive.slice(0, at).trim();
      const value = directive.slice(at + 1).trim();
      if (key === "flags") config.flags = value.split(/\s+/);
      else if (key === "target") config.target = value;
      else if (key === "exit") config.exit = Number(value);
      else if (key === "allow-script-errors")
        config.allowScriptErrors = ["yes", "true", "1"].includes(value.toLowerCase());
      continue;
    }
    const [where, ...rest] = line.split(" ");
    const [check, message = ""] = rest.join(" ").split("~");
    expected.push({ where: where!, check: check!.trim(), message: message.trim() });
  }
  expected.sort(byLocation);
  return { config, expected };
}

type Finding = { where: string; check: string; message: string };

/**
 * Findings as `file:line` and check-id, stripped of res:// and sorted.
 *
 * Fixture sources barely change, so a line number is real information here: if
 * a finding moves, something moved it. That is the opposite of a self lint,
 * where line numbers shift constantly and only counts are stable.
 */
function findingsOf(report: any): Finding[] {
  return report.issues
    .map((issue: any) => ({
      where: `${issue.file_path.replace("res://", "")}:${issue.line}`,
      check: issue.check_id,
      message: issue.message,
    }))
    .sort(byLocation);
}

/**
 * Sorts by file, then line NUMERICALLY, then check id. Comparing the location
 * as a string puts :17 before :5, which turns a passing suite into a diff about
 * ordering.
 */
function byLocation(a: { where: string; check: string }, b: { where: string; check: string }) {
  const [aFile, aLine] = splitLocation(a.where);
  const [bFile, bLine] = splitLocation(b.where);
  return aFile.localeCompare(bFile) || aLine - bLine || a.check.localeCompare(b.check);
}

function splitLocation(where: string): [string, number] {
  const at = where.lastIndexOf(":");
  return [where.slice(0, at), Number(where.slice(at + 1))];
}

async function runFixture(name: string) {
  const fixture = join(FIXTURES, name);
  const { config, expected } = parseExpect(join(fixture, "expect"));
  const work = mkdtempSync(join(tmpdir(), `gdlint-test-${name}-`));

  try {
    for (const entry of readdirSync(fixture)) {
      if (entry === "expect" || entry === "generate.gd") continue;
      cpSync(join(fixture, entry), join(work, entry), { recursive: true });
    }
    mkdirSync(join(work, "addons"), { recursive: true });
    cpSync(ADDON, join(work, "addons", "gdscript-linter"), { recursive: true });

    await $`${GODOT} --headless --path ${work} --import`.quiet().nothrow();

    // A generator runs after the import so it can load scripts, and writes
    // scenes and binary resources with Godot's own serialisation rather than
    // any hand-authored idea of those formats.
    const generator = join(fixture, "generate.gd");
    if (existsSync(generator)) {
      cpSync(generator, join(work, "generate.gd"));
      const made =
        await $`${GODOT} --headless --path ${work} --script res://generate.gd`.quiet().nothrow();
      if (made.exitCode !== 0) {
        throw new Error(`generate.gd failed:\n${made.stderr.toString()}`);
      }
      await $`${GODOT} --headless --path ${work} --import`.quiet().nothrow();
    }

    // Written outside the project on purpose: a report left inside it is
    // scanned by the next run, and its messages name the very functions
    // --check-unused-functions is looking for, which keeps them alive.
    const reportPath = join(work, "..", `gdlint-report-${name}.json`);
    const run =
      await $`${GODOT} --headless --path ${work} --script ${ANALYZER} -- ${config.flags} --json -o ${reportPath} ${config.target}`
        .quiet()
        .nothrow();

    if (!existsSync(reportPath)) {
      throw new Error(`no report written:\n${run.stderr.toString().slice(-2000)}`);
    }
    const actual = findingsOf(await Bun.file(reportPath).json());
    rmSync(reportPath, { force: true });
    return { config, expected, actual, run, fixture };
  } finally {
    if (process.env.KEEP_WORK) console.log(`    work kept at ${work}`);
    else rmSync(work, { recursive: true, force: true });
  }
}

/**
 * Rewriting an expectation is how a broken check gets frozen into a suite, so
 * the change is printed rather than applied silently. Kept deliberately clumsy:
 * one fixture at a time, and the diff goes to the terminal either way.
 */
function rewriteExpect(fixture: string, expected: Expectation[], actual: Finding[]) {
  const before = new Set(expected.map((e) => `${e.where} ${e.check}`));
  const after = actual.map((f) => `${f.where} ${f.check}`);
  const afterSet = new Set(after);
  const gone = [...before].filter((line) => !afterSet.has(line));
  const added = after.filter((line) => !before.has(line));
  console.log(`\n  updating ${fixture}`);
  for (const line of gone) console.log(`    -${line}`);
  for (const line of added) console.log(`    +${line}`);
  if (!gone.length && !added.length) {
    console.log("    (no change)");
    return;
  }
  console.log(
    "    ^ review these before committing: regenerating an expectation is how a\n" +
      "      broken check gets frozen into the suite",
  );
  const path = join(FIXTURES, fixture, "expect");
  const header = readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.trim().startsWith("#"));
  writeFileSync(path, [...header, ...after].join("\n") + "\n");
}

const MINUTE = 60_000;

describe("unit", () => {
  test(
    "pure functions",
    async () => {
      const result =
        await $`${GODOT} --headless --path ${REPO} --script res://tests/unit/run.gd`.quiet().nothrow();
      if (result.exitCode !== 0) throw new Error(result.stderr.toString());
      expect(result.exitCode).toBe(0);
    },
    MINUTE,
  );
});

const names = readdirSync(FIXTURES).filter((entry) =>
  existsSync(join(FIXTURES, entry, "expect")),
);

describe("fixtures", () => {
  for (const name of names.sort()) {
    test(
      name,
      async () => {
        const { config, expected, actual, run } = await runFixture(name);

        if (process.env.UPDATE) {
          rewriteExpect(name, expected, actual);
          return;
        }

        if (config.exit !== null) expect(run.exitCode).toBe(config.exit);

        if (!config.allowScriptErrors) {
          const errors = run.stderr
            .toString()
            .split("\n")
            .filter((line) => line.includes("SCRIPT ERROR"));
          expect(errors).toEqual([]);
        }

        // A check that collects nothing produces nothing to differ, so the
        // absence of findings is asserted separately from their content.
        expect(actual.length).toBeGreaterThan(0);

        expect(actual.map((f) => `${f.where} ${f.check}`)).toEqual(
          expected.map((e) => `${e.where} ${e.check}`),
        );

        for (const { where, check, message } of expected) {
          if (!message) continue;
          const found = actual.find((f) => f.where === where && f.check === check);
          expect(`${where} ${check}: ${found?.message ?? "<missing>"}`).toContain(message);
        }
      },
      2 * MINUTE,
    );
  }
});
