const { syncRedesign } = await import("../redesignSwitch.ts");
syncRedesign.on = process.env.SYNC_REDESIGN !== "off";

export const fixedBy = (step) => (syncRedesign.on ? {} : { todo: `${step}, with syncRedesign on` });

const shell = await import("../../test-native/index.ts");
const byLoginData = new WeakMap();
const noLoginData = {};
const loginData = () => shell.passwordStores.get(shell.current.device) ?? noLoginData;
const slot = () => {
  const key = loginData();
  let found = byLoginData.get(key);
  if (!found) byLoginData.set(key, (found = { value: null, refuse: false, marks: [] }));
  return found;
};
const loginDataMark = {
  get value() {
    return slot().value;
  },
  set value(v) {
    slot().value = v;
  },
  get refuse() {
    return slot().refuse;
  },
  set refuse(v) {
    slot().refuse = v;
  },
  get marks() {
    return slot().marks;
  },
  set marks(v) {
    slot().marks = v;
  },
};
globalThis.acTestLoginDataMark = loginDataMark;
const withMarkedRead = (value) => {
  const native = value?.ArdiaSync;
  if (native && !native.readPasswordsWithMark)
    native.readPasswordsWithMark = async (profile) => {
      const logins = await native.readPasswords(profile);
      return logins ? { logins, mark: loginDataMark.value } : null;
    };
  return value;
};
let modules = withMarkedRead(globalThis.acTestNativeModules);
Object.defineProperty(globalThis, "acTestNativeModules", {
  configurable: true,
  get: () => modules,
  set: (value) => {
    modules = withMarkedRead(value);
  },
});
let engineCall = globalThis.acTestEngineCall;
Object.defineProperty(globalThis, "acTestEngineCall", {
  configurable: true,
  get: () => (name, profile, args) => {
    if (name !== "ac_passwords_mark") return engineCall?.(name, profile, args);
    if (typeof args?.key !== "string" || !args.key.startsWith("solara_") || !args.value) return { error: "a solara_ key and a value required" };
    if (loginDataMark.refuse) return { error: "couldn't write Login Data's mark" };
    loginDataMark.value = args.value;
    loginDataMark.marks.push(args.value);
    return { ok: true };
  },
  set: (value) => {
    engineCall = value;
  },
});
