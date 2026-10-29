import type * as Expo from "expo-modules-core";
import { ardiaCoreNativeModules, ardiaCoreOptionalNativeModules } from "./ardiacore";
import { shellNativeModules, shellOptionalNativeModules } from "./shell";

const settingsCommands: Record<string, string> = {
  deleteHistory: "ac_history_delete_urls",
  importHistory: "ac_history_import",
  addHistoryVisits: "ac_history_add",
  applyBookmarks: "ac_bookmarks_apply",
  storeFavicon: "ac_favicons_set",
};

const settingsModule = {
  libraryCommand: async (kind: string, profile: string, payload: Record<string, unknown>) => {
    const name = settingsCommands[kind];
    if (!name) throw new Error(`unknown library command ${kind}`);
    const args = kind === "importHistory"
      ? { rows: (payload.rows as { url: string; title: string; visits: number; lastVisit: number }[]).map((r) => ({ u: r.url, t: r.title, n: r.visits, l: r.lastVisit })) }
      : kind === "addHistoryVisits"
        ? { pages: (payload.pages as { url: string; title: string; visitTimes: number[] }[]).map((p) => ({ u: p.url, t: p.title, v: p.visitTimes })), toleranceMs: payload.toleranceMs }
        : payload;
    const json = await ardiaCoreNativeModules.ArdiaCEF.engineCall(name, profile, JSON.stringify(args));
    const result = JSON.parse(json);
    if (result?.error) throw new Error(result.error);
    return kind === "addHistoryVisits" ? result.added : result;
  },
};

const nativeModules: Record<string, object> = { ...shellNativeModules, ...ardiaCoreNativeModules, SolaraSettings: settingsModule };
const optionalNativeModules: Record<string, () => object | null> = { ...shellOptionalNativeModules, ...ardiaCoreOptionalNativeModules };
const testModules = () => (globalThis as { acTestNativeModules?: Record<string, object> }).acTestNativeModules;

export const requireNativeModule: typeof Expo.requireNativeModule = <Module,>(name: string) => (nativeModules[name] ?? {}) as Module;

export const requireOptionalNativeModule: typeof Expo.requireOptionalNativeModule = <Module,>(name: string) =>
  (testModules()?.[name] ?? (name in optionalNativeModules ? optionalNativeModules[name]!() : (nativeModules[name] ?? null))) as Module | null;

export const requireNativeViewManager: typeof Expo.requireNativeViewManager = () => () => null;
