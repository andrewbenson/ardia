import { spawnSync } from "node:child_process";
import { cpSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { deflateRawSync, inflateRawSync } from "node:zlib";
import { registerHooks } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HELP = `usage: node src/sync/recordPinsApply.mjs [--representative] <fresh-output-directory> [test files...]

Run from apps/browser. The output directory must not exist; its parent must exist.
A failed run removes its temporary data and publishes no corpus. Every pair apply is labelled
with its initial row/tile kind, A/B operation names, pair id and exact delivery schedule.

Regenerate the four checked-in representative fixtures into a fresh scratch directory:
  node src/sync/recordPinsApply.mjs --representative /tmp/pins-representative-new
This runs all deterministic regressions and six selected pair schedules, then copies the two
stable normalized Legacy fixtures. Replace Cases/SyncPinsApply only after inspecting the result.

Regenerate the exhaustive corpus and replay every apply under both native configurations:
  node src/sync/recordPinsApply.mjs /tmp/pins-full-new
  cd ../../native/SolaraKit
  PIN_APPLY_DIR=/tmp/pins-full-new swift test --filter SyncPinsApplyReplayTests

The recorder freezes the clock and random seed. SYNC_REDESIGN=off/on selects the recording mode;
Swift replays the same fixtures with origin tagging off and on regardless of the recorded mode.`;

const selections = [
  { startRow: true, opA: "unpinX", opB: "repinX", schedule: "A then B" },
  { startRow: false, opA: "repinX", opB: "xTile", schedule: "both, A syncs first" },
  { startRow: true, opA: "moveXIntoG", opB: "unpinG", schedule: "B's log delayed" },
  { startRow: false, opA: "styleG", opB: "navM", schedule: "both, with an older Mac" },
  { startRow: true, opA: "createHMoveX", opB: "renameX", schedule: "A's first log 44 days late, C joins from a snapshot meanwhile" },
  { startRow: false, opA: "workRoundTrip", opB: "workTile", schedule: "A's first log delayed" },
];

function replaceOnce(source, anchor, replacement) {
  if (source.split(anchor).length !== 2) throw new Error(`recorder anchor changed: ${anchor}`);
  return source.replace(anchor, replacement);
}

const app = fileURLToPath(new URL("../../", import.meta.url));
const recorder = fileURLToPath(new URL("../../scripts/native/replay.mjs", import.meta.url));
const here = fileURLToPath(import.meta.url);

if (process.env.PIN_APPLY_RECORD_CHILD === "1") {
  registerHooks({
    load(url, context, next) {
      const loaded = next(url, context);
      if (loaded.source == null) return loaded;
      if (url.endsWith("/src/sync/pairs.test.mjs")) {
        let source = typeof loaded.source === "string" ? loaded.source : new TextDecoder().decode(loaded.source);
        source = replaceOnce(source, "async function runPair(startRow, opA, opB, schedule) {", 'async function runPair(startRow, opA, opB, schedule) {\n  globalThis.__pinApplyPair = { startRow, opA: opA.name, opB: opB.name, schedule };\n  try {');
        source = replaceOnce(source, "\n}\n\nconst cases = [];", "\n  } finally { globalThis.__pinApplyPair = null; }\n}\n\nconst cases = [];");
        if (process.env.PIN_APPLY_REPRESENTATIVE === "1") {
          source = replaceOnce(source, "for (const c of cases) {", `for (const c of cases.filter((c) => ${JSON.stringify(selections)}.some((s) => s.startRow === c.startRow && s.opA === c.opA.name && s.opB === c.opB.name && s.schedule === c.schedule))) {`);
        }
        return { ...loaded, source };
      }
      if (url.endsWith("/src/sync/redesignSwitch.ts") && ["1", "on"].includes(process.env.SYNC_REDESIGN)) {
        const source = typeof loaded.source === "string" ? loaded.source : new TextDecoder().decode(loaded.source);
        return { ...loaded, source: replaceOnce(source, "{ on: false }", "{ on: true }") };
      }
      if (url !== new URL(`file://${recorder}`).href) return loaded;
      let source = typeof loaded.source === "string" ? loaded.source : new TextDecoder().decode(loaded.source);
      source = replaceOnce(source, '["--no-warnings", "--max-old-space-size=8192", fileURLToPath(import.meta.url)', `["--no-warnings", "--max-old-space-size=4096", "--import", ${JSON.stringify(here)}, fileURLToPath(import.meta.url)`);
      if (process.env.PIN_APPLY_LEGACY_FIXTURES === "1") {
        source = replaceOnce(source, '(url.endsWith("/src/sync/adapters.ts") || url.endsWith("/src/sync/pinned.ts"))', '(url.endsWith("/src/sync/adapters.ts") || url.endsWith("/src/sync/pinned.ts") || /\\/src\\/sync\\/fixtures\\/pinned-v0\\.2\\.(38|40)\\.ts$/.test(url))');
        source = replaceOnce(source, 'source: instrumentAdapters(text) + exposed', `source: instrumentAdapters(text).replace(/globalThis\\.__replayAdapter\\("(\\w+Adapter)"/g, (call, name) => url.includes("/fixtures/") ? 'globalThis.__replayAdapter("legacy' + (/v0\\.2\\.(38|40)/.exec(url)?.[1] ?? "") + ':' + name + '"' : call) + exposed`);
        source = replaceOnce(source, 'const HOSTED_ADAPTERS =', 'for (const [name, kinds] of [...RECORDED_ADAPTERS]) { RECORDED_ADAPTERS.set("legacy38:" + name, kinds); RECORDED_ADAPTERS.set("legacy40:" + name, kinds); }\nconst HOSTED_ADAPTERS =');
      }
      source = replaceOnce(source, "let cases = [];", `let cases = []; let chunk = 0; let recorded = 0;
  const flushPinCases = () => {
    if (!cases.length) return;
    mkdirSync(out, { recursive: true });
    const label = relative(join(app, "src"), file).replace(/\\.test\\.mjs$/, "").replaceAll("/", "__");
    const target = join(out, "adapters__" + label + "__" + String(++chunk).padStart(4, "0") + ".json.deflate");
    writeFileSync(target, deflateRawSync(Buffer.from(JSON.stringify({ phase, file: relative(app, file), cases: encodeDeltas(cases) })), { level: 6 }));
    recorded += cases.length;
    cases = [];
  };`);
      source = replaceOnce(source, 'if (!ok || !c.test) return;', 'if (!ok || !c.test || c.call !== "apply") return;');
      source = replaceOnce(source, "cases.push(c);", "cases.push(c); if (cases.length >= 250) flushPinCases();");
      source = replaceOnce(source, "for (const t of tests) {", 'for (const t of tests) { if (process.env.PIN_APPLY_TEST_FILTER && !new RegExp(process.env.PIN_APPLY_TEST_FILTER).test(t.name)) continue;');
      source = replaceOnce(source, "if (spec.deltas) cases = encodeDeltas(cases);", "flushPinCases(); cases = [];");
      source = replaceOnce(source, 'console.log(`recorded ${cases.length} cases${failures ?', 'console.log(`recorded ${recorded} cases${failures ?');
      source = replaceOnce(source, "process.exit(0);\n}\n\nfunction projectState", "process.exit(failures ? 1 : 0);\n}\n\nfunction projectState");
      if (!source.includes("test: current,")) throw new Error("recorder test-label anchor changed");
      source = source.replaceAll("test: current,", 'test: globalThis.__pinApplyPair ? current + " | " + JSON.stringify(globalThis.__pinApplyPair) : current,');
      return { ...loaded, source };
    },
  });
} else {
  const args = process.argv.slice(2);
  if (args.includes("--help")) {
    console.log(HELP);
    process.exit(0);
  }
  const representative = args.includes("--representative");
  if (representative) args.splice(args.indexOf("--representative"), 1);
  if (!args[0] || args.some((arg) => arg.startsWith("--"))) {
    console.error(HELP);
    process.exit(1);
  }
  const out = resolve(args[0]);
  let temporary;
  try {
    if (outputExists(out)) throw new Error(`output already exists: ${out}`);
    temporary = mkdtempSync(join(dirname(out), ".pin-apply-"));
    const files = args.slice(1);
    const run = spawnSync(process.execPath, ["--no-warnings", "--max-old-space-size=4096", "--import", here, recorder, "--phase", "adapters", "--cap", "0", "--out", temporary, ...(files.length ? files : ["src/sync/pairs.test.mjs", "src/sync/pinned.test.mjs"])], {
      cwd: app,
      env: { ...process.env, PIN_APPLY_RECORD_CHILD: "1", PIN_APPLY_REPRESENTATIVE: representative ? "1" : "0" },
      stdio: "inherit",
    });
    if (run.error) throw run.error;
    if (run.status !== 0) throw new Error(`recording failed: ${run.signal ?? run.status}`);
    const deterministic = [];
    const schedules = [];
    let total = 0;
    for (const name of readdirSync(temporary).filter((name) => name.endsWith(".json.deflate")).sort()) {
      const path = join(temporary, name);
      const document = JSON.parse(inflateRawSync(readFileSync(path)));
      let last = null;
      for (const c of document.cases) {
        if (representative) {
          if (c.beforeDelta) c.before = applyDelta(c.beforeDelta, last);
          if (c.afterDelta) c.after = applyDelta(c.afterDelta, c.before);
          last = c.after;
          delete c.beforeDelta;
          delete c.afterDelta;
        }
        const separator = c.test.indexOf(" | ");
        if (separator >= 0) {
          const pair = JSON.parse(c.test.slice(separator + 3));
          c.pairId = `${pair.startRow ? "row" : "tile"}:${pair.opA}/${pair.opB}`;
          c.schedule = pair.schedule;
          if (representative) schedules.push(c);
        } else if (representative) deterministic.push(c);
        total++;
      }
      if (representative) rmSync(path);
      else writeFileSync(path, deflateRawSync(Buffer.from(JSON.stringify(document)), { level: 6 }));
    }
    if (!total) throw new Error("recording produced no applies");
    if (representative) {
      if (new Set(deterministic.map((c) => c.test)).size !== 22) throw new Error("expected all 22 deterministic regressions");
      const labelled = new Set(schedules.map((c) => `${c.pairId}|${c.schedule}`));
      for (const s of selections) if (!labelled.has(`${s.startRow ? "row" : "tile"}:${s.opA}/${s.opB}|${s.schedule}`)) throw new Error(`missing selected schedule: ${s.schedule}`);
      for (const [name, cases] of [["deterministic-current", deterministic], ["selected-schedules", schedules]]) {
        writeFileSync(join(temporary, `${name}.json.deflate`), deflateRawSync(Buffer.from(JSON.stringify({ phase: "adapters", cases })), { level: 6 }));
      }
    }
    cpSync(fileURLToPath(new URL("../../../../native/SolaraKit/Tests/SolaraSyncTests/Cases/SyncPinsApply/Legacy", import.meta.url)), join(temporary, "Legacy"), { recursive: true });
    if (outputExists(out)) throw new Error(`output appeared during recording: ${out}`);
    renameSync(temporary, out);
    temporary = null;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    if (temporary) rmSync(temporary, { recursive: true, force: true });
  }
}

function applyDelta(delta, from) {
  const out = { ...from };
  for (const [key, value] of Object.entries(delta)) {
    if (value?.$absent) delete out[key];
    else if (value?.$table) {
      const table = { ...out[key], ...value.$table.set };
      for (const id of value.$table.remove) delete table[id];
      out[key] = value.$table.order ? Object.fromEntries(value.$table.order.map((id) => [id, table[id]])) : table;
    } else out[key] = value;
  }
  return out;
}

function outputExists(path) {
  try {
    lstatSync(path);
    return true;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}
