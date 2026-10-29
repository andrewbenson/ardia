import { forwardRef, type ReactNode } from "react";
import type { StyleProp, View, ViewStyle } from "react-native";
import { useWindowId } from "../../store/hooks";
import { TabDropArea, type TabDropTarget } from "../layout/fileDrop";
import { hostedKinds } from "@ardia/settings";
import { useDragController } from "./dnd";
import { nativeSidebarDrag } from "./nativeDrag";

export const SidebarDropArea = forwardRef<View, { style?: StyleProp<ViewStyle>; children?: ReactNode }>(function SidebarDropArea({ style, children }, ref) {
  const controller = useDragController();
  const windowId = useWindowId();
  const target: TabDropTarget = hostedKinds().includes("sidebar")
    ? {
        windowId,
        enter: (count, at) => nativeSidebarDrag.external(windowId, "enter", at, count),
        move: (at) => void nativeSidebarDrag.external(windowId, "move", at),
        leave: () => void nativeSidebarDrag.external(windowId, "leave", [0, 0]),
        drop: (at) => nativeSidebarDrag.external(windowId, "drop", at),
      }
    : {
        windowId,
        enter: (count, [x, y]) => controller?.beginExternal(count, x, y),
        move: ([x, y]) => controller?.move(x, y),
        leave: () => void controller?.finishExternal(false),
        drop: ([x, y]) => {
          controller?.move(x, y);
          return controller?.finishExternal(true) ?? null;
        },
      };
  return (
    <TabDropArea ref={ref} target={target} style={style}>
      {children}
    </TabDropArea>
  );
});
