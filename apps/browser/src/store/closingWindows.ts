import { nativeOwnsWorkspace, nativeWrite } from "./nativeStore";

const closing = new Set<string>();

export const isWindowClosing = (windowId: string) => closing.has(windowId);
export const startClosingWindow = (windowId: string) => {
  closing.add(windowId);
  if (nativeOwnsWorkspace()) nativeWrite({ name: "setWindowClosing", args: [windowId, true] });
};
export const stopClosingWindow = (windowId: string) => {
  const was = closing.delete(windowId);
  if (nativeOwnsWorkspace()) nativeWrite({ name: "setWindowClosing", args: [windowId, false] });
  return was;
};
