#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { identity } from "../../../scripts/lib/identity.mjs";
import { launch, realPath, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = `ledger-e2e: the password ledger's first run in the app, between hidden instances of one build.

  node packages/sync/scripts/ledger-e2e.mjs [<Debug app> [work dir]] [--control]

Two Macs on the switch off sync eight logins; A then deletes one while quit, so the deletion was never published.
From that state A relaunches with ARDIA_SYNC_REDESIGN=1 and is killed:
  4a at the mark: while Login Data's mark is being written (no mark, no ledger)
  4b after the mark: once the mark lands, before the ledger is written (a mark, no ledger)
  4c before the consistent cycle: once the upgrade's ledger is written (mark and ledger agree, the deletion pending)
From two Macs that have upgraded:
  4d at the published write: killed at the mark that follows publishing a local edit
  5a Login Data missing on the upgrade, 5b Login Data missing after it
  5c an unreadable ledger: passwords pause with the reason shown, nothing changes, other types keep syncing;
     restoring the ledger lifts the pause
After each, both Macs sync until settled: every login is kept, the deletion goes out once, nothing comes back,
A's mark and ledger agree, and nothing is held or paused. Each crash case fails as "hook late" unless the state at
the kill is the one it is meant to freeze.
--control strikes the upgrade's deletion from the ledger in 4c and deletes a login on purpose in 5a: both must fail.
Logs go to <work dir>-logs; both dirs are removed on a pass, and the work dir also on a failure.`;
if (process.argv.includes("-h") || process.argv.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}

const args = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const CONTROL = process.argv.includes("--control");
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const APP = realPath(path.resolve(args[0] ?? `${repo}/apps/browser/build-sync/Build/Products/Debug/${identity("FULL_PRODUCT_NAME")}`));
const WORK = path.resolve(args[1] ?? `${process.env.TMPDIR ?? "/tmp"}/ac-ledger-e2e`);
const LOGS = `${WORK}-logs`;
const FOLDER = `${WORK}/folder`;
const LEGACY = `${WORK}/legacy`;
const UPGRADED = `${WORK}/upgraded`;
const LEDGER_DOC = "sync-pw-ledger.json";
const MARK_KEY = "solara_sync_ledger";
const UNREADABLE = "Passwords aren't syncing: Solara can't read this Mac's password sync records. Everything else keeps syncing.";

fs.rmSync(WORK, { recursive: true, force: true });
fs.rmSync(LOGS, { recursive: true, force: true });
fs.mkdirSync(FOLDER, { recursive: true });
fs.mkdirSync(LOGS, { recursive: true });
const report = reporter(`${LOGS}/ledger-e2e.log`, { name: "ledger e2e" });
const note = report.log;
const check = (name, ok, detail = "") => report.record(name, { error: ok ? null : detail || "the assertion failed" });
const text = (x) => JSON.stringify(x);

const KEEP = Array.from({ length: 7 }, (_, i) => [`https://nne2e-keep${i}.example`, `u${i}`, `keep-${i}`]);
const GONE = ["https://nne2e-gone.example", "g", "gone"];
const ALL = [...KEEP, GONE];
const entry = ([origin, user, password]) => `${origin} ${user}=${password}`;
const sorted = (logins) => logins.map(entry).sort();
const KEPT = sorted(KEEP);
const EVERY = sorted(ALL);

const hookInstall = (plan) => `
  const m = globalThis.expo?.modules;
  if (!m?.ArdiaCEF || !m?.ArdiaSync || !m?.ArdiaShell) return false;
  if (!globalThis.__ledgerHook) {
    const plan = ${text(plan)};
    const h = (globalThis.__ledgerHook = { marks: 0, reads: 0, armed: false, stalled: null, ledgerAtInstall: m.ArdiaShell.readDocument(${text(LEDGER_DOC)}) != null });
    const cef = m.ArdiaCEF;
    const realCall = cef.engineCall;
    const stall = (at) => { h.stalled = at; return new Promise(() => {}); };
    cef.engineCall = (name, profile, json) => {
      if (name !== "ac_passwords_mark") return realCall.call(cef, name, profile, json);
      h.marks++;
      if (plan.mark === "before") return stall("before the mark");
      if (plan.mark === "after") return realCall.call(cef, name, profile, json).then(() => stall("after the mark"));
      if (plan.mark === "armed" && h.armed) return stall("at the armed mark");
      return realCall.call(cef, name, profile, json);
    };
    const native = m.ArdiaSync;
    const realRead = native.readPasswordsWithMark;
    native.readPasswordsWithMark = (...a) => {
      h.reads++;
      if (plan.readOnceLedger && m.ArdiaShell.readDocument(${text(LEDGER_DOC)}) != null) return stall("reading Login Data once the ledger is written");
      return realRead.apply(native, a);
    };
  }
  return !!globalThis.acSync && !!globalThis.ac?.store && Object.keys(ac.store.getState().windows).length > 0;`;

const apps = {};
async function quit(name) {
  await apps[name]?.quit();
  delete apps[name];
}
async function start(name, sealed, plan = null) {
  if (apps[name]) await quit(name);
  apps[name] = await launch(APP, {
    data: `${WORK}/${name}`,
    env: { ARDIA_SYNC_DEFAULT_FOLDER: FOLDER, ARDIA_TEST_REAUTH: "granted", ARDIA_SYNC_REDESIGN: sealed ? "1" : null },
    ready: { timeout: 120_000, test: plan ? hookInstall(plan) : "return !!globalThis.acSync && Object.keys(ac.store.getState().windows).length > 0" },
  });
  note(`${name}: pid ${apps[name].pid}, sealed ${sealed}, plan ${text(plan)}, log ${apps[name].log}`);
  const sealing = await ev(name, "return acSync.sealing()");
  if (sealing !== sealed) throw new Error(`${name}: launched with the switch ${sealed ? "on" : "off"}, but sealing is ${sealing}`);
}
async function kill(name) {
  const app = apps[name];
  const binary = execFileSync("ps", ["-o", "comm=", "-p", String(app.pid)], { encoding: "utf8" }).trim();
  if (!binary.startsWith(`${APP}/`)) throw new Error(`${name}: pid ${app.pid} runs ${binary}, not this build; not killing it`);
  delete apps[name];
  app.kill("SIGKILL");
  const end = Date.now() + 20_000;
  while (app.alive && Date.now() < end) await sleep(100);
  if (app.alive) throw new Error(`${name}: pid ${app.pid} still running 20 s after SIGKILL`);
  note(`${name}: killed pid ${app.pid}`);
}

async function ev(name, body, timeout = 90_000) {
  const what = body.replace(/\s+/g, " ").trim().slice(0, 140);
  try {
    const result = await apps[name].eval(body, { timeout });
    note(`[${name}] ${what} -> ${text(result)?.slice(0, 600)}`);
    return result;
  } catch (e) {
    note(`[${name}] ${what} -> error ${e.message}`);
    throw new Error(`${name}: ${e.message}`);
  }
}

const sync = async (...names) => {
  for (const n of names) await ev(n, "return acSync.syncNow()");
};
const save = (name, [origin, user, password]) =>
  ev(name, `const c = globalThis.expo.modules.ArdiaCEF; return c.deletePassword("", ${text(origin)}, ${text(user)}).then(() => c.savePassword("", ${text(origin)}, ${text(user)}, ${text(password)}));`);
const remove = (name, [origin, user]) => ev(name, `return globalThis.expo.modules.ArdiaCEF.deletePassword("", ${text(origin)}, ${text(user)})`);
async function passwords(name) {
  const answer = await ev(
    name,
    `const c = globalThis.expo.modules.ArdiaCEF;
    return c.listPasswords("").then((list) => Array.isArray(list?.passwords)
      ? Promise.all(list.passwords.map((p) => c.getPassword("", p.origin, p.username).then((r) => r?.error
          ? { error: "getPassword " + p.origin + " " + p.username + ": " + r.error }
          : p.origin.replace(/\\/$/, "") + " " + p.username + "=" + r.password)))
        .then((all) => all.find((x) => x?.error) ?? { all: all.sort() })
      : { error: "listPasswords answered " + JSON.stringify(list) });`,
  );
  if (answer?.all) return answer.all;
  throw new Error(`${name}: ${answer?.error ?? `the passwords eval answered ${text(answer)}`}`);
}
const status = (name) =>
  ev(name, "const u = acSync.useSync.getState(); return { status: u.status, error: u.error, passwordsError: u.passwordsError ?? null, pending: u.pending, held: u.heldPasswords, enabled: u.enabled };");
const heldCount = (s) => Math.max(0, ...Object.values(s.held ?? {}));
const addBookmark = (name, title) =>
  ev(name, `ac.store.getState().addBookmark({ profileId: "default", url: "https://nne2e-bm.example/${encodeURIComponent(title)}", title: ${text(title)} }); return true;`);
const hasBookmark = (name, title) => ev(name, `return Object.values(ac.store.getState().bookmarks.nodes).some((n) => n.title === ${text(title)});`);

async function until(what, test, names, timeout = 150_000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const result = await test();
    if (result) return result;
    await sync(...names);
    await sleep(1500);
  }
  throw new Error(`timed out: ${what}`);
}
async function stalled(name, timeout = 120_000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const h = await apps[name].eval("return globalThis.__ledgerHook ?? null", { timeout: 5000 });
    if (h?.stalled) return h;
    await sleep(200);
  }
  throw new Error(`${name}: the hook never stalled`);
}

const loginData = (name) => {
  const found = execFileSync("find", [`${WORK}/${name}`, "-name", "Login Data", "-type", "f"], { encoding: "utf8" }).trim().split("\n").filter(Boolean);
  const defaults = found.filter((f) => path.basename(path.dirname(f)) === "Default");
  if (defaults.length !== 1) throw new Error(`${name}: expected one Default/Login Data, found ${text(found)}`);
  return defaults[0];
};
const sql = (file, query) => execFileSync("sqlite3", [file, query], { encoding: "utf8" }).trim();
const markOf = (name) => sql(loginData(name), `select value from meta where key = '${MARK_KEY}'`) || null;
const loginRows = (name) => sql(loginData(name), "select origin_url, username_value, hex(password_value), date_password_modified from logins order by 1, 2");
const ledgerFile = (name) => `${WORK}/${name}/${LEDGER_DOC}`;
const ledgerOf = (name) => (fs.existsSync(ledgerFile(name)) ? JSON.parse(fs.readFileSync(ledgerFile(name), "utf8")) : null);
const onlyLedger = (doc) => {
  const all = Object.values(doc?.profiles ?? {});
  return all.length === 1 ? all[0] : null;
};
const markL = (mark) => (mark ? Number(String(mark).split("@")[0]) : null);
const goneKey = (ledger) => Object.keys(ledger?.keys ?? {}).find((k) => k.startsWith(`pw:${GONE[0]}`) && k.endsWith(`\n${GONE[1]}`));
const agree = (name) => {
  const mark = markOf(name);
  const ledger = onlyLedger(ledgerOf(name));
  return { ok: !!mark && !!ledger && markL(mark) === ledger.L, mark, L: ledger?.L ?? null };
};

const folderFiles = () =>
  fs.readdirSync(FOLDER, { recursive: true }).map(String).filter((f) => f.endsWith(".nns")).sort()
    .map((f) => { const s = fs.statSync(path.join(FOLDER, f)); return `${f}:${s.size}:${s.mtimeMs}`; });

const copy = (from, to) => {
  fs.rmSync(to, { recursive: true, force: true });
  execFileSync("cp", ["-R", from, to]);
};
const snapshot = (to) => {
  fs.mkdirSync(to, { recursive: true });
  for (const d of ["A", "B", "folder"]) copy(`${WORK}/${d}`, `${to}/${d}`);
};
const restore = (from) => {
  for (const d of ["A", "B", "folder"]) copy(`${from}/${d}`, `${WORK}/${d}`);
};
let caseNumber = 0;
async function endCase(label) {
  await Promise.all(Object.keys(apps).map((name) => quit(name).catch((e) => note(`quit ${name}: ${e.message}`))));
  const logs = `${LOGS}/${++caseNumber}-${label.replace(/[^a-z0-9]+/gi, "-")}`;
  fs.mkdirSync(logs, { recursive: true });
  for (const d of ["A", "B"]) {
    const log = `${WORK}/${d}/app.out.log`;
    if (fs.existsSync(log)) fs.copyFileSync(log, `${logs}/${d}.log`);
  }
  for (const d of ["A", "B", "folder"]) fs.rmSync(`${WORK}/${d}`, { recursive: true, force: true });
}
const removeLoginData = (name) => {
  const file = loginData(name);
  for (const f of [file, `${file}-journal`, `${file}-wal`, `${file}-shm`]) fs.rmSync(f, { force: true });
};

async function buildLegacy() {
  await start("A", false);
  check("A turns on sync", text(await ev("A", `return acSync.turnOnSync(${text(FOLDER)})`)) === '{"ok":true}');
  const phrase = (await ev("A", "return acSync.native.recoveryWords()")).join(" ");
  for (const login of ALL) await save("A", login);
  await start("B", false);
  check("B joins", text(await ev("B", `return acSync.enterRecoveryPhrase(${text(FOLDER)}, ${text(phrase)})`)) === '{"ok":true}');
  await until("B gets A's eight logins", async () => text(await passwords("B")) === text(EVERY), ["A", "B"]);
  await sync("A", "B");
  check("the fixture: A and B on the switch off hold the same eight logins", text(await passwords("A")) === text(EVERY) && text(await passwords("B")) === text(EVERY));
  await quit("A");
  await quit("B");
  check("the fixture: A has no mark and no ledger yet", !markOf("A") && !ledgerOf("A"), text({ mark: markOf("A") }));
  snapshot(LEGACY);
}

async function buildUpgraded() {
  restore(LEGACY);
  await start("A", true);
  await start("B", true);
  await until("A and B converge with the switch on", async () => agreeingLedgers() && text(await passwords("A")) === text(EVERY) && text(await passwords("B")) === text(EVERY), ["A", "B"]);
  await sync("A", "B", "A");
  await quit("A");
  await quit("B");
  check("the upgraded fixture: A's mark and ledger agree", agree("A").ok, text(agree("A")));
  snapshot(UPGRADED);
  for (const d of ["A", "B", "folder"]) fs.rmSync(`${WORK}/${d}`, { recursive: true, force: true });
}
const agreeingLedgers = () => !!onlyLedger(ledgerOf("A")) && !!onlyLedger(ledgerOf("B"));

function deleteGoneOffline() {
  const file = loginData("A");
  const markBefore = markOf("A");
  sql(file, `PRAGMA wal_checkpoint(TRUNCATE); PRAGMA foreign_keys = ON; delete from logins where origin_url like '${GONE[0]}%' and username_value = '${GONE[1]}';`);
  const left = sql(file, `select count(*) from logins where origin_url like '${GONE[0]}%'`);
  if (left !== "0") throw new Error(`A: the offline deletion left ${left} rows`);
  if (markOf("A") !== markBefore) throw new Error(`A: the offline deletion changed the mark (${markBefore} -> ${markOf("A")})`);
}

async function settle(label, expected, { sealedB }) {
  if (!apps.A) await start("A", true);
  if (!apps.B) await start("B", sealedB);
  await until(`${label}: A and B agree`, async () => {
    const a = await passwords("A");
    const b = await passwords("B");
    return text(a) === text(b) && text(a) === text(expected);
  }, ["A", "B"]).catch((e) => note(e.message));
  await sync("A", "B", "A");
  const a = await passwords("A");
  const b = await passwords("B");
  check(`${label}: B holds every login it should and nothing else`, text(b) === text(expected), text({ expected, b }));
  check(`${label}: A holds the same, nothing comes back`, text(a) === text(expected), text({ expected, a }));
  const s = await status("A");
  check(`${label}: nothing held or paused on A`, heldCount(s) === 0 && !s.passwordsError && !s.error && s.status !== "stalled", text(s));
  const before = folderFiles();
  await sync("A", "B", "A");
  check(`${label}: a further sync writes no folder file`, text(folderFiles()) === text(before), text({ before, after: folderFiles() }));
  await quit("A");
  await quit("B");
  check(`${label}: A's mark and ledger agree`, agree("A").ok, text(agree("A")));
}

async function crashCase(label, plan, frozen) {
  restore(LEGACY);
  deleteGoneOffline();
  await start("A", true, plan);
  const h = await stalled("A");
  await kill("A");
  const state = { stalled: h.stalled, ledgerAtInstall: h.ledgerAtInstall, mark: markOf("A"), ledger: onlyLedger(ledgerOf("A")) };
  const intended = !h.ledgerAtInstall && frozen(state);
  check(`${label}: the kill froze the intended state (else the hook was late)`, intended, text(state));
  if (intended) {
    if (CONTROL && plan.readOnceLedger) strikeGone();
    await settle(label, KEPT, { sealedB: false });
  }
  await endCase(label);
}

function strikeGone() {
  const doc = ledgerOf("A");
  for (const ledger of Object.values(doc.profiles)) for (const key of Object.keys(ledger.keys)) if (key.startsWith(`pw:${GONE[0]}`)) delete ledger.keys[key];
  fs.writeFileSync(ledgerFile("A"), JSON.stringify(doc));
  note("control: struck the upgrade's deletion from A's ledger");
}

async function publishedWriteCase() {
  const label = "4d killed at the published write";
  const edited = [KEEP[0][0], KEEP[0][1], "keep-0-edited"];
  const expected = sorted([edited, ...KEEP.slice(1), GONE]);
  restore(UPGRADED);
  await start("A", true, { mark: "armed" });
  await start("B", true);
  await sync("A", "B", "A");
  await save("A", edited);
  await ev("A", "globalThis.__ledgerHook.armed = true; void acSync.syncNow(); return true");
  const h = await stalled("A");
  await sync("B");
  const reached = await passwords("B");
  check(`${label}: the edit was published before the stalled mark (else the stall hit extract's write)`, reached.includes(entry(edited)), text({ h, reached }));
  await kill("A");
  await settle(label, expected, { sealedB: true });
  await endCase(label);
}

async function missingLoginDataCase(label, from) {
  restore(from);
  removeLoginData("A");
  const expected = CONTROL ? sorted(ALL.slice(1)) : EVERY;
  if (CONTROL) {
    await start("B", from === UPGRADED);
    await remove("B", KEEP[0]);
    await quit("B");
    note("control: B deleted keep0 on purpose");
  }
  await settle(label, CONTROL ? EVERY : expected, { sealedB: from === UPGRADED });
  await endCase(label);
}

async function unreadableLedgerCase() {
  const label = "5c an unreadable ledger";
  restore(UPGRADED);
  fs.writeFileSync(ledgerFile("A"), "{");
  const rows = loginRows("A");
  await start("A", true);
  await start("B", true);
  await sync("A", "B", "A", "B");
  const s = await status("A");
  check(`${label}: the Sync pane says passwords paused, and why`, s.passwordsError === UNREADABLE, text(s));
  check(`${label}: B keeps all eight`, text(await passwords("B")) === text(EVERY), text(await passwords("B")));
  await addBookmark("B", "ledger-e2e from B");
  await addBookmark("A", "ledger-e2e from A");
  await until(`${label}: bookmarks still sync both ways`, async () => (await hasBookmark("A", "ledger-e2e from B")) && (await hasBookmark("B", "ledger-e2e from A")), ["B", "A"], 90_000)
    .then(() => check(`${label}: other types keep syncing`, true))
    .catch((e) => check(`${label}: other types keep syncing`, false, e.message));
  await quit("A");
  check(`${label}: the ledger's bytes are unchanged`, fs.readFileSync(ledgerFile("A"), "utf8") === "{");
  check(`${label}: A's Login Data is unchanged`, loginRows("A") === rows);

  copy(`${UPGRADED}/A/${LEDGER_DOC}`, ledgerFile("A"));
  const after = ["https://nne2e-after.example", "a", "after"];
  await save("B", after);
  await start("A", true);
  await until(`${label}: restored, passwords resume`, async () => (await passwords("A")).includes(entry(after)), ["B", "A"], 90_000).catch((e) => note(e.message));
  const resumed = await status("A");
  check(`${label}: restoring the ledger lifts the pause`, !resumed.passwordsError, text(resumed));
  check(`${label}: and passwords resume`, (await passwords("A")).includes(entry(after)));
  await endCase(label);
}

try {
  await buildLegacy();
  if (!CONTROL) {
    await crashCase("4a killed at the mark", { mark: "before" }, (s) => s.stalled === "before the mark" && !s.mark && !s.ledger);
    await crashCase("4b killed after the mark", { mark: "after" }, (s) => s.stalled === "after the mark" && !!s.mark && !s.ledger);
  }
  await crashCase("4c killed before the consistent cycle", { readOnceLedger: true }, (s) => {
    const key = goneKey(s.ledger);
    return !!s.mark && markL(s.mark) === s.ledger?.L && !!key && s.ledger.keys[key].m === 0;
  });
  await missingLoginDataCase("5a Login Data missing on the upgrade", LEGACY);
  if (!CONTROL) {
    await buildUpgraded();
    await publishedWriteCase();
    await missingLoginDataCase("5b Login Data missing after the upgrade", UPGRADED);
    await unreadableLedgerCase();
  }
} catch (error) {
  check("the run finished", false, error.stack);
} finally {
  await endCase("last").catch((e) => note(`cleanup: ${e.message}`));
  const passed = report.summary();
  fs.rmSync(WORK, { recursive: true, force: true });
  if (passed) fs.rmSync(LOGS, { recursive: true, force: true });
  process.exitCode = passed ? 0 : 1;
}
