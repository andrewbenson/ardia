import { launchEnvironment } from "@ardia/shell";

export const isMocked = (() => {
  try { return typeof __DEV__ !== "undefined" && __DEV__ && !!launchEnvironment("ARDIA_LIVE_MOCK"); }
  catch { return false; }
})();
