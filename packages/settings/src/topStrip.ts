import { requireOptionalNativeModule } from "expo-modules-core";

type TopStripModule = {
  incoming(windowId: string, x: number | null, y: number | null): Promise<string>;
  endIncoming(windowId: string): Promise<void>;
};

const native = requireOptionalNativeModule<TopStripModule>("SolaraTopStrip");

export async function topStripIncoming(windowId: string, point: [number, number] | null): Promise<string | null | undefined> {
  if (!native?.incoming) return undefined;
  const found = JSON.parse(await native.incoming(windowId, point?.[0] ?? null, point?.[1] ?? null)) as { beforeId: string | null } | null;
  return found ? found.beforeId : undefined;
}

export function endTopStripIncoming(windowId: string) {
  return native?.endIncoming?.(windowId) ?? Promise.resolve();
}
