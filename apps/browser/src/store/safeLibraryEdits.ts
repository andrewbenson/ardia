import { confirm, readDocumentResult } from "@ardia/shell";
import { nativeSafeMode } from "./nativeStore";
import { engineProfile } from "./model";

export function refuseSafeLegacyDeletion(kind: "bookmarks" | "history", matches: (contents: string) => boolean): boolean {
  if (!nativeSafeMode()) return false;
  let pending = false;
  try {
    const result = readDocumentResult(`${kind}.json`);
    pending = "failure" in result || ("contents" in result && matches(result.contents));
  } catch {
    pending = true;
  }
  if (!pending) return false;
  void confirm({
    title: "Safe Mode",
    message: `${kind === "bookmarks" ? "These bookmarks" : "This history"} can't be deleted in safe mode while a legacy file is waiting to migrate. Quit and open Solara normally, then delete it.`,
    confirmTitle: "OK",
  });
  return true;
}

export function refuseSafeHistoryDeletion(engine: string, urls?: string[], since?: number): boolean {
  return refuseSafeLegacyDeletion("history", (contents) => {
    const document = JSON.parse(contents) as { history?: Record<string, { url: string; lastVisit: number; visitTimes?: number[] }[]> };
    return Object.entries(document.history ?? {}).some(([profile, rows]) => engineProfile(profile) === engine && rows.some((row) =>
      (!urls || urls.includes(row.url)) && (since === undefined || (row.visitTimes?.length ? row.visitTimes : [row.lastVisit]).some((at) => at >= since))));
  });
}
