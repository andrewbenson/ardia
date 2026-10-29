import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";

globalThis.__DEV__ = false;
registerHooks({
  resolve(specifier, context, next) {
    if (!context.parentURL?.endsWith("/lib/cliControl.ts") || specifier !== "../components/pages") return next(specifier, context);
    const stub = "export const isInternalTab = () => false;";
    return { url: `data:text/javascript,${encodeURIComponent(stub)}`, shortCircuit: true };
  },
});
const reasons = [];
globalThis.acTestNativeModules = {
  SolaraSettings: {
    servicesActive: () => true,
    installCli: async (reason) => {
      reasons.push(reason);
      return { ok: false, appVersion: "0.1.0", error: "The installer stopped in Swift.", lines: [] };
    },
  },
};
const cli = await import("./cliControl.ts");

test("with native services on, an install from the RN pane runs in Swift", async () => {
  const pending = cli.installCliInBackground("settings");
  assert.equal(cli.useCli.getState().installing, "settings");
  const result = await pending;
  assert.deepEqual(reasons, ["settings"]);
  assert.equal(result.error, "The installer stopped in Swift.");
  assert.equal(cli.useCli.getState().installing, null);
  assert.equal(cli.useCli.getState().error, "The installer stopped in Swift.");
});
