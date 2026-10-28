let remote = 0;

export const applyingFromSync = () => remote > 0;

export function asSyncOrigin<T>(apply: () => T): T {
  remote++;
  try {
    return apply();
  } finally {
    remote--;
  }
}

export function asUserChange<T>(apply: () => T): T {
  const held = remote;
  remote = 0;
  try {
    return apply();
  } finally {
    remote = held;
  }
}
