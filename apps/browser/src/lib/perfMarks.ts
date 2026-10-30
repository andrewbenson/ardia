import { NativeModules } from "react-native";
import { readDocument } from "@ardia/shell";
import { useBrowser, type BrowserState } from "../store/browser";
import { activeTabId, findLast } from "../store/model";
import { perfProbeEnabled } from "./perfProbe";

type NativeTiming = {
  setEnabled(on: boolean): void;
  markFrame(key: string, kind: string): void;
  markPresented?(key: string, kind: string): void;
  lastInput(): [at: number, kind: number];
  drain(): [key: string, kind: string, at: number][];
};

const native = NativeModules.ACFieldTiming as NativeTiming | undefined;
const samples = new Map<string, number[]>();
const counts = new Map<string, number>();
const marks = new Map<string, [string, number][]>();
const pending: ({ journey: "j2"; key: string; t0: number; heard: number; bar?: number; barSettled?: boolean; keyAt?: number; suggested?: number; query?: string; generation?: string } | { journey: "j4"; key: string; t0: number; until?: number })[] = [];
type QuerySample = { tabId: string; query: string; generation: string; keyAt: number; committedAt?: number; shownAt?: number; invalidated?: boolean };
const queries: QuerySample[] = [];
const queryLatencies: { query: string; generation: string; ms: number }[] = [];
const panelMarks: [string, number][] = [];
const probedLatency: number[] = [];
let started = false;
let timer: ReturnType<typeof setTimeout> | undefined;

if (perfProbeEnabled) (globalThis as { __omniboxLatency?: number[] }).__omniboxLatency = probedLatency;

function sample(step: string, ms: number | null) {
  if (ms === null || !(ms >= 0 && ms < 60_000)) return;
  let list = samples.get(step);
  if (!list) samples.set(step, (list = []));
  if (list.length < 500) list.push(Math.round(ms));
}

function count(what: string) { counts.set(what, (counts.get(what) ?? 0) + 1); }
function lastInput(now = Date.now()): number | null {
  const [at = 0] = native?.lastInput() ?? [];
  return at > 0 && at <= now + 5 && now - at <= 1000 ? at : null;
}

function pullMarks(now: number) {
  for (const [key, kind, at] of native?.drain() ?? []) {
    let list = marks.get(key);
    if (!list) marks.set(key, (list = []));
    list.push([kind, at]);
  }
  for (const query of queries) {
    if (!query.invalidated && query.committedAt !== undefined) query.shownAt = mark(`omnibox:${query.tabId}:${query.generation}`, "suggestFrame", query.keyAt) ?? undefined;
  }
  for (const [key, list] of marks) {
    const fresh = list.filter(([, at]) => now - at < 120_000);
    if (fresh.length) marks.set(key, fresh);
    else marks.delete(key);
  }
}

function mark(key: string, kind: string, from: number, until = Infinity): number | null {
  let first: number | null = null;
  for (const [k, at] of marks.get(key) ?? []) if (k === kind && at >= from - 1 && at < until && (first === null || at < first)) first = at;
  return first;
}

function watchStore(s: BrowserState, prev: BrowserState) {
  if (s.windows === prev.windows) return;
  for (const id in s.windows) {
    const now = activeTabId(s, id);
    const before = activeTabId(prev, id);
    if (!now || now === before || s.windows[id]!.profileId !== prev.windows[id]?.profileId) continue;
    const t0 = lastInput();
    if (t0 !== null && !prev.tabs[now] && !s.tabs[now]!.url) begin({ journey: "j2", key: now, t0, heard: Date.now() });
  }
}

function begin(p: (typeof pending)[number]) {
  if (pending.length >= 50) pending.shift();
  pending.push(p);
  if (!timer) timer = setTimeout(tick, 1000);
}

function tick() {
  timer = undefined;
  const now = Date.now();
  pullMarks(now);
  for (let i = pending.length - 1; i >= 0; i--) {
    const p = pending[i]!;
    let done = false;
    if (p.journey === "j2") {
      if (p.bar === undefined) {
        if (now - p.t0 >= 5000) { count("j2_no_bar"); done = true; }
      } else {
        if (!p.barSettled) {
          const typeable = mark(p.key, "typeable", p.t0);
          if (typeable !== null || now - p.t0 >= 5000) {
            p.barSettled = true;
            sample("j2_js", p.heard - p.t0);
            sample("j2_commit", p.bar - p.t0);
            sample("j2_shown", (mark(p.key, "bar", p.t0) ?? p.t0) - p.t0);
            sample("j2_typeable", typeable === null ? null : typeable - p.t0);
          }
        }
        if (p.barSettled && p.suggested !== undefined) {
          const shown = p.generation === undefined
            ? mark(p.key, "suggest", p.suggested)
            : mark(`omnibox:${p.key}:${p.generation}`, "suggestFrame", p.keyAt ?? p.suggested);
          if (shown !== null || now - p.suggested >= 5000) {
            sample("j2_suggest", shown === null || p.keyAt === undefined ? null : shown - p.keyAt);
            done = true;
          }
        }
        if (now - p.t0 > 60_000) done = true;
      }
    } else {
      const request = mark(p.key, "request", p.t0, p.until ?? Infinity);
      if (request === null && (p.until !== undefined || now - p.t0 >= 3000)) { count("j4_no_load"); done = true; }
      else if (request !== null) {
        const fcp = mark(p.key, "fcp", p.t0, p.until ?? Infinity);
        if (fcp !== null || p.until !== undefined || now - p.t0 >= 30_000) {
          sample("j4_request", request - p.t0);
          for (const [step, kind] of [["j4_start", "start"], ["j4_commit", "commit"]] as const) {
            const at = mark(p.key, kind, p.t0, p.until ?? Infinity);
            sample(step, at === null ? null : at - p.t0);
          }
          sample("j4_fcp", fcp === null ? null : fcp - p.t0);
          sample("j4_engine", fcp === null ? null : fcp - request);
          if (fcp === null) count(p.until === undefined ? "j4_no_paint" : "j4_replaced");
          done = true;
        }
      }
    }
    if (done) pending.splice(i, 1);
  }
  if (pending.length) timer = setTimeout(tick, 1000);
}

export function startPerfMarks() {
  if (started || readDocument("bench-perf") !== "1") return;
  started = true;
  native?.setEnabled(true);
  useBrowser.subscribe(watchStore);
}

function newTabFor(tabId: string) { return pending.find((p) => p.journey === "j2" && p.key === tabId); }
export function journeyBarCommitted(tabId: string) {
  if (!started) return;
  const p = newTabFor(tabId);
  if (!p || p.journey !== "j2" || p.bar !== undefined) return;
  p.bar = Date.now();
  native?.markFrame(tabId, "bar");
}
export function journeyBarFocused(tabId: string) {
  if (!started) return;
  const p = newTabFor(tabId);
  if (p?.journey === "j2" && p.bar !== undefined) native?.markFrame(tabId, "typeable");
}
export function journeyKeystroke(tabId: string, query?: string, generation?: string) {
  if (!started) return;
  const p = newTabFor(tabId);
  const keyAt = lastInput() ?? Date.now();
  if (query !== undefined && generation !== undefined) {
    if (queries.length >= 500) queries.shift();
    queries.push({ tabId, query, generation, keyAt });
    if (p?.journey === "j2" && p.bar !== undefined) {
      p.keyAt = keyAt;
      p.query = query;
      p.generation = generation;
      p.suggested = undefined;
    }
  } else if (p?.journey === "j2" && p.bar !== undefined && p.keyAt === undefined) p.keyAt = keyAt;
}
export function journeySuggestions(tabId: string, query?: string, generation?: string, at?: number) {
  if (!started) return;
  const p = newTabFor(tabId);
  if (query !== undefined && generation !== undefined) {
    const sample = findLast(queries, (q) => q.tabId === tabId);
    if (!sample || sample.invalidated || sample.query !== query || sample.generation !== generation || sample.committedAt !== undefined || !Number.isFinite(at)) return;
    sample.committedAt = at;
    if (p?.journey === "j2" && p.query === query && p.generation === generation) p.suggested = at;
    return;
  }
  if (p?.journey !== "j2" || p.keyAt === undefined || p.suggested !== undefined || p.generation !== undefined) return;
  p.suggested = Date.now();
  native?.markFrame(tabId, "suggest");
}
export function journeyQueryInvalidated(tabId: string, generation?: string) {
  if (!started || generation === undefined) return;
  const query = findLast(queries, (q) => q.tabId === tabId && q.generation === generation);
  if (query) {
    query.invalidated = true;
    query.shownAt = undefined;
  }
  const p = newTabFor(tabId);
  if (p?.journey === "j2" && p.generation === generation) p.suggested = undefined;
}
export function journeyNavigate(tabId: string) {
  if (!started) return;
  const now = Date.now();
  const t0 = lastInput(now) ?? now;
  for (const p of pending) if (p.journey === "j4" && p.key === tabId && p.until === undefined) p.until = t0;
  begin({ journey: "j4", key: tabId, t0 });
}
export function markPanelFrame(kind: "dispatch" | "mount" | "growStart" | "growEnd") {
  panelMarks.push([kind, Date.now()]);
  if (panelMarks.length > 64) panelMarks.shift();
  if (kind === "mount") native?.markFrame("panel", kind);
}
export const panelFrameMarks = () => panelMarks.splice(0);
export function sampleOmniboxLatency(ms: number, query?: string, generation?: string) {
  if (started && query !== undefined && generation !== undefined) {
    if (queryLatencies.length < 500) queryLatencies.push({ query, generation, ms });
    return;
  }
  if (perfProbeEnabled && probedLatency.length < 10_000) probedLatency.push(ms);
}
export const devJourneys = () => ({ on: started, native: !!native, pending: pending.map((p) => ({ ...p })), samples: Object.fromEntries(samples), counts: Object.fromEntries(counts), marks: Object.fromEntries(marks), queries: queries.map((q) => ({ ...q })), queryLatencies: queryLatencies.map((q) => ({ ...q })) });
