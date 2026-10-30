import { onHostedEvent, SolaraHostedView } from "@ardia/settings";
import { useEffect, useState } from "react";
import { StyleSheet } from "react-native";
import { useTheme } from "../../../lib/theme";
import { useWindowId } from "../../../store/hooks";
import type { Rect } from "../../layout/geometry";
import { pageThemeState } from "../../pages/nativePageTheme";
import { locateAnchor } from "./anchors";
import { endToolTour, openVideoTour, stepToolTour, useTour, videoTourUrl } from "./state";

export function ToolTour() {
  const windowId = useWindowId();
  const theme = useTheme();
  const active = useTour((s) => s.windowId === windowId && s.stops.length > 0);
  const session = useTour((s) => s.session);
  const stops = useTour((s) => s.stops);
  const index = useTour((s) => s.index);
  const stop = active ? stops[Math.min(index, stops.length - 1)] : undefined;
  const [target, setTarget] = useState<Rect | null>(null);

  useEffect(() => {
    if (!stop?.anchor) return setTarget(null);
    let cancelled = false;
    const update = () =>
      void locateAnchor(windowId, stop.anchor!).then((rect) => {
        if (!cancelled) setTarget((prev) => (sameRect(prev, rect) ? prev : rect));
      });
    update();
    const timer = setInterval(update, 400);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [stop?.id, windowId]);

  useEffect(
    () =>
      onHostedEvent("toolTour", windowId, (name) => {
        if (name === "next") stepToolTour(1);
        else if (name === "back") stepToolTour(-1);
        else if (name === "skip") endToolTour();
        else if (name === "video") {
          endToolTour();
          openVideoTour(windowId);
        }
      }),
    [windowId],
  );

  if (!active) return null;
  const state = JSON.stringify({
    session,
    active,
    index,
    stops: stops.map((s) => ({ id: s.id, title: s.title, body: s.body, anchored: !!s.anchor, placement: s.placement, radius: s.radius, pad: s.pad })),
    target: stop?.anchor ? target : null,
    video: !!videoTourUrl(),
    ...pageThemeState(theme),
  });
  return <SolaraHostedView key={session} kind="toolTour" windowId={windowId} state={state} style={StyleSheet.absoluteFill} />;
}

const sameRect = (a: Rect | null, b: Rect | null) =>
  a === b || (!!a && !!b && Math.abs(a.x - b.x) < 0.5 && Math.abs(a.y - b.y) < 0.5 && Math.abs(a.width - b.width) < 0.5 && Math.abs(a.height - b.height) < 0.5);
