import AppKit
import Foundation
import SolaraUI

@MainActor
final class AutofillAdapter: AutofillServices {
  func autofillSettings(profile: String) async -> AutofillEnabled {
    let result = await SettingsAdapters.js("autofill.settings", profile) as? [String: Any] ?? [:]
    return AutofillEnabled(addresses: result.bool("addresses") ?? true, cards: result.bool("cards") ?? true)
  }

  func setAutofillSettings(addresses: Bool?, cards: Bool?, profile: String) async {
    await SettingsAdapters.js("autofill.setSettings", jsonArg(addresses), jsonArg(cards), profile)
  }

  func addresses(profile: String) async -> [SavedAddress] {
    let list = await SettingsAdapters.js("autofill.addresses", profile) as? [[String: Any]] ?? []
    return list.compactMap { entry in
      guard let id = entry.string("id") else { return nil }
      return SavedAddress(
        id: id,
        name: entry.string("name"),
        organization: entry.string("organization"),
        street: entry.string("street"),
        city: entry.string("city"),
        state: entry.string("state"),
        postalCode: entry.string("postalCode"),
        country: entry.string("country"),
        phone: entry.string("phone"),
        email: entry.string("email")
      )
    }
  }

  func saveAddress(_ address: AddressInput, profile: String) async -> String? {
    await SettingsAdapters.js("autofill.saveAddress", address.fields, profile) as? String
  }

  func cards(profile: String) async -> [SavedCard] {
    let list = await SettingsAdapters.js("autofill.cards", profile) as? [[String: Any]] ?? []
    return list.compactMap { entry in
      guard let id = entry.string("id") else { return nil }
      return SavedCard(
        id: id,
        name: entry.string("name"),
        network: entry.string("network").flatMap(CardNetwork.init(rawValue:)) ?? .card,
        last4: entry.string("last4") ?? "",
        expMonth: entry.int("expMonth"),
        expYear: entry.int("expYear")
      )
    }
  }

  func saveCard(_ card: CardInput, number: String?, profile: String) async -> String? {
    var fields: [String: Any] = ["name": card.name]
    if let id = card.id { fields["id"] = id }
    if let month = card.expMonth { fields["expMonth"] = month }
    if let year = card.expYear { fields["expYear"] = year }
    return await SettingsAdapters.js("autofill.saveCard", fields, jsonArg(number), profile) as? String
  }

  func deleteAutofillEntry(_ id: String, profile: String) async {
    await SettingsAdapters.js("autofill.deleteEntry", id, profile)
  }

  func revealCardNumber(_ id: String, profile: String) async -> String? {
    await SettingsAdapters.js("autofill.revealCardNumber", id, profile) as? String
  }

  func copy(_ text: String) { SettingsAdapters.copyText(text) }
}
