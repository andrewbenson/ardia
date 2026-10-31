const digestOf = ({ o, u, s }) => {
  const text = `${o}\u0000${u}\u0000${s}`;
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 0x01000193) >>> 0;
  return `${text.length}.${h.toString(36)}`;
};

export const sealKey = { value: "chain-1" };

const encode = (parts) => Buffer.from(JSON.stringify(parts)).toString("base64");

export const seal = (o, u, p) => `T${encode([sealKey.value, o, u, p])}`;

export function open(s, o, u) {
  if (typeof s !== "string" || !s.startsWith("T")) return null;
  try {
    const [key, so, su, p] = JSON.parse(Buffer.from(s.slice(1), "base64").toString());
    return key === sealKey.value && so === o && su === u && typeof p === "string" ? p : null;
  } catch {
    return null;
  }
}

export function refusal(reason) {
  const error = new Error(`pw: ${reason}`);
  error.code = "ERR_SEALED_PASSWORDS";
  return error;
}

const loginOrigin = (realm) => {
  const trimmed = realm.replace(/\/$/, "");
  return /^https?:\/\/[^/\s]+$/.test(trimmed) ? trimmed : null;
};

const isPlain = (v) => v && typeof v === "object" && typeof v.o === "string" && typeof v.u === "string" && "p" in v;

function walkFile(file, convert) {
  if (Array.isArray(file?.ops)) for (const op of file.ops) if (op.k?.startsWith("pw:") && op.v) op.v = convert(op.v);
  if (file?.records) for (const [k, r] of Object.entries(file.records)) if (k.startsWith("pw:") && r?.v) r.v = convert(r.v);
  return file;
}

function sealValue(v) {
  if (!isPlain(v)) return v;
  return { o: v.o, u: v.u, s: seal(v.o, v.u, v.p) };
}

function openValue(v) {
  if (isPlain(v)) throw refusal("a plain password where a sealed one belongs");
  if (typeof v?.s !== "string") return v;
  const p = open(v.s, v.o, v.u);
  if (p === null) throw refusal("a sealed password that doesn't open");
  return { o: v.o, u: v.u, p };
}

function plainInside(value) {
  if (typeof value === "string" && value.startsWith("{")) {
    try {
      return plainInside(JSON.parse(value));
    } catch {
      return false;
    }
  }
  if (!value || typeof value !== "object") return false;
  if (isPlain(value)) return true;
  return Object.values(value).some(plainInside);
}

const sealedLogins = (logins) =>
  logins.flatMap((l) => {
    if (typeof l.s === "string") return [l];
    const origin = loginOrigin(l.origin);
    if (!origin) return [];
    const login = { origin, username: l.username, s: seal(origin, l.username, l.password), created: l.created };
    return [l.modified === undefined ? login : { ...login, modified: l.modified }];
  });

export const sealMarked = (read) => async (profile) => {
  const marked = await read(profile);
  return marked ? { ...marked, logins: sealedLogins(marked.logins) } : marked;
};

export const plainOf = (v) => (v && typeof v.s === "string" ? open(v.s, v.o, v.u) : v?.p);

export const sealedCalls = (solaraCEF) => ({
  check: async (values) => values.map((v) => open(v.s, v.o, v.u) !== null),
  save: async (profile, origin, username, s, replacing) => {
    const p = open(s, origin, username);
    if (p === null) return false;
    const cef = solaraCEF();
    const ok = (result) => !!result && !result.error;
    if (replacing && !ok(await cef.deletePassword(profile, origin, username))) return false;
    return ok(await cef.savePassword(profile, origin, username, p));
  },
});

export function withSealedPasswords(native, solaraCEF, mark) {
  if (!native || native.useSealedPasswords) return native;
  let plainRead = native.readPasswords?.bind(native);
  let markedRead = async (profile) => {
    const logins = await plainRead?.(profile);
    return logins ? { logins, mark: mark() } : null;
  };
  const read = native.read.bind(native);
  const write = native.write.bind(native);
  const sealLocal = native.sealLocal.bind(native);
  let latched = false;
  const unwrapped = new WeakMap();
  native.useSealedPasswords = () => {
    latched = true;
  };
  Object.defineProperty(native, "readPasswords", {
    configurable: true,
    enumerable: true,
    get: () => {
      const inner = plainRead;
      const refusing = async (profile) => (latched ? null : inner?.(profile));
      unwrapped.set(refusing, inner);
      return refusing;
    },
    set: (reader) => {
      plainRead = unwrapped.get(reader) ?? reader;
    },
  });
  Object.defineProperty(native, "readPasswordsWithMark", {
    configurable: true,
    enumerable: true,
    get: () => sealMarked(markedRead),
    set: (reader) => {
      markedRead = reader;
    },
  });
  native.read = async (folder, scope, known) => {
    const listing = await read(folder, scope, known);
    if (!latched) return listing;
    return { ...listing, files: listing.files.map((f) => ({ ...f, payload: JSON.stringify(walkFile(JSON.parse(f.payload), sealValue)) })) };
  };
  native.write = async (folder, scope, payload) => (latched ? write(folder, scope, JSON.stringify(walkFile(JSON.parse(payload), openValue))) : write(folder, scope, payload));
  native.sealLocal = async (text, kind) => {
    if (latched && !kind) throw refusal("the local document's kind is needed once passwords are sealed");
    if (latched && plainInside(JSON.parse(text))) throw refusal(`a plain password in the local ${kind}`);
    return sealLocal(text, kind);
  };
  const calls = sealedCalls(solaraCEF);
  native.checkSealed = calls.check;
  native.saveSealedPassword = async (...args) => latched && calls.save(...args);
  native.migrateLedger = async (ledger, scopes, state) => {
    const doc = JSON.parse(ledger);
    if (!latched || doc?.v !== 1) return null;
    const scopeStates = JSON.parse(state);
    for (const [profile, stored] of Object.entries(doc.profiles ?? {})) {
      const entries = Object.entries(stored?.keys ?? {});
      if (!entries.length) continue;
      const logins = await plainRead?.(profile);
      if (!logins) return null;
      const local = new Map(logins.flatMap((l) => (loginOrigin(l.origin) ? [[`pw:${loginOrigin(l.origin)}\n${l.username}`, { o: loginOrigin(l.origin), u: l.username, p: l.password }]] : [])));
      const records = scopeStates[scopes[profile]]?.records ?? {};
      for (const [key, entry] of entries) {
        const first = entry?.d?.[0];
        if (first === undefined) continue;
        const r = records[key]?.v;
        const recorded = r && (typeof r.s === "string" ? { o: r.o, u: r.u, p: open(r.s, r.o, r.u) } : r);
        const match = [local.get(key), recorded].find((c) => c && typeof c.p === "string" && digestOf({ o: c.o, u: c.u, s: c.p }) === first);
        entry.d = [match ? digestOf({ o: match.o, u: match.u, s: seal(match.o, match.u, match.p) }) : "v1:unmatched"];
      }
    }
    return JSON.stringify({ ...doc, v: 2 });
  };
  return native;
}
