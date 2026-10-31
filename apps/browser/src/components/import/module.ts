import type * as ImportApi from "@solara/import";

let api: typeof ImportApi | null | undefined;

export function importModule(): typeof ImportApi | null {
  if (api === undefined) {
    try {
      api = require("@solara/import") as typeof ImportApi;
    } catch {
      api = null;
    }
  }
  return api;
}
