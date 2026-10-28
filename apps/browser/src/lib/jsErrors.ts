type Handler = (error: unknown, isFatal?: boolean) => void;
type ErrorUtilsType = { getGlobalHandler?: () => Handler | undefined; setGlobalHandler?: (handler: Handler) => void };
type Shell = { readDocument?: (name: string) => string | null; writeDocument?: (name: string, contents: string) => void };
export type JsErrorKind = "fatal" | `fatal storm (${number} in ${number} s)` | "error" | "render";

const JS_ERROR_LOG = "js-errors.log";
const JS_ERROR_LOG_PREVIOUS = "js-errors.1.log";
const MAX_LOG_BYTES = 128 * 1024;
const MAX_STACK_CHARS = 4000;
const MAX_DISTINCT_PER_LAUNCH = 50;
const STORM_FATALS = 20;
const STORM_WINDOW_MS = 10_000;
const STORM_LOG_FLUSH_MS = 250;

const seen = new Set<string>();
let recording = false;
let windowShown = false;
let recentFatals: number[] = [];
let stormHandedOff = false;

const shell = () => (globalThis as { expo?: { modules?: { ArdiaShell?: Shell } } }).expo?.modules?.ArdiaShell;

function describe(error: unknown) {
  if (error instanceof Error) return { message: `${error.name}: ${error.message}`, stack: error.stack ?? "" };
  return { message: String(error), stack: "" };
}

function append(entry: string) {
  const store = shell();
  if (typeof store?.readDocument !== "function" || typeof store.writeDocument !== "function") return;
  let current = store.readDocument(JS_ERROR_LOG) ?? "";
  if (current.length + entry.length > MAX_LOG_BYTES) {
    store.writeDocument(JS_ERROR_LOG_PREVIOUS, current);
    current = "";
  }
  store.writeDocument(JS_ERROR_LOG, current + entry);
}

export function recordJsError(error: unknown, kind: JsErrorKind, area?: string) {
  if (recording) return;
  recording = true;
  try {
    const { message, stack } = describe(error);
    const key = `${kind}\n${area ?? ""}\n${message}\n${stack}`;
    if (seen.has(key) || seen.size >= MAX_DISTINCT_PER_LAUNCH) return;
    seen.add(key);
    const where = area ? ` in ${area}` : "";
    const detail = stack.startsWith(message) ? stack : `${message}\n${stack}`;
    if (!__DEV__) console.error(`[js-error] ${kind}${where}: ${detail}`);
    append(`${new Date().toISOString()} ${kind}${where}\n${detail.slice(0, MAX_STACK_CHARS)}\n\n`);
  } catch {} finally {
    recording = false;
  }
}

export function jsErrorsSurvivable() {
  windowShown = true;
}

function fatalStorm() {
  const now = Date.now();
  recentFatals = recentFatals.filter((at) => now - at < STORM_WINDOW_MS);
  recentFatals.push(now);
  return recentFatals.length > STORM_FATALS;
}

function install() {
  const utils = (globalThis as { ErrorUtils?: ErrorUtilsType }).ErrorUtils;
  const previous = utils?.getGlobalHandler?.();
  utils?.setGlobalHandler?.((error, isFatal) => {
    if (stormHandedOff) return;
    const storm = !!isFatal && fatalStorm();
    recordJsError(error, storm ? `fatal storm (${recentFatals.length} in ${STORM_WINDOW_MS / 1000} s)` : isFatal ? "fatal" : "error");
    if (storm && !__DEV__ && windowShown) {
      stormHandedOff = true;
      setTimeout(() => previous?.(error, isFatal), STORM_LOG_FLUSH_MS);
    } else if (__DEV__ || !isFatal || !windowShown) previous?.(error, isFatal);
  });
}

install();
