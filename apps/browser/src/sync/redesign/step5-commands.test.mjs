import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "./switchOn.mjs";

const { useBrowser } = await import("../../store/browser.ts");
const { Clock } = await import("@solara/sync");
const { openJournal } = await import("../editJournal.ts");
const { journalCommands, pinSources } = await import("../commandJournal.ts");
const { settingsAdapter, profilesAdapter } = await import("../adapters.ts");
const { fromSync } = await import("../../store/pinOrderChoices.ts");
const S = () => useBrowser.getState();

function setup() {
  S().hydrate({});
  const docs = new Map();
  const journal = openJournal({ read: (n) => docs.get(n) ?? null, write: (n, t) => docs.set(n, t) }, { storeG: 0 });
  const links = { default: { syncId: "sync-default" } };
  const adapters = () => [
    { scope: "app", adapter: settingsAdapter, sources: (s) => [s.settings] },
    { scope: "app", adapter: profilesAdapter(() => links), sources: (s) => [s.profiles] },
  ];
  const stop = journalCommands(journal, new Clock("dev1"), adapters, () => undefined);
  return { journal, stop };
}

test("CMD-setting: a setting the user chooses is journaled with its value", fixedBy("step 5"), () => {
  const { journal, stop } = setup();
  try {
    S().updateSettings({ searchEngine: "duckduckgo" });
    assert.deepEqual(journal.entry("app", "set:searchEngine")?.v, { v: "duckduckgo" });
  } finally {
    stop();
  }
});

test("CMD-fromSync: a value sync applies is never journaled", fixedBy("step 5"), () => {
  const { journal, stop } = setup();
  try {
    fromSync(() => S().updateSettings({ searchEngine: "bing" }));
    S().updateSettings({ searchSuggestions: false }, { fromSync: true });
    assert.equal(journal.entries("app").length, 0);
  } finally {
    stop();
  }
});

test("CMD-profile: renaming a linked profile is journaled under its sync id", fixedBy("step 5"), () => {
  const { journal, stop } = setup();
  try {
    S().updateProfile("default", { name: "Renamed Here" });
    assert.equal(journal.entry("app", "prof:sync-default")?.v?.n, "Renamed Here");
  } finally {
    stop();
  }
});

test("CMD-unrelated: a change to state no journaled adapter reads writes nothing", fixedBy("step 5"), () => {
  const { journal, stop } = setup();
  try {
    S().createWindow({ url: "https://example.com/" });
    assert.equal(journal.entries("app").length, 0);
  } finally {
    stop();
  }
});

const { pinnedAreaAdapters } = await import("../pinned.ts");

function pinSetup() {
  S().hydrate({});
  const docs = new Map();
  const journal = openJournal({ read: (n) => docs.get(n) ?? null, write: (n, t) => docs.set(n, t) }, { storeG: 0 });
  const adapters = () =>
    pinnedAreaAdapters("default").map((adapter) => ({
      scope: "p:1",
      adapter,
      sources: pinSources,
      observations: (key) => (key.startsWith("pin:t:") ? ["ti"] : []),
    }));
  const stop = journalCommands(journal, new Clock("dev1"), adapters, () => undefined);
  return { journal, stop };
}

test("CMD-pin: pinning a tab is journaled; its page title changing afterwards isn't", fixedBy("step 5"), () => {
  const { journal, stop } = pinSetup();
  try {
    const w = S().createWindow({ url: "https://home.example/" });
    const tab = S().newTab(w, { url: "https://mail.example/" });
    S().togglePin(tab);
    const pinned = journal.entries("p:1").filter(([k]) => k.startsWith("pin:t:"));
    assert.equal(pinned.length, 1, `the pin is journaled (${journal.entries("p:1").map(([k]) => k)})`);
    const [key, entry] = pinned[0];
    S().navigated(tab, { url: "https://mail.example/", title: "Inbox (3)" }, {});
    assert.equal(journal.entry("p:1", key).h, entry.h, "the title change is an observation, not a command");
  } finally {
    stop();
  }
});
