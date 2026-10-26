import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
final class FakeAutofillServices: AutofillServices {
  var settings: [String: AutofillEnabled] = ["default": AutofillEnabled(addresses: true, cards: false)]
  var settingsWrites: [(addresses: Bool?, cards: Bool?, profile: String)] = []
  var addressList: [String: [SavedAddress]] = [
    "default": [
      SavedAddress(id: "a1", name: "Andrew Benson", organization: "Hill", street: "1 Infinite Loop\nSuite 200", city: "Cupertino", state: "CA", postalCode: "95014", country: "US", phone: "+1 408 555 0100", email: "andrew@example.com"),
      SavedAddress(id: "a2", street: "500 Market St", city: "San Francisco", state: "CA", postalCode: "94105"),
      SavedAddress(id: "a3", email: "orders@example.com"),
    ],
  ]
  var cardList: [String: [SavedCard]] = [
    "default": [
      SavedCard(id: "c1", name: "Andrew Benson", network: .visa, last4: "4242", expMonth: 4, expYear: 2029),
      SavedCard(id: "c2", name: "Andrew Benson", network: .mastercard, last4: "4444", expMonth: 1, expYear: 2025),
      SavedCard(id: "c3", network: .amex, last4: "0005", expMonth: 12, expYear: 2030),
      SavedCard(id: "c4", name: "Store Card", network: .card, last4: "1111"),
    ],
  ]
  var savedAddresses: [AddressInput] = []
  var savedCards: [(card: CardInput, number: String?)] = []
  var cardSaveAnswer: String? = "c9"
  var deleted: [String] = []
  var revealCalls: [String] = []
  var copied: [String] = []

  func autofillSettings(profile: String) async -> AutofillEnabled { settings[profile] ?? AutofillEnabled(addresses: true, cards: true) }
  func setAutofillSettings(addresses: Bool?, cards: Bool?, profile: String) async {
    settingsWrites.append((addresses, cards, profile))
  }
  func addresses(profile: String) async -> [SavedAddress] { addressList[profile] ?? [] }
  func saveAddress(_ address: AddressInput, profile: String) async -> String? {
    savedAddresses.append(address)
    return address.id ?? "new"
  }
  func cards(profile: String) async -> [SavedCard] { cardList[profile] ?? [] }
  func saveCard(_ card: CardInput, number: String?, profile: String) async -> String? {
    savedCards.append((card, number))
    return cardSaveAnswer
  }
  func deleteAutofillEntry(_ id: String, profile: String) async { deleted.append(id) }
  func revealCardNumber(_ id: String, profile: String) async -> String? {
    revealCalls.append(id)
    return "4242424242424242"
  }
  func copy(_ text: String) { copied.append(text) }
}

@MainActor
struct AutofillPaneTests {
  static let june2026 = Date(timeIntervalSince1970: 1_781_000_000)

  static func fixture() -> (AutofillPaneModel, FakeAutofillServices, SettingsContext) {
    let (context, store) = SettingsFixture.context()
    store.values["defaultProfileId"] = .string("default")
    let services = FakeAutofillServices()
    let model = AutofillPaneModel(services: services, store: store, now: { june2026 })
    context.panes[.autofill] = model
    return (model, services, context)
  }

  @Test func prepareLoadsAddressesCardsAndToggles() async {
    let (model, _, _) = Self.fixture()
    let place = SettingsPlace(pane: .autofill)
    #expect(!model.isLoaded(place))
    await model.prepare(place)
    #expect(model.isLoaded(place))
    #expect(model.addresses["default"]?.count == 3)
    #expect(model.cards["default"]?.count == 4)
    #expect(model.enabled["default"] == AutofillEnabled(addresses: true, cards: false))
    #expect(!model.isLoaded(SettingsPlace(pane: .autofill, profileId: "work")))
  }

  @Test func togglesWriteOneSettingAndUpdateTheCacheOnlyWhenLoaded() async {
    let (model, services, _) = Self.fixture()
    await model.setEnabled(cards: true, profile: "default")
    #expect(model.enabled["default"] == nil)
    await model.load("default")
    await model.setEnabled(cards: true, profile: "default")
    await model.setEnabled(addresses: false, profile: "default")
    #expect(model.enabled["default"] == AutofillEnabled(addresses: false, cards: true))
    #expect(services.settingsWrites.map(\.addresses) == [nil, nil, false])
    #expect(services.settingsWrites.map(\.cards) == [true, true, nil])
  }

  @Test func addressTitlesAndSummaries() {
    let full = SavedAddress(id: "1", name: "Andrew", street: "1 Main St\nApt 4", city: "Austin", state: "TX", postalCode: "78701", email: "a@example.com")
    #expect(AutofillText.addressTitle(full) == "Andrew")
    #expect(AutofillText.addressSummary(full) == "1 Main St, Austin TX 78701, a@example.com")
    let streetOnly = SavedAddress(id: "2", street: "9 Elm\nUnit 2", city: "Austin")
    #expect(AutofillText.addressTitle(streetOnly) == "9 Elm")
    #expect(AutofillText.addressSummary(streetOnly) == "Austin")
    let emailOnly = SavedAddress(id: "3", email: "e@example.com")
    #expect(AutofillText.addressTitle(emailOnly) == "e@example.com")
    #expect(AutofillText.addressTitle(SavedAddress(id: "4")) == "Address")
  }

  @Test func addressSheetSplitsAndJoinsStreetLines() {
    let saved = SavedAddress(id: "x", name: "N", street: "1 Main St\nFloor 2\nRoom 3")
    var values = AutofillAddressField.values(for: saved)
    #expect(values[.line1] == "1 Main St")
    #expect(values[.line2] == "Floor 2, Room 3")
    values[.line1] = "  2 Main St "
    values[.line2] = "   "
    values[.city] = " Austin "
    let input = AutofillAddressField.input(values, id: "x")
    #expect(input.street == "2 Main St")
    #expect(input.city == " Austin ")
    #expect(input.id == "x")
    #expect(input.fields["id"] == "x")
    #expect(AutofillAddressField.input(values, id: nil).fields["id"] == nil)
    #expect(AutofillAddressField.isEmpty(AutofillAddressField.values(for: nil)))
    #expect(!AutofillAddressField.isEmpty(values))
  }

  @Test func cardSummariesUseTheClock() {
    let now = Self.june2026
    #expect(AutofillText.cardSummary(SavedCard(id: "1", name: "A", network: .visa, last4: "1", expMonth: 4, expYear: 2029), now: now) == "Expires 04/29 · A")
    #expect(AutofillText.cardSummary(SavedCard(id: "2", network: .visa, last4: "1", expMonth: 5, expYear: 2026), now: now) == "Expired 05/26")
    #expect(AutofillText.cardSummary(SavedCard(id: "3", network: .visa, last4: "1", expMonth: 6, expYear: 2026), now: now) == "Expires 06/26")
    #expect(AutofillText.cardSummary(SavedCard(id: "4", name: "Only", network: .visa, last4: "1", expMonth: 6), now: now) == "Only")
    #expect(SavedCard(id: "5", network: .amex, last4: "0005").title == "American Express •••• 0005")
  }

  @Test func cardNumberFormatting() {
    #expect(AutofillText.formatCardNumber("4242424242424242") == "4242 4242 4242 4242")
    #expect(AutofillText.formatCardNumber("378282246310005") == "3782 822463 10005")
    #expect(AutofillText.formatCardNumber("4242424242424242123") == "4242 4242 4242 4242 123")
    #expect(AutofillText.formatCardNumber("42424") == "4242 4")
    #expect(AutofillText.formatCardNumber("") == "")
    #expect(AutofillText.formatCardNumber("3782822463100051234") == "3782 822463 10005 1234")
    #expect(AutofillText.digits("4242-4242 ab٣") == "42424242")
  }

  @Test func expirationOptions() {
    #expect(AutofillText.monthOptions.count == 13)
    #expect(AutofillText.monthOptions[1] == SettingOption("1", "01"))
    let years = AutofillText.yearOptions(current: 2020, now: Self.june2026)
    #expect(years.first == SettingOption("", "Year"))
    #expect(years[1].value == "2020")
    #expect(years[2].value == "2026")
    #expect(years.last?.value == "2041")
    #expect(AutofillText.yearOptions(current: 2030, now: Self.june2026).count == 17)
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersAutofill() async throws {
    let directory = try #require(Snapshot.directory)
    let (model, services, context) = Self.fixture()
    let place = SettingsPlace(pane: .autofill)
    await model.prepare(place)
    try await Snapshot.renderPanes(context, [.autofill])
    try await Snapshot.renderPanes(context, [], places: [SettingsPlace(pane: .autofill, profileId: "work")], named: { _ in "autofill-empty" })
    let address = services.addressList["default"]![0]
    let card = services.cardList["default"]![0]
    for dark in [false, true] {
      let scheme = dark ? "dark" : "light"
      let sheets: [(String, AnyView, CGFloat)] = [
        ("address-new", AnyView(AutofillAddressSheet(model: model, profile: "default", saved: nil)), 560),
        ("address-edit", AnyView(AutofillAddressSheet(model: model, profile: "default", saved: address)), 560),
        ("card-new", AnyView(AutofillCardSheet(model: model, profile: "default", saved: nil)), 260),
        ("card-masked", AnyView(AutofillCardSheet(model: model, profile: "default", saved: card)), 260),
        ("card-revealed", AnyView(AutofillCardSheet(model: model, profile: "default", saved: card, number: "4242 4242 4242 4242")), 260),
      ]
      for (name, sheet, height) in sheets {
        try await Snapshot.render(sheet.environment(\.settingsContext, context), size: NSSize(width: 460, height: height), dark: dark, to: directory.appendingPathComponent("autofill-sheet-\(name)-\(scheme).png"))
      }
    }
    let badges = HStack(spacing: 8) { ForEach(CardNetwork.allCases, id: \.self) { AutofillNetworkBadge(network: $0) } }.padding(12)
    try await Snapshot.render(badges, size: NSSize(width: 320, height: 60), dark: false, to: directory.appendingPathComponent("autofill-badges.png"))
  }
}
