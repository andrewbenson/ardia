import { hapticTick, onAppEvent, setDragEscapeCapture } from "@solara/shell";
import { requireOptionalNativeModule } from "expo-modules-core";
import { create } from "zustand";
import type { TabPlacement } from "../../store/organize";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import "../layout/nativeTabDrag";
import { arrangeLive } from "./pinnedOrder";
import { closeFolderPanel } from "./tileFolderUi";

type Frame = { x: number; y: number; w: number; h: number };
type ProbeItem = Frame & {
  key: string;
  kind: string;
  section: string;
  tabIds: string[];
  parentGroup: string | null;
  groupId: string | null;
  folderId: string | null;
};
type Probe = {
  active: boolean;
  external: number;
  gapKey: string | null;
  pitch: number;
  marks: NativeMarks;
  items: ProbeItem[];
  regions: Record<string, Frame>;
  landed: { key: string; x: number; y: number } | null;
  viewport: Frame | null;
  scrollY: number;
};
export type NativeMarks = {
  sources: string[];
  folderAway: boolean;
  folderTarget: string | null;
  pins: boolean;
  pinCount: number;
  dropInto: string | null;
};

type DragModule = {
  escape(): Promise<void>;
  external(windowId: string, phase: string, x: number, y: number, count: number): Promise<string | null>;
  panel(windowId: string, frameJSON: string | null): Promise<void>;
  panelDrag(windowId: string, phase: string, tabId: string, x: number, y: number): Promise<void>;
  startProbe(windowId: string): Promise<string>;
  probe(windowId: string): string;
  clearLanded(windowId: string): Promise<void>;
  scrollTo(windowId: string, y: number): Promise<void>;
};

const native = requireOptionalNativeModule<DragModule>("SolaraSidebarDrag");

export const useNativeDragMarks = create<{
  windowId: string | null;
  marks: NativeMarks | null;
}>()(() => ({ windowId: null, marks: null }));

addNativeSettingsHandlers({
  "sidebar.drag.live": (sequence: string[]) => arrangeLive(sequence),
  "sidebar.drag.escape": (on: boolean) => setDragEscapeCapture(on),
  "sidebar.drag.haptic": () => hapticTick(),
  "sidebar.drag.closePanel": () => closeFolderPanel(),
  "sidebar.drag.marks": (windowId: string, marks: NativeMarks) => useNativeDragMarks.setState({ windowId, marks }),
});

if (native) onAppEvent((e) => e.type === "dragEscape" && void native.escape());

export const nativeSidebarDrag = {
  external(windowId: string, phase: "enter" | "move" | "leave" | "drop", [x, y]: [number, number], count = 0): Promise<TabPlacement | null> {
    if (!native) return Promise.resolve(null);
    return native.external(windowId, phase, x, y, count).then((text) => (text ? (JSON.parse(text) as TabPlacement) : null));
  },
  panel(windowId: string, panel: { frame: Frame; members: (Frame & { tabId: string })[] } | null) {
    if (!panel) useNativeDragMarks.setState({ windowId: null, marks: null });
    return native?.panel(windowId, panel ? JSON.stringify(panel) : null);
  },
  panelDrag(windowId: string, phase: "begin" | "move" | "end" | "cancel", tabId: string, x: number, y: number) {
    return native?.panelDrag(windowId, phase, tabId, x, y);
  },
};

type ViewLike = {
  measureInWindow(cb: (x: number, y: number, w: number, h: number) => void): void;
};

export function installNativeDragProbe(
  windowId: string,
  jsPanel: () => {
    items: Map<string, { section: string; view: unknown }>;
    regions: Map<string, unknown>;
  } | null,
) {
  if (!__DEV__ || !native) return;
  void native.startProbe(windowId);
  const read = (): Probe | null => {
    let probe: Probe | null = null;
    try {
      probe = JSON.parse(native.probe(windowId)) as Probe | null;
    } catch {
      probe = null;
    }
    if (!probe) void native.startProbe(windowId);
    return probe;
  };
  const view = (pick: (p: Probe) => Frame | undefined): ViewLike => ({
    measureInWindow(cb) {
      void native.startProbe(windowId).then((text) => {
        const p = JSON.parse(text) as Probe | null;
        const f = p && pick(p);
        cb(f?.x ?? 0, f?.y ?? 0, f?.w ?? 0, f?.h ?? 0);
      });
    },
  });
  const probe = {
    get items() {
      const p = read();
      const out = new Map<string, unknown>();
      for (const i of p?.items ?? []) {
        if (i.kind === "tail" && i.section === "folder") continue;
        out.set(i.key, {
          ...i,
          view: view((q) => q.items.find((x) => x.key === i.key)),
        });
      }
      const panel = jsPanel();
      for (const [key, i] of panel?.items ?? []) if (i.section === "folder") out.set(key, i);
      return out;
    },
    get regions() {
      const p = read();
      const out = new Map<string, unknown>();
      for (const name of Object.keys(p?.regions ?? {}))
        out.set(
          name,
          view((q) => q.regions[name]),
        );
      const folder = jsPanel()?.regions.get("folder");
      if (folder) out.set("folder", folder);
      return out;
    },
    get marks() {
      const p = read();
      return {
        getState: () => ({
          ...(p?.marks ?? {}),
          sources: new Set(p?.marks.sources ?? []),
        }),
      };
    },
    scroll: {
      scrollTo: ({ y }: { y: number }) => void native.scrollTo(windowId, y),
      measureInWindow: view((q) => q.viewport ?? undefined).measureInWindow,
    },
    get scrollY() {
      return read()?.scrollY ?? 0;
    },
    get active() {
      return !!read()?.active;
    },
    get external() {
      return read()?.external ?? 0;
    },
    get gapKey() {
      return read()?.gapKey ?? null;
    },
    get pitch() {
      return read()?.pitch ?? 0;
    },
    get landed() {
      return read()?.landed ?? null;
    },
    set landed(value: unknown) {
      if (value === null) void native.clearLanded(windowId);
    },
  };
  const dev = globalThis as { sidebarDrag?: unknown; sidebarDrags?: Record<string, unknown> };
  dev.sidebarDrag = probe;
  (dev.sidebarDrags ??= {})[windowId] = probe;
  return () => {
    if (dev.sidebarDrags?.[windowId] === probe) delete dev.sidebarDrags[windowId];
    if (dev.sidebarDrag === probe) dev.sidebarDrag = Object.values(dev.sidebarDrags ?? {}).at(-1);
  };
}
