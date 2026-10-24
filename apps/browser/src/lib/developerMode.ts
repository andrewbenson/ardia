export type DeveloperModeState = { sites: readonly string[] };

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]", "::1"]);

export function developerHostOf(url: string): string | null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
  const host = parsed.hostname.toLowerCase();
  return host ? host.replace(/^www\./, "") : null;
}

export function isLocalDeveloperHost(host: string): boolean {
  const h = host.toLowerCase();
  return LOCAL_HOSTS.has(h) || h.endsWith(".localhost");
}

export function isLocalDeveloperUrl(url: string): boolean {
  const host = developerHostOf(url);
  return !!host && isLocalDeveloperHost(host);
}

export function isDeveloperMode(url: string, state: DeveloperModeState): boolean {
  const host = developerHostOf(url);
  return !!host && (isLocalDeveloperHost(host) || state.sites.includes(host));
}

export function canToggleDeveloperMode(url: string): boolean {
  const host = developerHostOf(url);
  return !!host && !isLocalDeveloperHost(host);
}

export function withDeveloperMode(sites: readonly string[], url: string, on: boolean): string[] {
  const host = developerHostOf(url);
  if (!host || isLocalDeveloperHost(host)) return [...sites];
  const rest = sites.filter((h) => h !== host);
  return on ? [...rest, host] : rest;
}
