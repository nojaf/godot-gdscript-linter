/**
 * The linter's test suite.
 *
 *   bun test                       everything
 *   bun test -t members            one fixture
 *   bun test --watch               while working on a checker
 *   bun test -u                    accept the current findings as correct
 *   KEEP_WORK=1 bun test           leave the temporary project behind to inspect
 *
 * Two kinds of test. Unit assertions run inside Godot, over the pure functions
 * (tests/unit/run.gd). Fixtures are small Godot projects: each has a `config`
 * naming the flags to run, and its findings are held in a snapshot.
 *
 * What each fixture is FOR is documented in the fixture's own source, next to
 * the code that triggers it, rather than here or in a generated file.
 *
 * The invariants are asserted explicitly and never snapshotted, because a
 * snapshot of "nothing" is a perfectly good snapshot and this repository's
 * recurring failure is a checker that throws, collects nothing, exits 0 and
 * looks exactly like a clean project. So: the exit code is what the fixture
 * says, stderr carries no SCRIPT ERROR unless the fixture allows it, and the
 * run produced at least one finding. Only the content of the findings is
 * snapshotted.
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

function findGodot(): string {
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
      `scripts/install-formatter.sh failed, and the suite needs it:\n${result.stderr.toString()}`,
    );
  }
  return result.text().trim();
}

const GODOT = findGodot();
process.env.GDLINT_FORMATTER = await findFormatter();

// Said out loud because both are variables the results depend on, and neither
// is obvious: the Godot picked up from PATH may not be the one you develop
// against, and the formatter is rebuilt from a sibling checkout on every run.
const version = (await $`${GODOT} --version`.quiet().nothrow()).text().trim();
console.log(`godot     ${GODOT} (${version})`);
console.log(`formatter ${process.env.GDLINT_FORMATTER}`);

type Config = {
  flags: string[];
  target: string;
  exit: number | null;
  allowScriptErrors: boolean;
};

type Finding = {
  file: string;
  line: number;
  severity: string;
  check: string;
  message: string;
};

/** `config` is directives only. Expectations live in the snapshot. */
function readConfig(path: string): Config {
  const config: Config = {
    flags: [],
    target: "res://src",
    exit: null,
    allowScriptErrors: false,
  };
  for (const raw of readFileSync(path, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line.startsWith("#")) continue;
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
  }
  return config;
}

/**
 * Sorted by file, then line NUMERICALLY, then check id. Comparing a location as
 * a string puts :17 before :5, which turns a passing suite into a diff about
 * ordering.
 */
function findingsOf(report: any): Finding[] {
  return report.issues
    .map((issue: any) => ({
      file: issue.file_path.replace("res://", ""),
      line: issue.line,
      severity: issue.severity,
      check: issue.check_id,
      message: issue.message,
    }))
    .sort(
      (a: Finding, b: Finding) =>
        a.file.localeCompare(b.file) || a.line - b.line || a.check.localeCompare(b.check),
    );
}

const asLine = (f: Finding) => `${f.file}:${f.line}  ${f.severity}  ${f.check}  ${f.message}`;

/**
 * The snapshot as last accepted, read from the file rather than from the failed
 * assertion. Bun's snapshot mismatch carries only a rendered message, with no
 * structured before-and-after to pull out, so the comparison below reads the
 * stored value directly.
 */
function storedSnapshot(name: string): string {
  const path = join(import.meta.dir, "__snapshots__", "lint.test.ts.snap");
  if (!existsSync(path)) return "";
  const text = readFileSync(path, "utf8");
  const marker = "exports[`fixtures " + name + " 1`] = `";
  const start = text.indexOf(marker);
  if (start < 0) return "";
  const from = start + marker.length;
  const end = text.indexOf("\n`;", from);
  if (end < 0) return "";
  return text
    .slice(from, end)
    .replace(/^\n/, "")
    .replace(/^"|"$/g, "")
    .replace(/\\`/g, "`")
    .replace(/\\\$/g, "$");
}

/**
 * What actually changed, in the linter's terms rather than as a text diff.
 *
 * A snapshot mismatch prints a diff of two blobs, which answers "these strings
 * differ" and not "this finding moved" or "this message lost its suggestion".
 * This runs on failure, before the assertion is rethrown, and says which
 * findings appeared, disappeared or changed wording, quoting the fixture line
 * each one points at.
 */
function explain(name: string, config: Config, actual: Finding[], work: string) {
  const previous = storedSnapshot(name)
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  const current = actual.map(asLine);
  const key = (line: string) => line.split("  ")[0]!;

  const before = new Map(previous.map((line) => [key(line), line]));
  const after = new Map(current.map((line) => [key(line), line]));

  const gone = [...before.keys()].filter((k) => !after.has(k));
  const added = [...after.keys()].filter((k) => !before.has(k));
  const changed = [...after.keys()].filter((k) => before.has(k) && before.get(k) !== after.get(k));

  const source = (location: string) => {
    const at = location.lastIndexOf(":");
    const file = join(work, location.slice(0, at));
    const line = Number(location.slice(at + 1));
    if (!existsSync(file)) return "";
    const text = readFileSync(file, "utf8").split("\n")[line - 1];
    return text === undefined ? "" : `\n         ${location.slice(0, at)}:${line} is: ${text.trim()}`;
  };

  const out: string[] = [
    "",
    `  ${name}: the findings changed.`,
    `  ran: ${config.flags.join(" ")} ${config.target}`,
  ];
  if (gone.length) {
    out.push("", "  NO LONGER REPORTED — a check stopped seeing something it used to:");
    for (const k of gone) out.push(`    - ${before.get(k)}${source(k)}`);
  }
  if (added.length) {
    out.push("", "  NEWLY REPORTED — a check started seeing something it did not:");
    for (const k of added) out.push(`    + ${after.get(k)}${source(k)}`);
  }
  if (changed.length) {
    out.push("", "  SAME PLACE, DIFFERENT MESSAGE:");
    for (const k of changed) {
      out.push(`    - ${before.get(k)}`, `    + ${after.get(k)}`);
    }
  }
  out.push(
    "",
    `  If the new output is correct, accept it with:  bun test -t ${name} -u`,
    `  To inspect the project it ran against:        KEEP_WORK=1 bun test -t ${name}`,
    "",
  );
  console.log(out.join("\n"));
}

async function runFixture(name: string) {
  const fixture = join(FIXTURES, name);
  const config = readConfig(join(fixture, "config"));
  const work = mkdtempSync(join(tmpdir(), `gdlint-test-${name}-`));

  for (const entry of readdirSync(fixture)) {
    if (entry === "config" || entry === "generate.gd") continue;
    cpSync(join(fixture, entry), join(work, entry), { recursive: true });
  }
  mkdirSync(join(work, "addons"), { recursive: true });
  cpSync(ADDON, join(work, "addons", "gdscript-linter"), { recursive: true });

  await $`${GODOT} --headless --path ${work} --import`.quiet().nothrow();

  // A generator runs after the import so it can load scripts, and writes scenes
  // and binary resources with Godot's own serialisation rather than any
  // hand-authored idea of those formats.
  const generator = join(fixture, "generate.gd");
  if (existsSync(generator)) {
    cpSync(generator, join(work, "generate.gd"));
    const made =
      await $`${GODOT} --headless --path ${work} --script res://generate.gd`.quiet().nothrow();
    if (made.exitCode !== 0) throw new Error(`generate.gd failed:\n${made.stderr.toString()}`);
    await $`${GODOT} --headless --path ${work} --import`.quiet().nothrow();
  }

  // Written outside the project on purpose: a report left inside it is scanned
  // by the next run, and its messages name the very functions
  // --check-unused-functions is looking for, which keeps them alive.
  const reportPath = join(work, "..", `gdlint-report-${name}.json`);
  const run =
    await $`${GODOT} --headless --path ${work} --script ${ANALYZER} -- ${config.flags} --json -o ${reportPath} ${config.target}`
      .quiet()
      .nothrow();

  if (!existsSync(reportPath)) {
    throw new Error(
      `${name}: the analyzer wrote no report at all, so nothing could be compared.\n` +
        `  exit code ${run.exitCode}\n  stderr tail:\n${run.stderr.toString().slice(-2000)}`,
    );
  }
  const actual = findingsOf(await Bun.file(reportPath).json());
  rmSync(reportPath, { force: true });
  return { config, actual, run, work };
}

const MINUTE = 60_000;

describe("unit", () => {
  test(
    "pure functions",
    async () => {
      // The class_name globals the assertions use only resolve once Godot has
      // imported the project, and a fresh clone has not. Without this the script
      // fails to load, Godot exits 0 anyway, and the test passes having run
      // nothing at all.
      if (!existsSync(join(REPO, ".godot"))) {
        await $`${GODOT} --headless --path ${REPO} --import`.quiet().nothrow();
      }

      const result =
        await $`${GODOT} --headless --path ${REPO} --script res://tests/unit/run.gd`.quiet().nothrow();
      const stderr = result.stderr.toString();

      // Exit code is not evidence. Godot exits 0 when a script fails to load, so
      // the run has to say how much of it happened.
      const ran = result.text().match(/^unit: (\d+) assertions, (\d+) failed$/m);
      if (!ran) {
        throw new Error(
          `tests/unit/run.gd never reported a total, so nothing was verified.\n` +
            `  exit code ${result.exitCode}, which Godot returns even when the script\n` +
            `  fails to load. Usually a parse error or a missing class_name.\n` +
            `  stdout:\n${result.text() || "    (empty)"}\n  stderr:\n${stderr || "    (empty)"}`,
        );
      }

      const [, total, failed] = ran;
      if (Number(failed) > 0) {
        throw new Error(
          `${failed} of ${total} unit assertions failed:\n${stderr}\n` +
            `  each block above is one assertion, with what it expected and what it got`,
        );
      }
      expect(Number(total)).toBeGreaterThan(0);
      expect(stderr).not.toContain("SCRIPT ERROR");
    },
    2 * MINUTE,
  );
});

const names = readdirSync(FIXTURES)
  .filter((entry) => existsSync(join(FIXTURES, entry, "config")))
  .sort();

describe("fixtures", () => {
  for (const name of names) {
    test(
      name,
      async () => {
        const { config, actual, run, work } = await runFixture(name);
        try {
          if (config.exit !== null && run.exitCode !== config.exit) {
            throw new Error(
              `${name}: exit code ${run.exitCode}, expected ${config.exit}.\n` +
                `  0 clean, 1 warnings, 2 critical, 3 could not run.\n` +
                `  ${actual.length} finding(s) were reported.\n` +
                `  stderr tail:\n${run.stderr.toString().slice(-1500)}`,
            );
          }

          if (!config.allowScriptErrors) {
            const errors = run.stderr
              .toString()
              .split("\n")
              .filter((line) => line.includes("SCRIPT ERROR"));
            if (errors.length) {
              throw new Error(
                `${name}: the analyzer threw while running.\n` +
                  `  A GDScript error does not stop the run: the checker collects nothing,\n` +
                  `  the report still parses, and the findings look merely absent.\n` +
                  errors.map((line) => `    ${line.trim()}`).join("\n"),
              );
            }
          }

          if (actual.length === 0) {
            throw new Error(
              `${name}: no findings at all.\n` +
                `  Every fixture is written to produce some. None means the check under\n` +
                `  test collected nothing, which is indistinguishable from a clean run.\n` +
                `  ran: ${config.flags.join(" ")} ${config.target}`,
            );
          }

          const stored = actual.map(asLine).join("\n");
          try {
            expect(stored).toMatchSnapshot();
          } catch (mismatch) {
            explain(name, config, actual, work);
            throw mismatch;
          }
        } finally {
          if (process.env.KEEP_WORK) console.log(`    ${name}: work kept at ${work}`);
          else rmSync(work, { recursive: true, force: true });
        }
      },
      2 * MINUTE,
    );
  }
});
