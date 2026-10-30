import { getDisplayMediaSources, type DisplayMediaAudio, type DisplayMediaRequest, type DisplayMediaSource } from "@ardia/ardiacore";
import { runningAppIcon } from "@ardia/shell";
import { windowShellActive } from "@ardia/settings";
import { useEffect, useRef, useState } from "react";
import { useTheme } from "../../lib/theme";
import { webviews } from "../../lib/webviews";
import { useBrowser } from "../../store/browser";
import { engineProfile } from "../../store/model";
import { PANEL, POPOVER_MARGIN } from "../layout/controls";
import { useNativePaneOverlay } from "../layout/nativePaneOverlays";
import { usePages } from "../layout/pageState";
import { noteTabShare } from "./ShareBar";
import { useMedia } from "./state";
import { useWindowId } from "../../store/hooks";
import { addMediaActions, addPickerHandler, callPickerHandler, mediaTheme, NativeMediaView, type PickerHandlers } from "./nativeMedia";

const shareHandlers: PickerHandlers = {};
addMediaActions({ sharePicker: (_windowId, tabId, extra) => callPickerHandler(shareHandlers, tabId, extra) });

const WIDTH = 460;
const REFRESH_MS = 2500;
const TAB = "tab:";
const AUDIO_SHARED_BY_DEFAULT = { tab: true, screen: false, window: false };

type SourceKind = keyof typeof AUDIO_SHARED_BY_DEFAULT;

const audioLabel = (kind: SourceKind, audio: DisplayMediaAudio) =>
  kind === "tab" ? "Also share tab audio" : kind === "window" && audio.window === "application" ? "Also share application audio" : "Also share system audio";

const audioOffered = (kind: SourceKind | null, audio: DisplayMediaAudio | null) =>
  !!audio && (kind === "tab" ? audio.tab : kind === "screen" ? audio.screen : kind === "window" ? !!audio.window : false);

function shareableTabs(tabId: string) {
  const s = useBrowser.getState();
  const tab = s.tabs[tabId];
  if (!tab) return [];
  const profile = engineProfile(tab.profileId);
  const live = new Set(Object.values(usePages.getState().browsers));
  return Object.values(s.tabs)
    .filter((t) => live.has(t.id) && engineProfile(t.profileId) === profile && /^https?:|^file:/.test(t.url))
    .sort((a, b) => (a.id === tabId ? 1 : b.id === tabId ? -1 : b.lastActiveAt - a.lastActiveAt));
}

type Pending = DisplayMediaRequest & { pageUrl: string };

export function requestDisplayMedia(tabId: string, request: DisplayMediaRequest) {
  const pending = useMedia.getState().displayRequests[tabId];
  if (pending) void webviews.get(tabId)?.resolveDisplayMedia(pending.id, null);
  const pageUrl = useBrowser.getState().tabs[tabId]?.url ?? "";
  useMedia.setState((m) => ({ displayRequests: { ...m.displayRequests, [tabId]: { ...request, pageUrl } as Pending } }));
}

if (__DEV__)
  (globalThis as { acSharePicker?: unknown }).acSharePicker = {
    answerDisplayMedia: (tabId: string, sourceId: string | null, audio = false) => answerDisplayMedia(tabId, sourceId, audio),
    shareTab: (tabId: string, sharedTabId: string, audio = true) => shareTab(tabId, sharedTabId, audio),
  };

export function answerDisplayMedia(tabId: string, sourceId: string | null, audio = false) {
  const request = useMedia.getState().displayRequests[tabId];
  if (!request) return;
  void webviews.get(tabId)?.resolveDisplayMedia(request.id, sourceId, audio);
  useMedia.setState((m) => {
    const displayRequests = { ...m.displayRequests };
    delete displayRequests[tabId];
    return { displayRequests };
  });
}

async function shareTab(tabId: string, sharedTabId: string, audio: boolean) {
  const request = useMedia.getState().displayRequests[tabId];
  if (!request) return;
  const source = await webviews.get(sharedTabId)?.mediaCaptureSourceId();
  if (useMedia.getState().displayRequests[tabId] !== request) return;
  if (source) noteTabShare(tabId, sharedTabId, request.origin);
  answerDisplayMedia(tabId, source ?? null, audio);
}

export function cancelDisplayMediaOnNavigation() {
  const page = (url: string) => url.replace(/#.*$/, "");
  return useBrowser.subscribe((s, prev) => {
    if (s.tabs === prev.tabs) return;
    for (const [tabId, request] of Object.entries(useMedia.getState().displayRequests) as [string, Pending][]) {
      const url = s.tabs[tabId]?.url;
      if (url !== undefined && page(url) !== page(request.pageUrl)) answerDisplayMedia(tabId, null);
    }
  });
}

const hostOf = (origin: string) => {
  try {
    return new URL(origin).host || origin;
  } catch {
    return origin;
  }
};

function PaneSharePicker({ windowId, tabId, state }: { windowId: string; tabId: string; state: object }) {
  useNativePaneOverlay(true, windowId, tabId, "sharePicker", state);
  return null;
}

export function SharePicker({ tabId, paneWidth, nativeAllowed = true }: { tabId: string; paneWidth: number; nativeAllowed?: boolean }) {
  const theme = useTheme();
  const request = useMedia((m) => m.displayRequests[tabId]);
  const [sources, setSources] = useState<DisplayMediaSource[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [shareAudio, setShareAudio] = useState(AUDIO_SHARED_BY_DEFAULT);
  const [icons, setIcons] = useState<Record<number, string | null>>({});
  const windowId = useWindowId();
  const [inShell] = useState(() => nativeAllowed && windowShellActive(windowId));
  const handler = useRef<(extra: Record<string, unknown>) => void>(() => {});
  useEffect(() => {
    return addPickerHandler(shareHandlers, tabId, (extra) => handler.current(extra));
  }, [tabId]);

  useEffect(() => {
    if (!request) return;
    setSources(request.sources);
    setSelected(null);
    setShareAudio(AUDIO_SHARED_BY_DEFAULT);
    let live = true;
    const t = setInterval(() => void getDisplayMediaSources().then((next) => live && setSources(next)), REFRESH_MS);
    return () => {
      live = false;
      clearInterval(t);
    };
  }, [request?.id]);

  useEffect(() => {
    const missing = [...new Set(sources.map((s) => s.pid).filter((pid): pid is number => pid !== undefined && !(pid in icons)))];
    if (!missing.length) return;
    void Promise.all(missing.map(async (pid) => [pid, await runningAppIcon(pid, 20)] as const)).then((entries) =>
      setIcons((current) => ({ ...current, ...Object.fromEntries(entries) })),
    );
  }, [sources]);

  if (!request) return null;
  const tabs = shareableTabs(tabId);
  const screens = sources.filter((s) => s.kind === "screen");
  const windows = sources.filter((s) => s.kind === "window");
  const isTab = (id: string | null) => !!id && id.startsWith(TAB) && tabs.some((t) => TAB + t.id === id);
  const kindOf = (id: string | null): SourceKind | null => (isTab(id) ? "tab" : (sources.find((s) => s.id === id)?.kind ?? null));
  const valid = !!kindOf(selected);
  const selectedKind = kindOf(selected);
  const audioFor = (kind: SourceKind | null) => !!kind && audioOffered(kind, request.audio) && shareAudio[kind];
  const share = (id: string | null = selected) => {
    const kind = kindOf(id);
    if (!id || !kind) return;
    if (kind === "tab") return void shareTab(tabId, id.slice(TAB.length), audioFor(kind));
    answerDisplayMedia(tabId, id, audioFor(kind));
  };
  const cancel = () => answerDisplayMedia(tabId, null);
  const frameHost = request.frameOrigin ? hostOf(request.frameOrigin) : "";
  const receiver = frameHost && frameHost !== hostOf(request.origin) ? `${frameHost}, a frame on this page,` : "The site";
  const width = Math.min(WIDTH, paneWidth - 24);
  const subtitle = audioFor(selectedKind)
    ? `${receiver} will see and hear what you choose.`
    : request.audio && !request.audio.screen && !request.audio.window && selectedKind !== "tab"
      ? `${receiver} will see what you choose. Only tabs share their audio.`
      : `${receiver} will see what you choose.`;

  handler.current = (extra) => {
    const id = typeof extra.id === "string" ? extra.id : null;
    switch (extra.action) {
      case "select":
        return id && setSelected(id);
      case "share":
        return share(id ?? selected);
      case "cancel":
        return cancel();
      case "audio":
        return selectedKind && setShareAudio((current) => ({ ...current, [selectedKind]: !!extra.value }));
    }
  };
  const state = {
    requestId: request.id,
    tabId,
    title: `Share your screen with ${hostOf(request.origin)}`,
    subtitle,
    tabs: tabs.map((t) => ({ id: t.id, title: t.title || t.url, url: t.url, favicon: t.favicon ?? null, profileId: t.profileId, current: t.id === tabId })),
    screens: screens.map((src) => ({ id: src.id, name: src.name, size: src.width ? `${src.width} × ${src.height}` : null, aspect: src.width && src.height ? src.height / src.width : 10 / 16 })),
    windows: windows.map((src) => {
      const title = src.name || src.app || "Window";
      return { id: src.id, title, app: src.app && src.app !== title ? src.app : null, icon: src.pid !== undefined ? (icons[src.pid] ?? null) : null };
    }),
    selected,
    valid,
    audio: selectedKind && request.audio && audioOffered(selectedKind, request.audio) ? { label: audioLabel(selectedKind, request.audio), value: shareAudio[selectedKind] } : null,
    tileWidth: (width - 2 * PANEL.rowInset - 8) / 2,
    theme: mediaTheme(theme),
    popover: { width, top: POPOVER_MARGIN, left: (paneWidth - width) / 2 },
  };
  if (inShell) return <PaneSharePicker key={request.id} windowId={windowId} tabId={tabId} state={state} />;
  return <NativeMediaView key={request.id} kind="media.sharePicker" windowId={windowId} state={state} />;
}
