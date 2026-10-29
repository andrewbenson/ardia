import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const appPath = process.argv[2];
if (!appPath) {
  console.error(`usage: node apps/browser/scripts/probe-gate-test.mjs <Debug Solara.app under apps/browser/build-*>

The native probe gate. A scratch data dir without the .solara-probe-scratch marker, holding a crafted inbox request:
the app answers nothing, creates no claimed/ or outbox/ dir and leaves the request where it was. Then the control: a
fresh scratch dir with the marker gets a probe.hello reply from the same build.`);
  process.exit(2);
}
const root = mkdtempSync(join(tmpdir(), "ac-probe-gate-"));
const rep = reporter(join(root, "probe-gate-test.log"), { name: "probe-gate-test" });
let instance = null;
try {
  await rep.check("gate-off-ignores-a-crafted-inbox", async () => {
    const data = join(root, "unmarked");
    const inbox = join(data, "probes", "inbox");
    mkdirSync(inbox, { recursive: true, mode: 0o700 });
    const id = randomUUID();
    writeFileSync(join(inbox, `${id}.json`), JSON.stringify({ protocol: 1, id, command: "probe.hello", args: {}, expiresAtMs: Date.now() + 30000 }));
    instance = await launch(resolve(appPath), { data, onboarded: true });
    await sleep(2000);
    assert.equal(existsSync(join(data, ".solara-probe-scratch")), false, "no marker");
    assert.equal(existsSync(join(data, "probes", "claimed")), false, "nothing claimed");
    assert.equal(existsSync(join(data, "probes", "outbox")), false, "no outbox");
    assert.ok(readFileSync(join(inbox, `${id}.json`), "utf8").includes(id), "the request is untouched");
    await instance.quit();
    instance = null;
  });
  await rep.check("gate-on-answers-hello", async () => {
    instance = await launch(resolve(appPath), { data: join(root, "marked"), fresh: true, onboarded: true });
    const hello = await instance.probe("probe.hello", {}, { timeout: 10000 });
    assert.equal(hello.protocol, 1);
    assert.equal(hello.pid, instance.pid);
    await instance.quit();
    instance = null;
  });
} finally {
  await instance?.quit().catch(() => {});
}
const failed = rep.results.filter((r) => !r.ok);
if (!failed.length) rmSync(root, { recursive: true, force: true });
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);
