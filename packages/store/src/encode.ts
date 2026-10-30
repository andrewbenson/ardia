export const PATCH_COMMANDS: ReadonlySet<string> = new Set(["updateTab", "navigated", "updateProfile", "updateGroup", "setFind"]);

const plain = (value: unknown): unknown => (value === undefined ? null : JSON.parse(JSON.stringify(value)));

export function encodeArgs(name: string, args: readonly unknown[]): unknown[] {
  const patches = PATCH_COMMANDS.has(name);
  return args.map((arg) => {
    if (!arg || typeof arg !== "object" || Array.isArray(arg) || !patches) return plain(arg);
    const record = arg as Record<string, unknown>;
    const unset = Object.keys(record).filter((k) => record[k] === undefined);
    const value = plain(record) as Record<string, unknown>;
    return unset.length ? { ...value, $unset: unset } : value;
  });
}

export function encodeCommand(name: string, args: readonly unknown[]): { name: string; args: unknown[] } {
  return { name, args: encodeArgs(name, args) };
}
