import type { LiveFolder, LiveSourceId } from "./types";

export const SOURCES: Record<LiveSourceId, { name: string; site: string; kind: LiveFolder["kind"] }> = {
  github: { name: "GitHub", site: "https://github.com", kind: "pullRequests" },
  notion: { name: "Notion", site: "https://www.notion.so", kind: "documents" },
  gdrive: { name: "Google Drive", site: "https://drive.google.com", kind: "documents" },
};

export function liveFolderIcon(folder: LiveFolder): { site: string; icon: string | null } {
  return { site: SOURCES[folder.sources[0] ?? "github"].site, icon: folder.icon ?? (folder.sources.length > 1 && folder.kind === "documents" ? "symbol:doc.text" : null) };
}
