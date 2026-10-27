import { useEffect, useRef } from "react";
import { useNativeToolbarModel } from "../NativeToolbar";
import type { ToolbarGeometry } from "./geometry";
import { dropSplitToolbar, feedSplitToolbar, type SplitToolbarHandlers } from "./nativeSplitChrome";

const noHandle = () => null;

export function SplitToolbarFeed({ tabId, windowId, geometry, focused }: { tabId: string; windowId: string; geometry: ToolbarGeometry; focused: boolean }) {
  const { json, onClick, onAnchors } = useNativeToolbarModel({ tabId, geometry, windowId, inSplit: true, focused }, noHandle);
  const handlers = useRef<SplitToolbarHandlers>({ onClick, onAnchors });
  handlers.current = { onClick, onAnchors };
  useEffect(() => feedSplitToolbar(windowId, tabId, json, handlers), [windowId, tabId, json]);
  useEffect(() => () => dropSplitToolbar(windowId, tabId), [windowId, tabId]);
  return null;
}
