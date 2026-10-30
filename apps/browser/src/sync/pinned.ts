import { assignPositions, type Adapter, type ApplyRecords, type Extraction } from "@ardia/sync";
import { nativeSnapshot } from "@ardia/store";
import { useBrowser, type BrowserState } from "../store/browser";
import { ancestorIds, depthOf, leaveGroups, orderSections, syncGroupOrder, withParent } from "../store/groups";
import { makeTab, newId, pinnedFirst, without } from "../store/model";
import { groupChoiceKey, noteRemotePinDeletion, orderChoiceKey, placeChoiceKey, type PinSyncEntry } from "../store/organize";
import { adoptParkedPins, parkWindowPins } from "../store/parkedPins";
import { arrangeParked, arrangePinnedArea, parkedAnchors, parkedAreaKeys, pinnedAnchors, pinnedAreaKeys } from "../store/pinnedArea";
import { fromSync } from "../store/pinOrderChoices";
import { pinnedGroupMembers } from "../store/pinHomes";
import { pinKeyOf } from "../store/pinMirror";
import { removeTabs } from "../store/tabs";
import { tileFolderOf, withTileFolder } from "../store/tileFolders";
import type { Tab, TabGroup, TileFolder } from "../store/types";
import { inTodaysNames } from "./adapters";
import { NativeStoreBusy, nativeOwnsWorkspace, nativeWrite, writeState } from "../store/nativeStore";
import { asSyncOrigin } from "../store/syncOrigin";

const store = () => useBrowser.getState();

type SyncPinsKind = "pins" | "rows" | "order" | "looks" | "homes" | "tileFolders";

function frozenPinInputs(visible: Map<string, unknown>, changed: Set<string>, base: (key: string) => unknown, records: ApplyRecords) {
  const ids = new Set<string>();
  const prefixes = ["pin:t:", "pin:g:", "pinn:g:", "pinn:t:", "pinrow:", "pord:g:", "pgc:", "pgh:", "tilefold:"];
  for (const key of [...visible.keys(), ...changed]) {
    const prefix = prefixes.find((prefix) => key.startsWith(prefix));
    if (prefix) ids.add(key.slice(prefix.length));
  }
  for (const value of visible.values()) {
    if (!value || typeof value !== "object") continue;
    for (const key of ["g", "p"]) {
      const id = (value as Record<string, unknown>)[key];
      if (id) ids.add(String(id));
    }
  }
  for (const source of [store(), nativeSnapshot()?.data]) {
    if (!source) continue;
    const state = source as Partial<BrowserState>;
    for (const table of [state.tabs, state.groups]) {
      for (const entity of Object.values(table ?? {})) {
        ids.add(entity.id);
        if (entity.pinKey) ids.add(entity.pinKey);
      }
    }
    for (const park of Object.values(state.parkedPins ?? {})) {
      for (const entity of [...park.tabs, ...park.groups]) ids.add(entity.id);
    }
  }
  const values: Record<string, unknown> = {};
  for (const id of ids) {
    for (const prefix of prefixes) {
      const key = `${prefix}${id}`;
      const value = base(key);
      if (value !== undefined) values[key] = value;
    }
    const folder = syncedFolderId(values[`${TILE_FOLDER}${id}`]);
    if (folder) {
      const nameKey = `${FOLDER_NAME}${folder}`;
      const name = base(nameKey);
      if (name !== undefined) values[nameKey] = name;
    }
  }
  return JSON.parse(JSON.stringify({
    visible: [...visible], changed: [...changed], base: values,
    known: [...ids].map((id) => `pin:g:${id}`).filter((key) => records.known(key)), now: records.now, horizon: records.horizon,
  }));
}

function applyNativePins(profileId: string, kind: SyncPinsKind, visible: Map<string, unknown>, changed: Set<string>, base: (key: string) => unknown, records: ApplyRecords): boolean | Set<string> {
  const inputs = frozenPinInputs(visible, changed, base, records);
  try {
    const response = asSyncOrigin(() => nativeWrite({ name: "syncPinsApply", args: [profileId, { kind, ...inputs }] }));
    if (!response || response.busy || response.error || response.result === false) return false;
    if (Array.isArray(response.result) && response.result.every((key) => typeof key === "string")) return new Set(response.result);
    return response.result === true;
  } catch (error) {
    if (error instanceof NativeStoreBusy) return false;
    throw error;
  }
}

export function pinnedAreaAdapters(profileId: string): Adapter[] {
  return [
    tileFoldersAdapter(profileId),
    pinnedRowsAdapter(profileId),
    pinnedOrderAdapter(profileId),
    groupLooksAdapter(profileId),
    inTodaysNames(pinnedHomesAdapter(profileId)),
    inTodaysNames(pinnedAdapter(profileId)),
  ];
}

type PinValue = { g: string | null; u: string; t: string | null; i: string | null; ti: string; pos: string };
type PinGroupValue = { n: string; i: string | null; c: TabGroup["color"]; pos: string };
type NestGroupValue = { n: string; i: string | null; c: TabGroup["color"]; p: string };
type NestTabValue = { g: string };
const PIN_NEST = "pinn:";
const GROUP_LOOK = "pgc:";
const NO_BOX = "none";

const legacyColor = (color: TabGroup["color"]): TabGroup["color"] => (color === "none" ? null : color);
const lookedColor = (color: TabGroup["color"] | undefined, look: unknown): TabGroup["color"] => ((color ?? null) === null && look === NO_BOX ? "none" : (color ?? null));

type Window = BrowserState["windows"][string];

const hasPage = (t: Tab) => !!t.navigation || !!t.adoptId;

const openWindows = (s: BrowserState) => s.windowOrder.map((id) => s.windows[id]).filter((w): w is Window => !!w && !w.incognito && w.kind !== "small");

function homeWindow(s: BrowserState, profileId: string): Window | undefined {
  const order = [...s.ui.focusOrder, ...s.windowOrder].map((id) => s.windows[id]).filter((w): w is Window => !!w && !w.incognito && w.kind !== "small");
  const shows = (w: Window) => w.tabIds.some((id) => s.tabs[id]?.profileId === profileId);
  return order.find((w) => w.profileId === profileId && shows(w)) ?? order.find(shows) ?? order.find((w) => w.profileId === profileId) ?? order[0];
}

export function pinnedAdapter(profileId: string): Adapter {
  return {
    prefix: "pin",
    extract: (base, queued, now) => {
      const s = store();
      type Pin = Pick<Tab, "id" | "url" | "title" | "customTitle" | "customIcon"> & Partial<Pick<Tab, "pinnedUrl" | "pinnedAsRow">>;
      type Node = { pin: Pin } | { group: string };
      const area: Node[] = [];
      const inside = new Map<string, Node[]>();
      const info = new Map<string, Pick<TabGroup, "name" | "icon" | "color"> & { parent: string | null }>();
      const enter = (chain: (Pick<TabGroup, "name" | "icon" | "color"> & { key: string })[]) =>
        chain.forEach((g, i) => {
          if (info.has(g.key)) return;
          const parent = chain[i - 1]?.key ?? null;
          info.set(g.key, { name: g.name, icon: g.icon, color: g.color, parent });
          inside.set(g.key, []);
          (parent ? inside.get(parent)! : area).push({ group: g.key });
        });
      const pinned = Object.values(s.groups).filter((g) => g.pinned && g.profileId === profileId);
      const pinnedGroupOf = new Map<string, TabGroup>();
      for (const g of pinned.map((g) => [g, depthOf(s.groups, g.id)] as const).sort((a, z) => a[1] - z[1]).map(([g]) => g)) g.tabIds.forEach((id) => pinnedGroupOf.set(id, g));
      const seen = new Set<string>();
      const home = homeWindow(s, profileId);
      for (const w of home ? [home, ...openWindows(s).filter((w) => w.id !== home.id)] : openWindows(s)) {
        for (const id of w.tabIds) {
          const t = s.tabs[id];
          if (!t || t.profileId !== profileId || seen.has(pinKeyOf(t))) continue;
          const g = pinnedGroupOf.get(id);
          if (t.pinned) area.push({ pin: { ...t, id: pinKeyOf(t) } });
          else if (g) {
            const chain = [...ancestorIds(s.groups, g.id).reverse().map((x) => s.groups[x]!).filter((x) => x.pinned), g];
            enter(chain.map((x) => ({ ...x, key: pinKeyOf(x) })));
            inside.get(pinKeyOf(g))!.push({ pin: { ...t, id: pinKeyOf(t) } });
          } else continue;
          seen.add(pinKeyOf(t));
        }
      }
      const park = s.parkedPins[profileId];
      const parkGroups = new Map((park?.groups ?? []).map((g) => [g.id, g]));
      const parkChain = (key: string) => {
        const chain: (Pick<TabGroup, "name" | "icon" | "color"> & { key: string })[] = [];
        for (let g = parkGroups.get(key); g && !chain.some((c) => c.key === g!.id); g = g.parentId ? parkGroups.get(g.parentId) : undefined) chain.unshift({ ...g, key: g.id });
        return chain;
      };
      for (const p of park?.tabs ?? []) {
        if (!p.groupId) area.push({ pin: p });
        else if (parkGroups.has(p.groupId)) (enter(parkChain(p.groupId)), inside.get(p.groupId)!.push({ pin: p }));
      }
      for (const g of park?.groups ?? []) enter(parkChain(g.id));
      const values = new Map<string, unknown>();
      const chosen = s.pinChoices[profileId] ?? {};
      const sync = s.pinSync[profileId] ?? {};
      const baseTab = (key: string) => base(`pin:t:${key}`) as PinValue | undefined;
      const baseGroup = (key: string) => base(`pin:g:${key}`) as PinGroupValue | undefined;
      const pinValue = (t: Pin, group: string | null, pos: string): PinValue => {
        const was = baseTab(t.id);
        const entry = was ? sync[t.id] : undefined;
        const waiting = !group && !!was?.g && entry?.g === was.g && now < (entry.w ?? 0);
        return {
          g: waiting ? was!.g : group,
          u: (group ? t.url : t.pinnedUrl || t.url) || "",
          t: t.customTitle,
          i: t.customIcon,
          ti: t.title,
          pos: waiting ? was!.pos : pos,
        };
      };
      const flat = (key: string): { pin: Pin; inner: string }[] => inside.get(key)!.flatMap((n) => ("pin" in n ? [{ pin: n.pin, inner: key }] : flat(n.group)));
      const nest = (key: string) => {
        for (const n of inside.get(key)!) {
          if (!("group" in n)) continue;
          const g = info.get(n.group)!;
          values.set(`${PIN_NEST}g:${n.group}`, { n: g.name, i: g.icon, c: legacyColor(g.color), p: key } satisfies NestGroupValue);
          nest(n.group);
        }
      };
      const legacyRank = (n: Node) => ("pin" in n ? (n.pin.pinnedAsRow ? 1 : 0) : 2);
      area.sort((a, z) => legacyRank(a) - legacyRank(z));
      const areaPositions = assignPositions(area.map((n) => ("pin" in n ? ((baseTab(n.pin.id)?.g ?? null) === null ? baseTab(n.pin.id)?.pos : undefined) : baseGroup(n.group)?.pos)));
      area.forEach((n, i) => {
        if ("pin" in n) {
          values.set(`pin:t:${n.pin.id}`, pinValue(n.pin, null, areaPositions[i]!));
          return;
        }
        const g = info.get(n.group)!;
        values.set(`pin:g:${n.group}`, { n: g.name, i: g.icon, c: legacyColor(g.color), pos: areaPositions[i]! } satisfies PinGroupValue);
        const members = flat(n.group);
        const positions = assignPositions(members.map(({ pin }) => (baseTab(pin.id)?.g === n.group ? baseTab(pin.id)?.pos : undefined)));
        members.forEach(({ pin, inner }, j) => {
          values.set(`pin:t:${pin.id}`, pinValue(pin, n.group, positions[j]!));
          if (inner !== n.group) values.set(`${PIN_NEST}t:${pin.id}`, { g: inner } satisfies NestTabValue);
        });
        nest(n.group);
      });
      const choiceOf = (k: string) => (k.startsWith("pin:g:") ? groupChoiceKey(k.slice(6)) : placeChoiceKey(k.slice(6)));
      return {
        values,
        ignore: (k) => k.startsWith(PIN_ROW),
        republish: (k) => k.startsWith("pin:") && choiceOf(k) in chosen && !queued(k),
        published: (keys) =>
          settleChoices(profileId, Object.fromEntries([...keys].filter((k) => k.startsWith("pin:")).map(choiceOf).filter((c) => c in chosen).map((c) => [c, chosen[c]!]))),
      } satisfies Extraction;
    },
    apply: (visible, changed, base, records) => {
      if (nativeOwnsWorkspace()) return applyNativePins(profileId, "pins", visible, changed, base, records);
      if ([...changed].every((k) => k.startsWith(PIN_ROW))) return true;
      const pinItem = (k: string) => k.startsWith("pin:t:") || k.startsWith("pin:g:") || k.startsWith(`${PIN_NEST}g:`);
      if ([...changed].some((k) => pinItem(k) && !visible.has(k))) noteRemotePinDeletion(profileId);
      const sync = store().pinSync[profileId] ?? {};
      let s = store();
      const home = homeWindow(s, profileId);
      if (!home) return false;
      const marked = (key: string) => (base(`${PIN_ROW}${key}`) === ROW ? (true as const) : undefined);
      const PARK = `park:${profileId}`;
      const shown = home.tabIds.some((id) => s.tabs[id]?.profileId === profileId);
      if (s.parkedPins[profileId] || !shown) {
        const stand: Window = { id: PARK, profileId, incognito: false, tabIds: [], activeTabIds: {}, sidebarOpen: true, frame: null, createdAt: 0 };
        s = { ...s, windows: { ...s.windows, [PARK]: stand } };
        if (s.parkedPins[profileId]) s = adoptParkedPins(s, PARK, profileId);
      }
      const newPinWindow = shown ? home.id : PARK;
      const scope = new Set([home.id, PARK]);
      const tabOfKey = new Map<string, string>();
      const groupOfKey = new Map<string, string>();
      const pinnedMember = new Set(Object.values(s.groups).filter((g) => g.pinned && g.profileId === profileId).flatMap((g) => g.tabIds));
      const searchOrder = [...scope, ...Object.keys(s.windows).filter((w) => !scope.has(w))];
      const kept = new Map<string, Tab>();
      for (const wid of searchOrder) {
        for (const id of s.windows[wid]?.tabIds ?? []) {
          const t = s.tabs[id];
          if (t?.profileId !== profileId) continue;
          if (t.pinned || pinnedMember.has(id)) {
            if (!tabOfKey.has(pinKeyOf(t))) tabOfKey.set(pinKeyOf(t), id);
          } else if (t.pinKey) {
            const other = kept.get(t.pinKey);
            if (!other || (!hasPage(other) && hasPage(t))) kept.set(t.pinKey, t);
          }
        }
      }
      for (const [key, t] of kept) if (!tabOfKey.has(key)) tabOfKey.set(key, t.id);
      for (const g of Object.values(s.groups)) if (g.pinned && g.profileId === profileId && scope.has(g.windowId) && !groupOfKey.has(pinKeyOf(g))) groupOfKey.set(pinKeyOf(g), g.id);
      const keyOfLocal = new Map<string, string>();
      const local = (ofKey: Map<string, string>, taken: (id: string) => boolean, key: string) => {
        const known = ofKey.get(key);
        if (known) return known;
        const id = taken(key) ? newId("tab") : key;
        ofKey.set(key, id);
        if (id !== key) keyOfLocal.set(id, key);
        return id;
      };
      const tid = (key: string) => local(tabOfKey, (id) => !!s.tabs[id] && s.tabs[id]!.profileId !== profileId, key);
      const gid = (key: string) => local(groupOfKey, (id) => !!s.groups[id] && (s.groups[id]!.profileId !== profileId || !s.groups[id]!.pinned), key);
      const pinKeyField = (id: string) => (keyOfLocal.has(id) ? { pinKey: keyOfLocal.get(id)! } : {});
      const pins = new Map<string, PinValue>();
      const groupValues = new Map<string, PinGroupValue>();
      const nestValues = new Map<string, NestGroupValue>();
      const awaiting = new Map<string, string>();
      const hadGroup = new Set([...Object.values(s.groups).filter((g) => g.profileId === profileId).map(pinKeyOf), ...(s.parkedPins[profileId]?.groups ?? []).map((g) => g.id)]);
      const expired = (k: string, g: string) => sync[k.slice(6)]?.g === g && (sync[k.slice(6)]!.w ?? 0) <= records.now;
      const listed = (g: string) => visible.has(`pin:g:${g}`) || visible.has(`${PIN_NEST}g:${g}`);
      const unresolved = (k: string, g: string) => !listed(g) && !hadGroup.has(g) && !records.known(`pin:g:${g}`) && !expired(k, g);
      const contained = (id: string) => !!s.tabs[id] && (s.tabs[id]!.pinned || pinnedMember.has(id));
      const retainedIn = (id: string, g: string) =>
        !contained(id) && Object.values(s.groups).some((x) => !x.pinned && x.profileId === profileId && pinKeyOf(x) === g && x.tabIds.includes(id));
      for (const [k, v] of visible) {
        if (k.startsWith("pin:t:")) {
          const g = (v as PinValue).g;
          const id = tid(k.slice(6));
          if (g && !listed(g) && retainedIn(id, g)) continue;
          if (g && unresolved(k, g)) awaiting.set(id, g);
          pins.set(id, { ...(v as PinValue), g: g && gid(g) });
        } else if (k.startsWith("pin:g:")) groupValues.set(gid(k.slice(6)), v as PinGroupValue);
        else if (k.startsWith(`${PIN_NEST}g:`)) nestValues.set(gid(k.slice(PIN_NEST.length + 2)), v as NestGroupValue);
      }
      const all = new Set([...groupValues.keys(), ...nestValues.keys()]);
      const keyOf = (id: string) => keyOfLocal.get(id) ?? id;
      const byKey = (a: string, z: string) => (keyOf(a) < keyOf(z) ? -1 : keyOf(a) > keyOf(z) ? 1 : 0);
      const parentGroup = new Map<string, string | null>();
      for (const id of all) {
        const p = nestValues.get(id)?.p;
        const parent = p && listed(p) ? gid(p) : null;
        parentGroup.set(id, parent && parent !== id && all.has(parent) ? parent : null);
      }
      for (const start of [...all].sort(byKey)) {
        const path: string[] = [];
        for (let at: string | null = start; at; at = parentGroup.get(at) ?? null) {
          const loop = path.indexOf(at);
          if (loop >= 0) {
            parentGroup.set(path.slice(loop).sort(byKey)[0]!, null);
            break;
          }
          path.push(at);
        }
      }
      const chainUp = (id: string) => {
        const out: string[] = [];
        for (let g: string | null = id; g && !out.includes(g); g = parentGroup.get(g) ?? null) out.push(g);
        return out;
      };
      const lookOf = (id: string): Pick<PinGroupValue, "n" | "i" | "c"> => (parentGroup.get(id) ? (nestValues.get(id) ?? groupValues.get(id)) : (groupValues.get(id) ?? nestValues.get(id)))!;
      for (const [k, v] of visible) {
        if (!k.startsWith(`${PIN_NEST}t:`)) continue;
        const key = k.slice(PIN_NEST.length + 2);
        const inner = (v as NestTabValue).g;
        if (!visible.has(`pin:t:${key}`) || !listed(inner)) continue;
        const id = tid(key);
        const pin = pins.get(id);
        if (pin?.g && all.has(pin.g) && all.has(gid(inner)) && chainUp(gid(inner)).at(-1) === chainUp(pin.g).at(-1)) pins.set(id, { ...pin, g: gid(inner) });
      }
      for (const [id, v] of pins) if (v.g && !all.has(v.g)) pins.set(id, { ...v, g: null });
      type Slot = { id: string; group: boolean; pos: string };
      const bySlot = (a: Slot, z: Slot) => (a.pos < z.pos ? -1 : a.pos > z.pos ? 1 : a.id < z.id ? -1 : 1);
      const roots = [...all].filter((id) => !parentGroup.get(id));
      const areaSlots = [
        ...[...pins].filter(([, v]) => !v.g).map(([id, v]) => ({ id, group: false, pos: v.pos })),
        ...roots.map((id) => ({ id, group: true, pos: groupValues.get(id)?.pos ?? `\uffff${keyOf(id)}` })),
      ].sort(bySlot);
      const kids = new Map<string, Slot[]>();
      const placedGroups = new Set<string>();
      const members = [...pins].filter(([, v]) => v.g).map(([id, v]) => ({ id, group: false, pos: v.pos, chain: chainUp(v.g!).reverse() }));
      for (const m of members.sort(bySlot)) {
        m.chain.forEach((g, i) => {
          if (i === 0 || placedGroups.has(g)) return;
          placedGroups.add(g);
          kids.set(m.chain[i - 1]!, [...(kids.get(m.chain[i - 1]!) ?? []), { id: g, group: true, pos: "" }]);
        });
        kids.set(m.chain.at(-1)!, [...(kids.get(m.chain.at(-1)!) ?? []), m]);
      }
      const walk = (id: string): Slot[] => (kids.get(id) ?? []).flatMap((x) => (x.group ? [x, ...walk(x.id)] : [x]));
      const tree = areaSlots.flatMap((x) => (x.group ? [x, ...walk(x.id)] : [x]));
      const groupOrder = tree.filter((x) => x.group).map((x) => x.id);
      const tileOrder = areaSlots.filter((x) => !x.group).map((x) => x.id);
      const memberOrder = new Map([...all].map((g) => [g, walk(g).filter((x) => !x.group).map((x) => x.id)]));

      const goneTabs = [...changed].filter((k) => k.startsWith("pin:t:") && !visible.has(k)).map((k) => tid(k.slice(6))).filter((id) => contained(id) && scope.has(s.tabs[id]!.windowId));
      const removable = goneTabs.filter((id) => {
        const t = s.tabs[id]!;
        const w = s.windows[t.windowId];
        const kept = !!t.navigation || !!t.adoptId || Object.values(w?.activeTabIds ?? {}).includes(id);
        return w && !kept && w.tabIds.some((other) => other !== id && !goneTabs.includes(other));
      });
      s = removeTabs(s, removable, false);
      const tabs = { ...s.tabs };
      for (const id of goneTabs) if (tabs[id]) tabs[id] = { ...tabs[id]!, pinned: false, pinnedUrl: null, pinnedAsRow: undefined, tileFolder: undefined, pinKey: undefined };
      let groups = { ...s.groups };
      for (const k of changed) {
        const key = k.startsWith("pin:g:") ? k.slice(6) : k.startsWith(`${PIN_NEST}g:`) ? k.slice(PIN_NEST.length + 2) : null;
        if (key === null || visible.has(k) || all.has(gid(key))) continue;
        if (groups[gid(key)]?.pinned && scope.has(groups[gid(key)]!.windowId)) delete groups[gid(key)];
      }
      const windows = { ...s.windows };

      for (const id of groupOrder) {
        const v = lookOf(id);
        const old = groups[id];
        const color = lookedColor(v.c, base(`${GROUP_LOOK}${old ? pinKeyOf(old) : keyOf(id)}`));
        const made: TabGroup = old
          ? { ...old, name: v.n, icon: v.i, color, pinned: true }
          : { id, ...pinKeyField(id), windowId: newPinWindow, profileId, name: v.n, icon: v.i, color, collapsed: false, pinned: true, tabIds: [], createdAt: Date.now() };
        groups[id] = withParent(made, parentGroup.get(id) ?? undefined);
      }
      const noted = new Map<string, PinSyncEntry>();
      const note = (key: string, id: string) => {
        const g = awaiting.get(id);
        const was = sync[key];
        if ((was?.g ?? undefined) === g) return;
        noted.set(key, g ? { g, w: was?.g === g && was.w !== undefined ? was.w : records.now + records.horizon } : {});
      };
      for (const [id, v] of pins) {
        const group = v.g && all.has(v.g) && groups[v.g] ? groups[v.g]! : null;
        const old = tabs[id];
        if (old) {
          tabs[id] = {
            ...old,
            pinned: !group,
            pinnedUrl: group ? (pinnedMember.has(id) ? old.pinnedUrl || syncedHomeIn(base, pinKeyOf(old)) : syncedHomeIn(base, pinKeyOf(old)) || old.pinnedUrl) || v.u || null : v.u,
            ...(group ? { pinnedAsRow: undefined } : old.pinned ? {} : { pinnedAsRow: marked(pinKeyOf(old)) }),
            ...(group ? { tileFolder: undefined } : old.pinned || marked(pinKeyOf(old)) ? {} : folderMark(base, pinKeyOf(old))),
            customTitle: v.t,
            customIcon: v.i,
            ...(old.unloaded ? { url: v.u, title: v.ti } : {}),
          };
          note(pinKeyOf(tabs[id]!), id);
          continue;
        }
        const windowId = group?.windowId ?? newPinWindow;
        const w = windows[windowId];
        if (!w) continue;
        const tab: Tab = {
          ...makeTab(windowId, profileId, v.u, { title: v.ti, pinned: !group, customTitle: v.t, customIcon: v.i }),
          id,
          ...pinKeyField(id),
          pinnedUrl: (group && syncedHomeIn(base, keyOfLocal.get(id) ?? id)) || v.u || null,
          ...(!group && marked(keyOfLocal.get(id) ?? id) ? { pinnedAsRow: true as const } : {}),
          ...(!group && !marked(keyOfLocal.get(id) ?? id) ? folderMark(base, keyOfLocal.get(id) ?? id) : {}),
          navigation: null,
          unloaded: true,
        };
        note(keyOfLocal.get(id) ?? id, id);
        tabs[id] = tab;
        windows[windowId] = { ...w, tabIds: [...w.tabIds, id] };
      }
      const standalone = new Set(tileOrder.filter((id) => tabs[id]?.pinned));
      groups = {
        ...Object.fromEntries(Object.entries(groups).filter(([, g]) => g.pinned)),
        ...leaveGroups(Object.fromEntries(Object.entries(groups).filter(([, g]) => !g.pinned)), standalone),
      };
      const inGroup = new Set([...memberOrder.values()].flat().filter((id) => tabs[id]));
      for (const g of Object.values(groups)) {
        if (g.profileId !== profileId) continue;
        const wanted = g.pinned && memberOrder.has(g.id) ? memberOrder.get(g.id)!.filter((id) => tabs[id]) : g.tabIds.filter((id) => !inGroup.has(id));
        groups[g.id] = { ...g, tabIds: wanted };
      }
      for (const g of Object.values(groups)) if (g.profileId === profileId && !g.tabIds.length) delete groups[g.id];
      const copied = new Map<string, string>();
      const pinnedHere = Object.values(groups).filter((g) => g.profileId === profileId && g.pinned);
      for (const { id: groupId } of pinnedHere.map((g) => [g, depthOf(groups, g.id)] as const).sort((a, z) => a[1] - z[1]).map(([g]) => g)) {
        const g = groups[groupId]!;
        const parent = g.parentId ? groups[g.parentId] : undefined;
        const real = (w: string) => w !== PARK && !!windows[w];
        const homes = g.tabIds.map((id) => tabs[copied.get(id) ?? id]!).filter((t) => real(t.windowId));
        const windowId = parent ? parent.windowId : !homes.length || homes.some((t) => t.windowId === g.windowId) ? g.windowId : (homes.find(hasPage) ?? homes[0]!).windowId;
        const tabIds: string[] = [];
        for (const id of g.tabIds.map((x) => copied.get(x) ?? x)) {
          const t = tabs[id]!;
          if (t.windowId === windowId) tabIds.push(id);
          else if (t.windowId === PARK && windows[windowId]) {
            windows[PARK] = { ...windows[PARK]!, tabIds: windows[PARK]!.tabIds.filter((x) => x !== id) };
            windows[windowId] = { ...windows[windowId]!, tabIds: [...windows[windowId]!.tabIds, id] };
            tabs[id] = { ...t, windowId };
            tabIds.push(id);
          } else if (windows[windowId]) {
            const copy: Tab = {
              ...makeTab(windowId, profileId, t.url, { title: t.title, favicon: t.favicon, customTitle: t.customTitle, customIcon: t.customIcon }),
              pinKey: pinKeyOf(t),
              pinnedUrl: t.pinnedUrl,
              navigation: null,
              unloaded: true,
            };
            tabs[copy.id] = copy;
            tabs[id] = { ...t, pinKey: undefined };
            windows[windowId] = { ...windows[windowId]!, tabIds: [...windows[windowId]!.tabIds, copy.id] };
            tabIds.push(copy.id);
            copied.set(id, copy.id);
          }
        }
        groups[g.id] = { ...g, windowId, tabIds };
      }

      const sequence = tree.filter((x) => !x.group).map((x) => copied.get(x.id) ?? x.id);
      const rank = new Map(sequence.map((id, i) => [id, i]));
      for (const w of Object.values(windows)) {
        if (w.incognito) continue;
        const ids = w.tabIds.filter((id) => tabs[id]);
        const slots = ids.map((id, i) => (rank.has(id) ? i : -1)).filter((i) => i >= 0);
        const sorted = slots.map((i) => ids[i]!).sort((a, z) => rank.get(a)! - rank.get(z)!);
        slots.forEach((slot, i) => (ids[slot] = sorted[i]!));
        const sectioned = { ...w, tabIds: orderSections(pinnedFirst(ids, tabs, groups), tabs, groups) };
        const window = { ...sectioned, tabIds: arrangePinnedArea({ tabs, groups }, sectioned, profileId, (group) => anchorIn(base(`${PIN_ORDER}${group}`))) };
        windows[w.id] = window;
        groups = syncGroupOrder(groups, window);
      }
      let { live, parkedPins } = s;
      const parkWindow = windows[PARK];
      if (parkWindow) {
        parkedPins = parkWindowPins(parkedPins, parkWindow, { tabs, groups, history: s.history });
        for (const id of parkWindow.tabIds) delete tabs[id];
        live = without(live, parkWindow.tabIds);
        groups = Object.fromEntries(Object.entries(groups).filter(([, g]) => g.windowId !== PARK));
        delete windows[PARK];
      }
      const { find, splits, selection, windowOrder, windowUi } = s;
      const pinSync = noted.size ? { ...s.pinSync, [profileId]: { ...s.pinSync[profileId], ...Object.fromEntries(noted) } } : s.pinSync;
      fromSync(() => writeState(useBrowser, { tabs, windows, groups, live, find, splits, selection, windowOrder, windowUi, parkedPins, pinSync }));
    },
  };
}

const PIN_ORDER = "pord:g:";
type PinOrderValue = { a: string | null };
const anchorIn = (value: unknown) => (value as PinOrderValue | undefined)?.a;

export function pinnedOrderAdapter(profileId: string): Adapter {
  const shownIn = (s: BrowserState) => openWindows(s).filter((w) => w.tabIds.some((id) => s.tabs[id]?.profileId === profileId));
  return {
    prefix: PIN_ORDER,
    extract: (base, queued, _now, _known, remote, stamp) => {
      const s = store();
      const home = homeWindow(s, profileId);
      const shown = !!home && shownIn(s).includes(home);
      const gone = (key: string) => remote(key) === null;
      const ignore = (k: string) => !gone(`pin:g:${k.slice(PIN_ORDER.length)}`);
      if (!shown && !s.parkedPins[profileId]) return { values: new Map(), ignore } satisfies Extraction;
      const anchors = shown ? pinnedAnchors(s, home!, profileId) : parkedAnchors(s, profileId);
      const chosen = s.pinChoices[profileId] ?? {};
      const choiceOf = (k: string) => orderChoiceKey(k.slice(PIN_ORDER.length));
      const rows = new Set((shown ? pinnedAreaKeys(s, home!, profileId) : parkedAreaKeys(s, profileId)).filter((k) => k.startsWith("t:")).map((k) => k.slice(2)));
      const values = new Map<string, unknown>();
      for (const [group, a] of anchors) {
        const was = base(`${PIN_ORDER}${group}`) as PinOrderValue | undefined;
        const since = stamp(`${PIN_ORDER}${group}`);
        const changedSince = (key: string) => since !== undefined && (stamp(key) ?? "") > since;
        const pin = was?.a ? (remote(`pin:t:${was.a}`) as PinValue | null | undefined) : undefined;
        const leftRows = !!was?.a && changedSince(`pin:t:${was.a}`) && (pin === null || (!!pin && pin.g !== null));
        const madeTile = !!was?.a && changedSince(`${PIN_ROW}${was.a}`) && remote(`${PIN_ROW}${was.a}`) !== ROW;
        const settled = leftRows || madeTile;
        const waiting = !(orderChoiceKey(group) in chosen) && !!was?.a && was.a !== a && !rows.has(was.a) && !settled;
        values.set(`${PIN_ORDER}${group}`, waiting ? was! : ({ a } satisfies PinOrderValue));
      }
      return {
        values,
        ignore,
        republish: (k) => choiceOf(k) in chosen && !queued(k),
        published: (published) => settleChoices(profileId, Object.fromEntries([...published].map(choiceOf).filter((c) => c in chosen).map((c) => [c, chosen[c]!]))),
      } satisfies Extraction;
    },
    apply: (visible, changed, base, records) => {
      if (nativeOwnsWorkspace()) return applyNativePins(profileId, "order", visible, changed, base, records);
      const s = store();
      const anchorOf = (group: string) => anchorIn(visible.get(`${PIN_ORDER}${group}`));
      let windows = s.windows;
      let groups = s.groups;
      for (const w of shownIn(s)) {
        const tabIds = arrangePinnedArea(s, w, profileId, anchorOf);
        if (tabIds === w.tabIds) continue;
        const window = { ...w, tabIds };
        windows = { ...windows, [w.id]: window };
        groups = syncGroupOrder(groups, window);
      }
      const park = s.parkedPins[profileId];
      const parked = park && arrangeParked(park, anchorOf);
      if (windows === s.windows && parked === park) return true;
      fromSync(() => writeState(useBrowser, { windows, groups, ...(park && parked !== park ? { parkedPins: { ...s.parkedPins, [profileId]: parked! } } : {}) }));
      return true;
    },
  };
}

const PIN_ROW = "pinrow:";
const ROW = 1;
const TILE = 0;

function settleChoices(profileId: string, published: Record<string, number>) {
  if (nativeOwnsWorkspace()) {
    asSyncOrigin(() => nativeWrite({ name: "settlePinChoices", args: [profileId, JSON.parse(JSON.stringify(published))] }));
    return;
  }
  const now = store().pinChoices;
  const mine = now[profileId];
  if (!mine) return;
  const left = Object.fromEntries(Object.entries(mine).filter(([key, n]) => published[key] !== n));
  if (Object.keys(left).length === Object.keys(mine).length) return;
  const { [profileId]: _, ...others } = now;
  writeState(useBrowser, { pinChoices: Object.keys(left).length ? { ...now, [profileId]: left } : others });
}

export function pinnedRowsAdapter(profileId: string): Adapter {
  const keyOf = (k: string) => k.slice(PIN_ROW.length);
  return {
    prefix: PIN_ROW,
    extract: (base, queued) => {
      const s = store();
      const values = new Map<string, unknown>();
      const known = new Set<string>();
      const chosen = s.pinChoices[profileId] ?? {};
      const home = homeWindow(s, profileId);
      const mark = (key: string, row: boolean | undefined) => {
        if (row) values.set(`${PIN_ROW}${key}`, ROW);
        else if (key in chosen || base(`${PIN_ROW}${key}`) !== undefined) values.set(`${PIN_ROW}${key}`, TILE);
      };
      const windows = home ? [home, ...openWindows(s).filter((w) => w.id !== home.id)] : openWindows(s);
      for (const w of windows) {
        for (const id of w.tabIds) {
          const t = s.tabs[id];
          if (!t?.pinned || t.profileId !== profileId || known.has(pinKeyOf(t))) continue;
          known.add(pinKeyOf(t));
          mark(pinKeyOf(t), t.pinnedAsRow);
        }
      }
      for (const p of s.parkedPins[profileId]?.tabs ?? []) {
        if (p.groupId || known.has(p.id)) continue;
        known.add(p.id);
        mark(p.id, p.pinnedAsRow);
      }
      return {
        values,
        ignore: (k) => !known.has(keyOf(k)) && base(`pin:t:${keyOf(k)}`) === undefined,
        republish: (k) => keyOf(k) in chosen && !queued(k),
        published: (keys) => settleChoices(profileId, Object.fromEntries([...keys].map(keyOf).filter((k) => k in chosen).map((k) => [k, chosen[k]!]))),
      } satisfies Extraction;
    },
    apply: (visible, changed, base, records) => {
      if (nativeOwnsWorkspace()) return applyNativePins(profileId, "rows", visible, changed, base, records);
      const s = store();
      const rows = new Set([...visible].filter(([, v]) => v === ROW).map(([k]) => keyOf(k)));
      const pos = (t: Tab | undefined) => (t ? (base(`pin:t:${pinKeyOf(t)}`) as PinValue | undefined)?.pos : undefined);
      const stillMarked = new Set([...visible.keys()].map(keyOf));
      const touched = new Set([...changed].map(keyOf).filter((key) => stillMarked.has(key)));
      const wants = (key: string, row: boolean | undefined) => touched.has(key) && !!row !== rows.has(key);
      const tabs = { ...s.tabs };
      const windows = { ...s.windows };
      let edited = false;
      for (const w of openWindows(s)) {
        let moved = false;
        for (const id of w.tabIds) {
          const t = tabs[id];
          if (!t?.pinned || t.profileId !== profileId || !wants(pinKeyOf(t), t.pinnedAsRow)) continue;
          tabs[id] = rows.has(pinKeyOf(t)) ? { ...t, pinnedAsRow: true } : { ...t, pinnedAsRow: undefined };
          moved = true;
        }
        if (!moved) continue;
        const ids = [...w.tabIds];
        const slots = ids.map((id, i) => (tabs[id]?.pinned && tabs[id]!.profileId === profileId && pos(tabs[id]) !== undefined ? i : -1)).filter((i) => i >= 0);
        const sorted = slots.map((i) => ids[i]!).sort((a, z) => (pos(tabs[a])! < pos(tabs[z])! ? -1 : pos(tabs[a])! > pos(tabs[z])! ? 1 : 0));
        slots.forEach((slot, i) => (ids[slot] = sorted[i]!));
        const sectioned = { ...w, tabIds: orderSections(pinnedFirst(ids, tabs, s.groups), tabs, s.groups) };
        windows[w.id] = { ...sectioned, tabIds: arrangePinnedArea({ tabs, groups: s.groups }, sectioned, profileId, (group) => anchorIn(base(`${PIN_ORDER}${group}`))) };
        edited = true;
      }
      const park = s.parkedPins[profileId];
      const marked = park?.tabs.map((p) =>
        p.groupId || !wants(p.id, p.pinnedAsRow) ? p : rows.has(p.id) ? { ...p, pinnedAsRow: true as const } : (({ pinnedAsRow: _, ...rest }) => rest)(p),
      );
      const parked = park && marked && arrangeParked({ ...park, tabs: marked }, (group) => anchorIn(base(`${PIN_ORDER}${group}`))).tabs;
      const parkEdited = !!park && parked!.some((p, i) => p !== park.tabs[i]);
      if (!edited && !parkEdited) return true;
      fromSync(() =>
        writeState(useBrowser, {
          tabs,
          windows,
          ...(parkEdited ? { parkedPins: { ...s.parkedPins, [profileId]: { ...park!, tabs: parked! } } } : {}),
        }),
      );
      return true;
    },
  };
}

export function groupLooksAdapter(profileId: string): Adapter {
  const keyOf = (k: string) => k.slice(GROUP_LOOK.length);
  const groupRecords = (key: string) => [`pin:g:${key}`, `${PIN_NEST}g:${key}`];
  return {
    prefix: GROUP_LOOK,
    extract: (_base, _queued, _now, recorded, remote) => {
      const s = store();
      const values = new Map<string, unknown>();
      const known = new Set<string>();
      const offer = (key: string, color: TabGroup["color"]) => {
        if (known.has(key)) return;
        known.add(key);
        if (color === "none") values.set(`${GROUP_LOOK}${key}`, NO_BOX);
      };
      for (const g of Object.values(s.groups)) if (g.pinned && g.profileId === profileId) offer(pinKeyOf(g), g.color);
      for (const g of s.parkedPins[profileId]?.groups ?? []) offer(g.id, g.color);
      const gone = (key: string) => groupRecords(key).some(recorded) && groupRecords(key).every((k) => (remote(k) ?? null) === null);
      return { values, ignore: (k) => !known.has(keyOf(k)) && !gone(keyOf(k)) } satisfies Extraction;
    },
    apply: (visible, changed, base, records) => {
      if (nativeOwnsWorkspace()) return applyNativePins(profileId, "looks", visible, changed, base, records);
      const touched = new Set([...changed].map(keyOf));
      if (!touched.size) return true;
      const wanted = (key: string, color: TabGroup["color"]) => {
        if (!touched.has(key)) return undefined;
        const next = lookedColor(legacyColor(color), visible.get(`${GROUP_LOOK}${key}`));
        return next === color ? undefined : next;
      };
      const s = store();
      let groups: Record<string, TabGroup> | null = null;
      for (const g of Object.values(s.groups)) {
        if (!g.pinned || g.profileId !== profileId) continue;
        const color = wanted(pinKeyOf(g), g.color);
        if (color !== undefined) (groups ??= { ...s.groups })[g.id] = { ...g, color };
      }
      const park = s.parkedPins[profileId];
      const parkedGroups = park?.groups.map((g) => {
        const color = wanted(g.id, g.color);
        return color === undefined ? g : { ...g, color };
      });
      const parkEdited = !!park && parkedGroups!.some((g, i) => g !== park.groups[i]);
      if (!groups && !parkEdited) return true;
      fromSync(() =>
        writeState(useBrowser, {
          ...(groups ? { groups } : {}),
          ...(parkEdited ? { parkedPins: { ...s.parkedPins, [profileId]: { ...park!, groups: parkedGroups! } } } : {}),
        }),
      );
      return true;
    },
  };
}

const PIN_HOME = "pgh:";

const syncedHome = (value: unknown) => (typeof value === "string" && value ? value : undefined);
const syncedHomeIn = (base: (key: string) => unknown, key: string) => syncedHome(base(`${PIN_HOME}${key}`));

function parkedAt<T extends { url: string; pinnedUrl?: string | null; restoreFrom?: string }>(p: T, home: string): T {
  if (p.url === home) return { ...p, pinnedUrl: home };
  const { restoreFrom: _, ...rest } = p;
  return { ...rest, url: home, pinnedUrl: home } as T;
}

export function pinnedHomesAdapter(profileId: string): Adapter {
  const keyOf = (k: string) => k.slice(PIN_HOME.length);
  return {
    prefix: PIN_HOME,
    publishAfterPull: true,
    extract: (base, _queued, _now, recorded, remote) => {
      const s = store();
      const values = new Map<string, unknown>();
      const known = new Set<string>();
      const held = new Set<string>();
      const offer = (key: string, member: boolean, home: string | null | undefined) => {
        if (known.has(key)) return;
        known.add(key);
        if (!member) return;
        const k = `${PIN_HOME}${key}`;
        if (!home) held.add(key);
        else if (base(k) !== undefined || (remote(k) ?? null) === null) values.set(k, home);
      };
      const members = pinnedGroupMembers(s);
      const home = homeWindow(s, profileId);
      for (const w of home ? [home, ...openWindows(s).filter((w) => w.id !== home.id)] : openWindows(s)) {
        for (const id of w.tabIds) {
          const t = s.tabs[id];
          if (t?.profileId === profileId && (t.pinned || members.has(id))) offer(pinKeyOf(t), !t.pinned, t.pinnedUrl);
        }
      }
      for (const p of s.parkedPins[profileId]?.tabs ?? []) offer(p.id, !!p.groupId, p.pinnedUrl || p.url);
      const unpinned = (key: string) => recorded(`pin:t:${key}`) && remote(`pin:t:${key}`) === null;
      return {
        values,
        ignore: (k) => held.has(keyOf(k)) || (!known.has(keyOf(k)) && base(`pin:t:${keyOf(k)}`) === undefined && !unpinned(keyOf(k))),
      } satisfies Extraction;
    },
    apply: (visible, changed, base, records) => {
      if (nativeOwnsWorkspace()) return applyNativePins(profileId, "homes", visible, changed, base, records);
      const incoming = new Map<string, string>();
      for (const k of changed) {
        const home = syncedHome(visible.get(k));
        if (home) incoming.set(keyOf(k), home);
      }
      if (!incoming.size) return true;
      const keptHere = new Set<string>();
      const wanted = (key: string, current: string | null | undefined) => {
        const home = incoming.get(key);
        if (!home || home === current) return undefined;
        const synced = syncedHomeIn(base, key);
        if (!current || synced === undefined || synced === current) return home;
        keptHere.add(`${PIN_HOME}${key}`);
        return undefined;
      };
      const s = store();
      let tabs: Record<string, Tab> | null = null;
      for (const id of pinnedGroupMembers(s)) {
        const t = s.tabs[id];
        if (!t || t.profileId !== profileId || t.pinned) continue;
        const home = wanted(pinKeyOf(t), t.pinnedUrl);
        if (home) (tabs ??= { ...s.tabs })[id] = { ...t, pinnedUrl: home };
      }
      const park = s.parkedPins[profileId];
      const parked = park?.tabs.map((p) => {
        const home = p.groupId ? wanted(p.id, p.pinnedUrl || p.url) : undefined;
        return home ? parkedAt(p, home) : p;
      });
      const parkEdited = !!park && parked!.some((p, i) => p !== park.tabs[i]);
      if (tabs || parkEdited)
        fromSync(() =>
          writeState(useBrowser, {
            ...(tabs ? { tabs } : {}),
            ...(parkEdited ? { parkedPins: { ...s.parkedPins, [profileId]: { ...park!, tabs: parked! } } } : {}),
          }),
        );
      return new Set([...changed].filter((k) => !keptHere.has(k)));
    },
  };
}

const TILE_FOLDER = "tilefold:";
const FOLDER_NAME = `${TILE_FOLDER}n:`;
type TileFolderValue = { f: string };
type FolderNameValue = { n: string };

const syncedFolderId = (value: unknown) => {
  const v = value as TileFolderValue | undefined;
  return v && typeof v.f === "string" ? v.f : undefined;
};
const syncedName = (value: unknown) => {
  const v = value as FolderNameValue | undefined;
  return v && typeof v.n === "string" ? v.n : undefined;
};
const folderMark = (base: (key: string) => unknown, key: string) => {
  const id = syncedFolderId(base(`${TILE_FOLDER}${key}`));
  return id ? { tileFolder: { id, name: syncedName(base(`${FOLDER_NAME}${id}`)) ?? "" } } : {};
};
const localFolders = new Map<string, Set<string>>();

export function tileFoldersAdapter(profileId: string): Adapter {
  const keyOf = (k: string) => k.slice(TILE_FOLDER.length);
  return {
    prefix: TILE_FOLDER,
    extract: (base, _queued, _now, recorded, remote) => {
      const s = store();
      const values = new Map<string, unknown>();
      const known = new Set<string>();
      const local = new Map<string, TileFolder>();
      const mark = (key: string, folder: TileFolder | undefined) => {
        known.add(key);
        if (!folder) return;
        values.set(`${TILE_FOLDER}${key}`, { f: folder.id } satisfies TileFolderValue);
        const was = local.get(folder.id);
        if (!was || (folder.renamedAt ?? -1) > (was.renamedAt ?? -1)) local.set(folder.id, folder);
      };
      const unpinned = (key: string) => recorded(`pin:t:${key}`) && remote(`pin:t:${key}`) === null;
      const home = homeWindow(s, profileId);
      for (const w of home ? [home, ...openWindows(s).filter((w) => w.id !== home.id)] : openWindows(s)) {
        for (const id of w.tabIds) {
          const t = s.tabs[id];
          if (t?.pinned && t.profileId === profileId && !known.has(pinKeyOf(t))) mark(pinKeyOf(t), tileFolderOf(t));
        }
      }
      for (const p of s.parkedPins[profileId]?.tabs ?? []) if (!p.groupId && !known.has(p.id)) mark(p.id, p.pinnedAsRow ? undefined : p.tileFolder);
      for (const [folderId, folder] of local) {
        const synced = base(`${FOLDER_NAME}${folderId}`);
        if (folder.renamedAt !== undefined && syncedName(synced) !== folder.name) values.set(`${FOLDER_NAME}${folderId}`, { n: folder.name } satisfies FolderNameValue);
        else if (synced !== undefined) values.set(`${FOLDER_NAME}${folderId}`, synced);
      }
      const had = localFolders.get(profileId) ?? new Set();
      localFolders.set(profileId, new Set(local.keys()));
      const ignore = (k: string) => {
        if (k.startsWith(FOLDER_NAME)) return !had.has(k.slice(FOLDER_NAME.length));
        return !known.has(keyOf(k)) && base(`pin:t:${keyOf(k)}`) === undefined && !unpinned(keyOf(k));
      };
      return { values, ignore } satisfies Extraction;
    },
    apply: (visible, changed, base, records) => {
      if (nativeOwnsWorkspace()) return applyNativePins(profileId, "tileFolders", visible, changed, base, records);
      const s = store();
      const touched = new Set([...changed].filter((k) => !k.startsWith(FOLDER_NAME)).map(keyOf));
      const names = new Map<string, string>();
      for (const [k, v] of visible) {
        const name = k.startsWith(FOLDER_NAME) ? syncedName(v) : undefined;
        if (name !== undefined) names.set(k.slice(FOLDER_NAME.length), name);
      }
      const wanted = (key: string, current: TileFolder | undefined): TileFolder | undefined => {
        const id = touched.has(key) ? syncedFolderId(visible.get(`${TILE_FOLDER}${key}`)) : current?.id;
        if (!id) return undefined;
        const name = names.get(id);
        if (current?.id === id && (name === undefined || name === current.name)) return current;
        return { id, name: name ?? (current?.id === id ? current.name : "") };
      };
      let tabs: Record<string, Tab> | null = null;
      for (const w of openWindows(s)) {
        for (const id of w.tabIds) {
          const t = s.tabs[id];
          if (!t?.pinned || t.pinnedAsRow || t.profileId !== profileId) continue;
          const folder = wanted(pinKeyOf(t), t.tileFolder);
          if (folder !== t.tileFolder) (tabs ??= { ...s.tabs })[id] = withTileFolder(t, folder);
        }
      }
      const park = s.parkedPins[profileId];
      const parked = park?.tabs.map((p) => {
        if (p.groupId || p.pinnedAsRow) return p;
        const folder = wanted(p.id, p.tileFolder);
        if (folder === p.tileFolder) return p;
        const { tileFolder: _, ...rest } = p;
        return folder ? { ...rest, tileFolder: folder } : rest;
      });
      const parkEdited = !!park && parked!.some((p, i) => p !== park.tabs[i]);
      if (!tabs && !parkEdited) return true;
      fromSync(() =>
        writeState(useBrowser, {
          ...(tabs ? { tabs } : {}),
          ...(parkEdited ? { parkedPins: { ...s.parkedPins, [profileId]: { ...park!, tabs: parked! } } } : {}),
        }),
      );
      return true;
    },
  };
}
