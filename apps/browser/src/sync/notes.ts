import { canonical } from "@ardia/sync";
import { isObject } from "./readable";

export function digest(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 0x01000193);
  return (h >>> 0).toString(36);
}

export const choice = (value: unknown) => {
  if (!isObject(value) || !("pos" in value)) return canonical(value);
  const { pos: _derived, ...chosen } = value;
  return canonical(chosen);
};
