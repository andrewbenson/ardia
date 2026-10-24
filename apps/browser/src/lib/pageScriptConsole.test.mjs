import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const script = readFileSync(new URL("../../../../packages/ardiacore/ios/page_script.js", import.meta.url), "utf8");
const start = script.indexOf("  const developerConsole = (() => {\n");
const end = script.indexOf("  handlers.config = (config) => {\n", start);
assert.ok(start > 0 && end > start, "page_script.js has the developer console block");
const block = script.slice(start, end);

function page(hostname, { top = true } = {}) {
  const sent = [];
  const listeners = {};
  const timers = [];
  const logged = [];
  class ErrorEvent {
    constructor(isTrusted) {
      this.isTrusted = isTrusted;
    }
  }
  class PromiseRejectionEvent extends ErrorEvent {}
  const console = { error: (...a) => logged.push(["error", ...a]), warn: (...a) => logged.push(["warn", ...a]) };
  const originals = { ...console };
  const window = { ErrorEvent, PromiseRejectionEvent };
  const run = new Function(
    "isTop", "send", "later", "guard", "setPrototypeOf", "keys", "apply", "console", "window", "addEventListener", "location", "handlers",
    `${block}\nreturn developerConsole;`,
  );
  const later = (fn) => () => timers.push(fn);
  const guard = (fn) => (...a) => {
    try {
      return fn(...a);
    } catch {}
  };
  const handlers = {};
  const set = run(
    top,
    (kind, data) => sent.push([kind, { ...data }]),
    later,
    guard,
    Object.setPrototypeOf,
    Object.keys,
    Reflect.apply,
    console,
    window,
    (type, fn) => (listeners[type] = fn),
    { hostname },
    handlers,
  );
  const flush = () => {
    const due = timers.splice(0);
    for (const fn of due) fn();
  };
  return { set, sent, listeners, flush, console, originals, logged, ErrorEvent, PromiseRejectionEvent, handlers };
}

test("a localhost page counts console errors and warnings and uncaught errors from the start", () => {
  const p = page("localhost");
  p.console.error("a");
  p.console.error("b");
  p.console.warn("c");
  p.listeners.error(new p.ErrorEvent(true));
  p.flush();
  assert.deepEqual(p.sent.at(-1), ["console", { errors: 3, warnings: 1 }]);
  assert.deepEqual(p.logged.map((l) => l[0]), ["error", "error", "warn"]);
});

test("an ordinary site isn't wrapped or reported until native turns Developer Mode on", () => {
  const p = page("example.com");
  assert.equal(p.console.error, p.originals.error);
  p.listeners.error(new p.ErrorEvent(true));
  p.console.error("not counted");
  p.flush();
  assert.equal(p.sent.length, 0);
  p.set(true);
  assert.notEqual(p.console.error, p.originals.error);
  p.console.error("counted");
  p.flush();
  assert.deepEqual(p.sent.at(-1), ["console", { errors: 2, warnings: 0 }]);
  p.set(false);
  assert.equal(p.console.error, p.originals.error);
  assert.equal(p.console.warn, p.originals.warn);
});

test("untrusted events don't count, rejections do, and a page's own console replacement is kept on unwrap", () => {
  const p = page("localhost");
  p.listeners.error(new p.ErrorEvent(false));
  p.listeners.error({ isTrusted: true });
  p.listeners.unhandledrejection(new p.PromiseRejectionEvent(true));
  p.flush();
  assert.deepEqual(p.sent.at(-1), ["console", { errors: 1, warnings: 0 }]);
  const own = () => {};
  p.console.error = own;
  p.set(false);
  assert.equal(p.console.error, own);
});

test("subframes have no counter", () => {
  const p = page("localhost", { top: false });
  assert.equal(p.set, null);
  assert.equal(p.console.error, p.originals.error);
});

test("an unchanged count isn't sent twice", () => {
  const p = page("localhost");
  p.flush();
  p.flush();
  assert.equal(p.sent.length, 1);
  p.set(true);
  p.flush();
  assert.equal(p.sent.length, 2);
});
