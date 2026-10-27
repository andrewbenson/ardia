import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../../../scripts/native/engineScenario.mjs", import.meta.url));

function oracle(seed, { strict = false, redesign = true } = {}) {
  const out = execFileSync(process.execPath, ["--no-warnings", script, "--oracle", "1", "--seed", String(seed), "--steps", "50"], {
    env: { ...process.env, ...(strict ? { ORACLE_STRICT: "1" } : {}), ...(redesign ? { ORACLE_REDESIGN: "1" } : {}) },
    encoding: "utf8",
    timeout: 240_000,
  });
  return out.split("\n").filter((line) => line.startsWith("oracle"));
}

const converges = (lines) => assert.ok(lines.some((l) => l.startsWith("oracle: 1 of 1")), lines.join("\n"));

for (const seed of [32144, 40636]) {
  test(`oracle seed ${seed} converges with every kept edit and no seq reused`, () => converges(oracle(seed)));
}

test("oracle seed 35309 converges with every kept edit and no seq reused", { todo: "step 7" }, () => converges(oracle(35309)));

for (const seed of [43, 212, 390, 398]) {
  test(`strict oracle seed ${seed} converges without counting position repairs as choices`, { todo: "step 12" }, () => converges(oracle(seed, { strict: true })));
}

test("oracle control: seed 43 converges when repairs count as choices", () => converges(oracle(43)));

test("oracle control: seed 43 converges with the switch off", () => converges(oracle(43, { redesign: false })));
