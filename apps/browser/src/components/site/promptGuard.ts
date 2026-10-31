import { onWindowEvent } from "@solara/shell";
import { useCallback, useLayoutEffect, useRef } from "react";
import { AppState } from "react-native";
import { POPOVER_MOTION } from "../layout/controls";

export const PROMPT_INPUT_DELAY_MS = 500;

let activatedAt = 0;
let watching = false;

const markActivation = () => {
  activatedAt = Date.now();
};

function watchWindowActivation() {
  if (watching) return;
  watching = true;
  onWindowEvent((e) => e.type === "focus" && markActivation());
  AppState.addEventListener("change", (state) => state === "active" && markActivation());
}

export function usePromptInputGuard(promptKey: string | number | null | undefined) {
  const visibleAt = useRef(Number.POSITIVE_INFINITY);
  const lastInputAt = useRef(0);
  useLayoutEffect(() => {
    watchWindowActivation();
    visibleAt.current = promptKey == null ? Number.POSITIVE_INFINITY : Date.now() + POPOVER_MOTION.open.duration;
  }, [promptKey]);
  return useCallback(
    <A extends unknown[]>(action: (...args: A) => void) =>
      (...args: A) => {
        const now = Date.now();
        const previousInputAt = lastInputAt.current;
        lastInputAt.current = now;
        const settledAt = Math.max(visibleAt.current, activatedAt) + PROMPT_INPUT_DELAY_MS;
        if (now < settledAt || now - previousInputAt < PROMPT_INPUT_DELAY_MS) return;
        action(...args);
      },
    [],
  );
}
