#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { identity } from "../../../scripts/lib/identity.mjs";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = `sealed-e2e: password sync across the ARDIA_SYNC_REDESIGN switch, between hidden instances of one build.

  node packages/sync/scripts/sealed-e2e.mjs [<Debug app> [work dir]]

A Mac launched with ARDIA_SYNC_REDESIGN=1 seals passwords; one launched without it stands in for an older build,
since the folder format is the same. Cases: an older and a newer Mac converge; a realm saved with a trailing slash
syncs and settles; a password that reads "s1.abc" arrives as written; going back to the older build changes no
password; a deletion made before the upgrade and never published goes out after it; a held mass change stays held
across a relaunch; Stop Syncing in the middle of a cycle shows no fault and changes no password.`;
if (process.argv.includes("-h") || process.argv.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const APP = path.resolve(process.argv[2] ?? `${repo}/apps/browser/build-sync/Build/Products/Debug/${identity("FULL_PRODUCT_NAME")}`);
const WORK = path.resolve(process.argv[3] ?? `${process.env.TMPDIR ?? "/tmp"}/ac-sealed-e2e`);
const FOLDER = `${WORK}/folder`;

fs.rmSync(WORK, { recursive: true, force: true });
fs.mkdirSync(FOLDER, { recursive: true });
const report = reporter(`${WORK}/sealed-e2e.log`, { name: "sealed e2e" });
const note = report.log;
const check = (name, ok, detail = "") => report.record(name, { error: ok ? null : detail || "the assertion failed" });
const text = (x) => JSON.stringify(x);

const apps = {};
async function quit(name) {
  await apps[name]?.quit();
  delete apps[name];
}
async function start(name, sealed) {
  if (apps[name]) await quit(name);
  apps[name] = await launch(APP, {
    data: `${WORK}/${name}`,
    env: { ARDIA_SYNC_DEFAULT_FOLDER: FOLDER, ARDIA_TEST_REAUTH: "granted", ARDIA_SYNC_REDESIGN: sealed ? "1" : null },
    ready: { timeout: 120_000, test: "return !!globalThis.acSync && Object.keys(ac.store.getState().windows).length > 0" },
  });
  note(`${name}: pid ${apps[name].pid}, sealed ${sealed}, log ${apps[name].log}`);
  const sealing = await ev(name, "return acSync.sealing()");
  if (sealing !== sealed) throw new Error(`${name}: launched with the switch ${sealed ? "on" : "off"}, but sealing is ${sealing}`);
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
const save = (name, origin, user, password) =>
  ev(name, `const c = globalThis.expo.modules.ArdiaCEF; return c.deletePassword("", ${text(origin)}, ${text(user)}).then(() => c.savePassword("", ${text(origin)}, ${text(user)}, ${text(password)}));`);
const remove = (name, origin, user) => ev(name, `return globalThis.expo.modules.ArdiaCEF.deletePassword("", ${text(origin)}, ${text(user)})`);
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
  if (answer?.error) throw new Error(`${name}: ${answer.error}`);
  const log = await apps[name].eval("return globalThis.__devEvalLog ?? null", { timeout: 10_000 }).catch((e) => `unavailable (${e.message})`);
  throw new Error(`${name}: the passwords eval came back empty (${text(answer)}), app alive ${apps[name].alive}, eval log ${text(log)}`);
}
const status = (name) =>
  ev(name, "const u = acSync.useSync.getState(); return { status: u.status, error: u.error, passwordsError: u.passwordsError ?? null, pending: u.pending, held: u.heldPasswords, enabled: u.enabled };");
const fileCount = () => fs.readdirSync(FOLDER, { recursive: true }).filter((f) => String(f).endsWith(".nns")).length;

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

const BANK = "https://nne2e-bank.example";
const MAIL = "https://nne2e-mail.example";
const has = async (name, entry) => (await passwords(name)).includes(entry);
const mass = async (name) => (await passwords(name)).filter((p) => p.includes("=mass-")).length;
const heldCount = async (name) => Math.max(0, ...Object.values((await status(name)).held ?? {}));

try {
  await start("A", false);
  await start("B", true);
  check("A, the older build, turns on sync", text(await ev("A", `return acSync.turnOnSync(${text(FOLDER)})`)) === '{"ok":true}');
  const phrase = (await ev("A", "return acSync.native.recoveryWords()")).join(" ");
  await sync("A");
  check("B, the newer build, joins", text(await ev("B", `return acSync.enterRecoveryPhrase(${text(FOLDER)}, ${text(phrase)})`)) === '{"ok":true}');

  await save("A", BANK, "alice", "from-old-A");
  await save("B", MAIL, "bob", "from-new-B");
  await until("both logins on both Macs", async () => (await passwords("A")).length === 2 && (await passwords("B")).length === 2, ["A", "B"]);
  let [a, b] = [await passwords("A"), await passwords("B")];
  check("an older and a newer Mac converge", text(a) === text(b) && a.includes(`${BANK} alice=from-old-A`) && a.includes(`${MAIL} bob=from-new-B`), text({ a, b }));
  await save("B", BANK, "alice", "changed-on-new-B");
  await until("B's change reaches A", () => has("A", `${BANK} alice=changed-on-new-B`), ["B", "A"]);
  await save("A", MAIL, "bob", "changed-on-old-A");
  await until("A's change reaches B", () => has("B", `${MAIL} bob=changed-on-old-A`), ["A", "B"]);
  check("edits go both ways between the builds", true);

  await save("B", "https://nne2e-slash.example/", "carol", "slash-realm");
  await save("B", "https://nne2e-literal.example", "dave", "s1.abc");
  await until("the slash realm and the literal reach A", async () => (await has("A", "https://nne2e-slash.example carol=slash-realm")) && (await has("A", "https://nne2e-literal.example dave=s1.abc")), ["B", "A"]);
  check("a realm saved with a trailing slash syncs", true);
  check('a password that reads "s1.abc" arrives as written', await has("A", "https://nne2e-literal.example dave=s1.abc"));
  await sync("B", "A", "B");
  const settled = fileCount();
  await sync("B", "A", "B", "A");
  const quiet = await status("B");
  check("and B settles: nothing pending, no fault, no files written while nothing changes", fileCount() === settled && quiet.pending === 0 && !quiet.error && !quiet.passwordsError, text({ settled, now: fileCount(), quiet }));

  b = await passwords("B");
  await start("B", false);
  await sync("B", "A", "B");
  const back = await passwords("B");
  check("going back to the older build changes no password", text(back) === text(b), text({ b, back }));
  check("and its sync isn't stalled", (await status("B")).status !== "stalled", text(await status("B")));

  await remove("A", MAIL, "bob");
  await start("A", true);
  await until("A's deletion, made before the upgrade, reaches B", async () => !(await passwords("B")).some((p) => p.startsWith(`${MAIL} bob=`)), ["A", "B"]);
  check("a deletion made before the upgrade and never published goes out after it", !(await passwords("A")).some((p) => p.startsWith(`${MAIL} bob=`)));

  await start("B", true);
  for (let i = 0; i < 8; i++) await save("B", `https://nne2e-mass${i}.example`, "m", `mass-${i}`);
  await until("the eight logins reach A", async () => (await mass("A")) === 8, ["B", "A"]);
  for (let i = 0; i < 8; i++) await remove("A", `https://nne2e-mass${i}.example`, "m");
  await until("A holds its mass deletion", async () => (await heldCount("A")) >= 8, ["A"], 90_000);
  await start("A", true);
  await sync("A", "B", "A");
  check("a held mass change stays held across a relaunch", (await heldCount("A")) >= 8, text(await status("A")));
  check("and none of it reaches B", (await mass("B")) === 8, text(await passwords("B")));

  b = await passwords("B");
  await ev("B", "void acSync.syncNow(); return acSync.stopSync()");
  await sleep(2000);
  const stopped = await status("B");
  check("Stop Syncing in the middle of a cycle shows no fault", !stopped.enabled && stopped.status !== "stalled" && !stopped.error, text(stopped));
  check("and changes no password here", text(await passwords("B")) === text(b), text({ b, after: await passwords("B") }));
} catch (error) {
  check("the run finished", false, error.stack);
} finally {
  await Promise.all(Object.keys(apps).map((name) => quit(name).catch((e) => note(`quit ${name}: ${e.message}`))));
  process.exitCode = report.summary() ? 0 : 1;
}
