import { publishSettingsTopic, type SettingsHandler } from "@solara/settings";
import { importModule } from "../../import/module";

export const passwordsHandlers: Record<string, SettingsHandler> = {
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
