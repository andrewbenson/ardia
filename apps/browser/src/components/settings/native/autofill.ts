import {
  deleteCard,
  getAutofillSettings,
  listAddresses,
  listCards,
  revealCardNumber,
  saveAddress,
  saveCard,
  setAutofillSettings,
  type AddressInput,
  type CardInput,
} from "@solara/solaracore";
import type { SettingsHandler } from "@solara/settings";
import { load, resource, store } from "./resources";

export const addresses = resource("addresses", (profile: string) => listAddresses(profile).catch(() => []));
export const cards = resource("cards", (profile: string) => listCards(profile).catch(() => []));
export const autofillEnabled = resource("autofillEnabled", (profile: string) =>
  load(addresses, [profile]).then(() => getAutofillSettings(profile).catch(() => ({ addresses: true, cards: true }))),
);

export const autofillHandlers: Record<string, SettingsHandler> = {
  "autofill.settings": (profile: string) => load(autofillEnabled, [profile], { fresh: true }),
  "autofill.setSettings": async (addressesOn: boolean | null, cardsOn: boolean | null, profile: string) => {
    const patch = { ...(addressesOn === null ? {} : { addresses: addressesOn }), ...(cardsOn === null ? {} : { cards: cardsOn }) };
    await setAutofillSettings(patch, profile);
    const current = await load(autofillEnabled, [profile]).catch(() => null);
    if (current) store(autofillEnabled, [profile], { ...current, ...patch });
  },
  "autofill.addresses": (profile: string) => load(addresses, [profile], { fresh: true }),
  "autofill.saveAddress": (address: AddressInput, profile: string) => saveAddress(profile, address).catch(() => null),
  "autofill.cards": (profile: string) => load(cards, [profile], { fresh: true }),
  "autofill.saveCard": (card: CardInput, number: string | null, profile: string) => saveCard(profile, card, number ?? undefined).catch(() => null),
  "autofill.deleteEntry": (id: string, profile: string) => deleteCard(profile, id).catch(() => {}),
  "autofill.revealCardNumber": (id: string, profile: string) => revealCardNumber(profile, id).catch(() => null),
};
