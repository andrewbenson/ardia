import { requireOptionalNativeModule } from "expo-modules-core";

const native = requireOptionalNativeModule<{ cliIndicatorShown?(): boolean | null }>("SolaraMedia");

export function nativeCliIndicatorShown(): boolean | null {
  try {
    return native?.cliIndicatorShown?.() ?? null;
  } catch {
    return null;
  }
}
