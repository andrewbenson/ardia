import { engineCall, onEngineEvent } from "./engine";

export type EngineHistoryEntry = { url: string; title: string; visits: number; visitTimes: number[] };

export type HistoryChange =
  | { kind: "visit"; profile: string; url: string; title: string; visits: number; at: number }
  | { kind: "modified"; profile: string; rows: { url: string; title: string; visits: number }[] }
  | { kind: "deleted"; profile: string; all: boolean; urls: string[] };

type Row = { u: string; t: string; n: number };

export async function queryHistory(profile: string, maxUrls = 5000, maxVisits = 50): Promise<EngineHistoryEntry[]> {
  const { entries } = await engineCall<{ entries: (Row & { v: number[] })[] }>("ac_history_query", profile, { maxUrls, maxVisits });
  return entries.map((e) => ({ url: e.u, title: e.t, visits: e.n, visitTimes: e.v }));
}

export const watchHistory = (profile: string) => engineCall("ac_history_watch", profile);

type RawChange = Record<string, unknown>;

export const onHistoryChanged = (listener: (change: HistoryChange) => void) =>
  onEngineEvent("history.changed", (p) => {
    const profile = p.profile;
    const one = (c: RawChange) => {
      if (c.kind === "visit") listener({ kind: "visit", profile, url: c.u as string, title: c.t as string, visits: c.n as number, at: c.at as number });
      else if (c.kind === "modified")
        listener({ kind: "modified", profile, rows: (c.rows as Row[]).map((r) => ({ url: r.u, title: r.t, visits: r.n })) });
      else if (c.kind === "deleted") listener({ kind: "deleted", profile, all: !!c.all, urls: (c.urls as string[]) ?? [] });
    };
    if (p.kind === "batch") for (const c of (p.changes as RawChange[]) ?? []) one(c);
    else one(p);
  });
