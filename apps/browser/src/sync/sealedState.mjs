import { applyDelta, parseDeltaName } from "./stateDeltas.ts";

const opened = (docs, name) => JSON.parse(docs.get(name).slice(7));

export function sealedState(docs) {
  const full = opened(docs, "sync-state.nns");
  const deltas = [...docs.keys()]
    .map((name) => [name, parseDeltaName(name)])
    .filter(([, delta]) => delta && delta.n === full["~n"] && delta.epoch === full["~epoch"])
    .sort(([, a], [, b]) => a.g - b.g);
  for (const [name] of deltas) applyDelta(full, opened(docs, name));
  return Object.fromEntries(Object.entries(full).filter(([key]) => !key.startsWith("~")));
}

export function sealedJournal(docs) {
  const journal = {};
  const legacy = docs.get("sync-journal.nns");
  const add = (text) => {
    for (const [scope, list] of Object.entries(JSON.parse(text.slice(7)).journal ?? {})) journal[scope] = [...(journal[scope] ?? []), ...list];
  };
  if (legacy) add(legacy);
  for (const [name, text] of docs) if (name.startsWith("sync-journal-b-") && text) add(text);
  return journal;
}
