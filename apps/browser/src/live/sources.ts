import { liveCommand } from "@ardia/settings";
import type { LiveFolder, LiveSourceId } from "./types";

export const SOURCES: Record<LiveSourceId, { name: string; site: string; kind: LiveFolder["kind"] }> = {
  github: { name: "GitHub", site: "https://github.com", kind: "pullRequests" },
  bitbucket: { name: "Bitbucket", site: "https://bitbucket.org", kind: "pullRequests" },
  notion: { name: "Notion", site: "https://www.notion.so", kind: "documents" },
  confluence: { name: "Confluence", site: "https://www.atlassian.com", kind: "documents" },
  gdrive: { name: "Google Drive", site: "https://drive.google.com", kind: "documents" },
};

export const connectGithub = (token: string) => liveCommand("connectGithub", { token });
export const connectBitbucket = (user: string, token: string) => liveCommand("connectBitbucket", { user, token });
export const connectNotion = (token: string) => liveCommand("connectNotion", { token });
export const connectConfluence = (site: string, email: string, token: string) => liveCommand("connectConfluence", { site, email, token });
export const disconnect = (source: LiveSourceId) => liveCommand("disconnect", { source });

export type DeviceFlow = { id: string; userCode: string; verificationUri: string; expiresAt: number; done: Promise<void>; cancel(): void };

export async function startGithubDeviceFlow(clientId: string): Promise<DeviceFlow> {
  const result = await liveCommand("startGithubDeviceFlow", { clientId });
  const flow = result.deviceFlow;
  if (!flow) throw new Error("GitHub device flow returned no code");
  return {
    ...flow,
    done: liveCommand("finishGithubDeviceFlow", { id: flow.id }).then(() => undefined),
    cancel: () => { void liveCommand("cancelGithubDeviceFlow", { id: flow.id }); },
  };
}

export function liveFolderIcon(folder: LiveFolder): { site: string; icon: string | null } {
  return { site: SOURCES[folder.sources[0] ?? "github"].site, icon: folder.icon ?? (folder.sources.length > 1 && folder.kind === "documents" ? "symbol:doc.text" : null) };
}
