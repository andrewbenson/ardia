import { inputIdleSeconds } from "@solara/solaracore";
import { killSwitchEnvironment } from "@solara/shell";
import { isQuitting } from "./native";

const STEP_MS = 250;
const BUSY_RETRY_MS = 1000;
const MAX_COLLECTIONS = 8;
const MAX_POSTPONES = 30;
const INPUT_IDLE_SECONDS = 2;
const TIMER_LATE_MS = 50;

type HermesStats = { js_heapSize?: number };
const runtime = globalThis as { gc?: () => void; HermesInternal?: { getInstrumentedStats?: () => HermesStats } };
const heapSize = () => runtime.HermesInternal?.getInstrumentedStats?.().js_heapSize ?? null;

export async function compactMemory(): Promise<void> {
  if (["off", "0", "false"].includes(killSwitchEnvironment("SOLARA_MEMORY_TRIM_HEAP") ?? "")) return;
  if (typeof runtime.gc !== "function" || isQuitting()) return;
  const before = heapSize();
  if (before === null) return;

  return new Promise<void>((resolve, reject) => {
    const later = (fn: (lateMs: number) => void, ms: number) => {
      const due = Date.now() + ms;
      setTimeout(() => fn(Date.now() - due), ms);
    };
    const compact = (step: number, previous: number, postponed: number, lateMs: number) => {
      try {
        if (isQuitting()) return resolve();
        if (!(lateMs < TIMER_LATE_MS && (inputIdleSeconds() ?? Infinity) >= INPUT_IDLE_SECONDS)) {
          if (postponed < MAX_POSTPONES) later((late) => compact(step, previous, postponed + 1, late), BUSY_RETRY_MS);
          else resolve();
          return;
        }
        runtime.gc!();
        const after = heapSize() ?? previous;
        if (after < previous && step + 1 < MAX_COLLECTIONS) later((late) => compact(step + 1, after, postponed, late), STEP_MS);
        else resolve();
      } catch (error) {
        reject(error);
      }
    };
    compact(0, before, 0, 0);
  });
}
