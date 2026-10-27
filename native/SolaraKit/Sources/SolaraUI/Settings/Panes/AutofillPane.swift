import Observation
import SwiftUI

public struct SavedAddress: Hashable, Sendable, Identifiable {
  public let id: String
  public var name: String?
  public var organization: String?
  public var street: String?
  public var city: String?
  public var state: String?
  public var postalCode: String?
  public var country: String?
  public var phone: String?
  public var email: String?

  public init(id: String, name: String? = nil, organization: String? = nil, street: String? = nil, city: String? = nil, state: String? = nil, postalCode: String? = nil, country: String? = nil, phone: String? = nil, email: String? = nil) {
    self.id = id
    self.name = name
    self.organization = organization
    self.street = street
    self.city = city
    self.state = state
    self.postalCode = postalCode
    self.country = country
    self.phone = phone
    self.email = email
  }
}

public struct AddressInput: Hashable, Sendable {
  public var id: String?
  public var name: String
  public var organization: String
  public var street: String
  public var city: String
  public var state: String
  public var postalCode: String
  public var country: String
  public var phone: String
  public var email: String

  public var fields: [String: String] {
    var fields = ["name": name, "organization": organization, "street": street, "city": city, "state": state, "postalCode": postalCode, "country": country, "phone": phone, "email": email]
    if let id { fields["id"] = id }
    return fields
  }
}

public enum CardNetwork: String, Sendable, CaseIterable {
  case visa
  case mastercard
  case amex
  case discover
  case diners
  case jcb
  case unionpay
  case card

  public var displayName: String {
    switch self {
    case .visa: "Visa"
    case .mastercard: "Mastercard"
    case .amex: "American Express"
    case .discover: "Discover"
    case .diners: "Diners Club"
    case .jcb: "JCB"
    case .unionpay: "UnionPay"
    case .card: "Card"
    }
  }
}

public struct SavedCard: Hashable, Sendable, Identifiable {
  public let id: String
  public var name: String?
  public var network: CardNetwork
  public var last4: String
  public var expMonth: Int?
  public var expYear: Int?

  public init(id: String, name: String? = nil, network: CardNetwork, last4: String, expMonth: Int? = nil, expYear: Int? = nil) {
    self.id = id
    self.name = name
    self.network = network
    self.last4 = last4
    self.expMonth = expMonth
    self.expYear = expYear
  }

  public var title: String { "\(network.displayName) •••• \(last4)" }
}

public struct CardInput: Hashable, Sendable {
  public var id: String?
  public var name: String
  public var expMonth: Int?
  public var expYear: Int?
}

public struct AutofillEnabled: Hashable, Sendable {
  public var addresses: Bool
  public var cards: Bool

  public init(addresses: Bool, cards: Bool) {
    self.addresses = addresses
    self.cards = cards
  }
}

@MainActor
public protocol AutofillServices: AnyObject {
  func autofillSettings(profile: String) async -> AutofillEnabled
  func setAutofillSettings(addresses: Bool?, cards: Bool?, profile: String) async
  func addresses(profile: String) async -> [SavedAddress]
  func saveAddress(_ address: AddressInput, profile: String) async -> String?
  func cards(profile: String) async -> [SavedCard]
  func saveCard(_ card: CardInput, number: String?, profile: String) async -> String?
  func deleteAutofillEntry(_ id: String, profile: String) async
  func revealCardNumber(_ id: String, profile: String) async -> String?
  func copy(_ text: String)
}

enum AutofillText {
  static func firstLine(_ street: String?) -> String {
    guard let street else { return "" }
    return street.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
  }

  static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  static func addressTitle(_ address: SavedAddress) -> String {
    nonEmpty(address.name) ?? nonEmpty(firstLine(address.street)) ?? nonEmpty(address.email) ?? "Address"
  }

  static func addressSummary(_ address: SavedAddress) -> String {
    let place = [address.city, address.state, address.postalCode].compactMap(nonEmpty).joined(separator: " ")
    let street = nonEmpty(address.name) != nil ? firstLine(address.street) : ""
    return [street, place, address.email ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
  }

  static func pad(_ value: Int) -> String { value < 10 && value >= 0 ? "0\(value)" : "\(value)" }

  static func isExpired(_ card: SavedCard, now: Date) -> Bool {
    guard let month = card.expMonth, month != 0, let year = card.expYear, year != 0 else { return false }
    let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
    let thisYear = parts.year ?? 0
    let thisMonth = parts.month ?? 0
    return year < thisYear || (year == thisYear && month < thisMonth)
  }

  static func cardSummary(_ card: SavedCard, now: Date) -> String {
    var expiry = ""
    if let month = card.expMonth, month != 0, let year = card.expYear, year != 0 {
      expiry = "\(isExpired(card, now: now) ? "Expired" : "Expires") \(pad(month))/\(pad(year % 100))"
    }
    return [expiry, card.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  static func digits(_ text: String) -> String {
    String(text.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.map(Character.init))
  }

  static func formatCardNumber(_ digits: String) -> String {
    let characters = Array(digits)
    let groups = digits.hasPrefix("34") || digits.hasPrefix("37") ? [4, 6, 5] : [4, 4, 4, 4, 3]
    var out: [String] = []
    var index = 0
    for group in groups {
      if index >= characters.count { break }
      out.append(String(characters[index..<min(index + group, characters.count)]))
      index += group
    }
    if index < characters.count { out.append(String(characters[index...])) }
    return out.joined(separator: " ")
  }

  static func yearOptions(current: Int?, now: Date) -> [SettingOption] {
    let thisYear = Calendar(identifier: .gregorian).component(.year, from: now)
    var years = Array(thisYear..<(thisYear + 16))
    if let current, current != 0, !years.contains(current) { years.insert(current, at: 0) }
    return [SettingOption("", "Year")] + years.map { SettingOption(String($0), String($0)) }
  }

  static let monthOptions: [SettingOption] = [SettingOption("", "Month")] + (1...12).map { SettingOption(String($0), pad($0)) }
}

@MainActor
@Observable
public final class AutofillPaneModel: SettingsPaneProvider {
  @ObservationIgnored let services: AutofillServices
  @ObservationIgnored let store: SettingsStoreSource
  @ObservationIgnored let now: () -> Date
  var addresses: [String: [SavedAddress]] = [:]
  var cards: [String: [SavedCard]] = [:]
  var enabled: [String: AutofillEnabled] = [:]

  public init(services: AutofillServices, store: SettingsStoreSource, now: @escaping () -> Date = Date.init) {
    self.services = services
    self.store = store
    self.now = now
  }

  func initialProfileId(_ place: SettingsPlace) -> String {
    place.profileId ?? store.string("defaultProfileId")
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool {
    let profile = store.engineProfile(initialProfileId(place))
    return addresses[profile] != nil && cards[profile] != nil && enabled[profile] != nil
  }

  public func prepare(_ place: SettingsPlace) async {
    await load(store.engineProfile(initialProfileId(place)))
  }

  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(AutofillPane(model: self, initialProfileId: initialProfileId(place)).id(place))
  }

  func load(_ profile: String) async {
    await reload(profile)
    enabled[profile] = await services.autofillSettings(profile: profile)
  }

  func reload(_ profile: String) async {
    addresses[profile] = await services.addresses(profile: profile)
    cards[profile] = await services.cards(profile: profile)
  }

  func setEnabled(addresses on: Bool, profile: String) async {
    await services.setAutofillSettings(addresses: on, cards: nil, profile: profile)
    enabled[profile]?.addresses = on
  }

  func setEnabled(cards on: Bool, profile: String) async {
    await services.setAutofillSettings(addresses: nil, cards: on, profile: profile)
    enabled[profile]?.cards = on
  }
}

enum AutofillSheetItem: Identifiable {
  case address(SavedAddress?)
  case card(SavedCard?)

  var id: String {
    switch self {
    case .address(let saved): "address:\(saved?.id ?? "")"
    case .card(let saved): "card:\(saved?.id ?? "")"
    }
  }
}

struct AutofillPane: View {
  let model: AutofillPaneModel
  @State private var profileId: String
  @State private var sheet: AutofillSheetItem?

  init(model: AutofillPaneModel, initialProfileId: String) {
    self.model = model
    _profileId = State(initialValue: initialProfileId)
  }

  var body: some View {
    let profiles = model.store.profiles
    let profile = model.store.engineProfile(profileId)
    let addresses = model.addresses[profile]
    let cards = model.cards[profile]
    let enabled = model.enabled[profile]
    let now = model.now()
    SettingsForm {
      SettingsSection(
        "Autofill",
        description: "Addresses and cards you save are offered when you fill in a form, separately for each profile. Card numbers are kept in your macOS Keychain."
      ) {
        if profiles.count > 1 {
          SettingPicker(profiles.map { SettingOption($0.id, $0.name) }, selection: $profileId)
        }
      } content: {
        SettingRow("autofill.addresses") {
          Toggle("", isOn: Binding(
            get: { enabled?.addresses ?? true },
            set: { on in Task { await model.setEnabled(addresses: on, profile: profile) } }
          ))
          .labelsHidden()
          .toggleStyle(.settingsSwitch)
          .disabled(enabled == nil)
        }
        SettingRow("autofill.cards") {
          Toggle("", isOn: Binding(
            get: { enabled?.cards ?? true },
            set: { on in Task { await model.setEnabled(cards: on, profile: profile) } }
          ))
          .labelsHidden()
          .toggleStyle(.settingsSwitch)
          .disabled(enabled == nil)
        }
      }

      SettingsSection(anchor: "autofill.addressList") {
        Button("Add Address…") { sheet = .address(nil) }
      } content: {
        if let addresses, addresses.isEmpty {
          SettingRow(title: "No saved addresses", description: .text("Addresses you enter in forms can be saved here."))
        } else {
          ForEach(addresses ?? []) { address in
            PasswordsLinkRow(title: AutofillText.addressTitle(address), description: AutofillText.addressSummary(address)) {
              Image(systemName: "person.crop.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
            } action: {
              sheet = .address(address)
            }
          }
        }
      }

      SettingsSection(anchor: "autofill.cardList") {
        Button("Add Card…") { sheet = .card(nil) }
      } content: {
        if let cards, cards.isEmpty {
          SettingRow(title: "No saved cards", description: .text("Cards you enter at checkout can be saved here."))
        } else {
          ForEach(cards ?? []) { card in
            PasswordsLinkRow(title: card.title, description: AutofillText.cardSummary(card, now: now)) {
              AutofillNetworkBadge(network: card.network)
            } action: {
              sheet = .card(card)
            }
          }
        }
      }
    }
    .task(id: profile) { await model.load(profile) }
    .sheet(item: $sheet) { item in
      switch item {
      case .address(let saved): AutofillAddressSheet(model: model, profile: profile, saved: saved)
      case .card(let saved): AutofillCardSheet(model: model, profile: profile, saved: saved)
      }
    }
  }
}

struct AutofillNetworkBadge: View {
  let network: CardNetwork

  private struct Badge {
    let label: String
    let fill: Color
  }

  private static func hex(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
  }

  private var badge: Badge {
    switch network {
    case .visa: Badge(label: "VISA", fill: Self.hex(0x1A1F71))
    case .mastercard: Badge(label: "", fill: Self.hex(0x1C1C1E))
    case .amex: Badge(label: "AMEX", fill: Self.hex(0x2E77BC))
    case .discover: Badge(label: "DISC", fill: Self.hex(0xFF6000))
    case .diners: Badge(label: "DC", fill: Self.hex(0x0079BE))
    case .jcb: Badge(label: "JCB", fill: Self.hex(0x0B7A3E))
    case .unionpay: Badge(label: "UP", fill: Self.hex(0xD7282F))
    case .card: Badge(label: "", fill: Self.hex(0x8E8E93))
    }
  }

  var body: some View {
    let badge = badge
    RoundedRectangle(cornerRadius: 3.5)
      .fill(badge.fill)
      .frame(width: 28, height: 19)
      .overlay {
        if network == .mastercard {
          HStack(spacing: -3.5) {
            Circle().fill(Self.hex(0xEB001B)).frame(width: 10, height: 10)
            Circle().fill(Self.hex(0xF79E1B)).opacity(0.9).frame(width: 10, height: 10)
          }
        } else if !badge.label.isEmpty {
          Text(badge.label)
            .font(.system(size: badge.label.count > 3 ? 7.5 : 8, weight: .heavy))
            .italic(network == .visa)
            .tracking(0.3)
            .foregroundStyle(.white)
        } else {
          Image(systemName: "creditcard.fill")
            .font(.system(size: 10))
            .foregroundStyle(.white)
        }
      }
  }
}
