import {
  deletePassword,
  exportPasswords,
  getNeverSavePasswordOrigins,
  getPassword,
  listPasswords,
  savePassword,
  setNeverSavePasswords,
  setPasswordAutofill,
  unlockPasswords,
  updatePassword,
} from "@ardia/ardiacore";
import { publishSettingsTopic, type SettingsHandler } from "@ardia/settings";
import { importModule } from "../../import/module";
import { passwordAutofill } from "../paneData";
import { load, store } from "../resources";

const listedPassword = ({ origin, username }: { origin: string; username: string }) => ({ origin, username });

export const passwordsHandlers: Record<string, SettingsHandler> = {
  "passwords.autofill": (profile: string) => load(passwordAutofill, [profile], { fresh: true }),
  "passwords.setAutofill": (on: boolean, profile: string) => setPasswordAutofill(on, profile).then(() => store(passwordAutofill, [profile], on)),
  "passwords.unlock": (profile: string) => unlockPasswords(profile).catch(() => false),
  "passwords.list": (profile: string) => listPasswords(profile).then((list) => list.map(listedPassword), () => []),
  "passwords.neverSaveOrigins": (profile: string) => getNeverSavePasswordOrigins(profile).catch(() => null),
  "passwords.password": (profile: string, origin: string, username: string) => getPassword(profile, origin, username).catch(() => null),
  "passwords.save": (profile: string, origin: string, username: string, password: string) =>
    savePassword(profile, origin, username, password).catch(() => false),
  "passwords.update": (profile: string, origin: string, username: string, newUsername: string | null, newPassword: string | null) =>
    updatePassword(profile, origin, username, { username: newUsername ?? undefined, password: newPassword ?? undefined }).catch(() => false),
  "passwords.delete": (profile: string, origin: string, username: string) => deletePassword(profile, origin, username).catch(() => false),
  "passwords.allowSaving": (profile: string, origin: string) => setNeverSavePasswords(profile, origin, false).catch(() => {}),
  "passwords.export": (profile: string) => exportPasswords(profile).catch(() => ({ status: "writeFailed" as const })),
  "passwords.chooseCSV": () => importModule()?.chooseImportFile("passwordsCSV") ?? null,
  "passwords.importCSV": async (path: string) => {
    const mod = importModule();
    if (!mod) throw new Error("Importing isn't available in this build.");
    return mod.importPasswordsCSV(path);
  },
};

export function publishPasswords(): void {
  publishSettingsTopic("passwords.importAvailable", importModule() !== null);
}
