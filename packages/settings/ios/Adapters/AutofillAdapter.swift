import AppKit
import SolaraCore
import Foundation
import SolaraUI

@MainActor
final class AutofillAdapter: AutofillServices {
  func autofillSettings(profile: String) async -> AutofillEnabled {
    _ = await addresses(profile: profile)
    return AutofillEnabled(
      addresses: SolaraCoreServices.boolPreference("autofill.profile_enabled", profile: profile),
      cards: SolaraCoreServices.boolPreference("autofill.credit_card_enabled", profile: profile)
    )
  }

  func setAutofillSettings(addresses: Bool?, cards: Bool?, profile: String) async {
    if let addresses { SolaraCoreServices.setBoolPreference("autofill.profile_enabled", value: addresses, profile: profile) }
    if let cards { SolaraCoreServices.setBoolPreference("autofill.credit_card_enabled", value: cards, profile: profile) }
  }

  func addresses(profile: String) async -> [SavedAddress] {
    await EngineCalls.result({ done in SolaraCoreServices.addresses(profile: profile) { done($0) } }) {
      EngineCalls.failed($0, "addresses") ? [] : Self.addresses($0.list("addresses"))
    }
  }

  nonisolated static func addresses(_ list: [[String: Any]]) -> [SavedAddress] {
    list.compactMap { entry in
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
    let fields = address.fields
    return await EngineCalls.result({ done in SolaraCoreServices.saveAddress(fields, profile: profile) { done($0) } }) {
      EngineCalls.failed($0, "saveAddress") ? nil : $0.string("id")
    }
  }

  func cards(profile: String) async -> [SavedCard] {
    await EngineCalls.result({ done in SolaraCoreServices.cards(profile: profile) { done($0) } }) {
      EngineCalls.failed($0, "cards") ? [] : Self.cards($0.list("cards"))
    }
  }

  nonisolated static func cards(_ list: [[String: Any]]) -> [SavedCard] {
    list.compactMap { entry in
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
    return await EngineCalls.result({ done in SolaraCoreServices.saveCard(fields, number: number, profile: profile) { done($0) } }) {
      EngineCalls.failed($0, "saveCard") ? nil : $0.string("id")
    }
  }

  func deleteAutofillEntry(_ id: String, profile: String) async {
    await EngineCalls.result({ done in SolaraCoreServices.deleteAutofillEntry(id, profile: profile) { done($0) } }) {
      _ = EngineCalls.failed($0, "deleteAutofillEntry")
    }
  }

  func revealCardNumber(_ id: String, profile: String) async -> String? {
    await EngineCalls.result({ done in SolaraCoreServices.revealCardNumber(id, profile: profile) { done($0) } }) {
      EngineCalls.failed($0, "revealCardNumber") ? nil : $0.string("number")
    }
  }

  func copy(_ text: String) { SettingsAdapters.copyText(text) }
}
