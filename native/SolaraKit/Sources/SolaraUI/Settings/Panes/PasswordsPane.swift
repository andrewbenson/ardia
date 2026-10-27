import AppKit
import Observation
import SwiftUI

public struct SavedPassword: Hashable, Sendable, Identifiable {
  public let origin: String
  public let username: String

  public init(origin: String, username: String) {
    self.origin = origin
    self.username = username
  }

  public var id: String { "\(origin)|\(username)" }
}

public struct ImportedCredential: Hashable, Sendable {
  public let url: String
  public let username: String
  public let password: String

  public init(url: String, username: String, password: String) {
    self.url = url
    self.username = username
    self.password = password
  }
}

public enum PasswordExportStatus: String, Sendable {
  case succeeded
  case cancelled
  case writeFailed
  case reauthFailed
  case inProgress
}

public struct PasswordExportResult: Sendable, Equatable {
  public let status: PasswordExportStatus
  public let path: String?

  public init(status: PasswordExportStatus, path: String? = nil) {
    self.status = status
    self.path = path
  }
}

@MainActor
public protocol PasswordsServices: AnyObject {
  func passwordAutofill(profile: String) async -> Bool
  func setPasswordAutofill(_ on: Bool, profile: String) async
  func unlockPasswords(profile: String) async -> Bool
  func listPasswords(profile: String) async -> [SavedPassword]
  func neverSaveOrigins(profile: String) async -> [String]?
  func password(profile: String, origin: String, username: String) async -> String?
  func savePassword(profile: String, origin: String, username: String, password: String) async -> Bool
  func updatePassword(profile: String, origin: String, username: String, newUsername: String?, newPassword: String?) async -> Bool
  func deletePassword(profile: String, origin: String, username: String) async
  func allowSavingPasswords(profile: String, origin: String) async
  func exportPasswords(profile: String) async -> PasswordExportResult
  var passwordsImportAvailable: Bool { get }
  func choosePasswordsCSV() async -> String?
  func importPasswordsCSV(path: String) async throws -> [ImportedCredential]
  var inApplicationsFolder: Bool? { get }
  func copy(_ text: String)
  func hostLabel(_ url: String) -> String
  func searchText(_ fields: [String]) -> String
}

public extension PasswordsServices {
  func hostLabel(_ url: String) -> String { PasswordsText.plainHostLabel(url) }
  func searchText(_ fields: [String]) -> String { fields.joined(separator: " ").lowercased() }
}

enum PasswordsText {
  static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

  static func plainHostLabel(_ url: String) -> String {
    guard let match = url.firstMatch(of: /^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\/([^\/?#:]+)/) else { return url }
    let host = String(match.1).lowercased()
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  static func originOf(_ url: String) -> String {
    guard let match = url.firstMatch(of: /^([a-zA-Z][a-zA-Z0-9+.\-]*:\/\/[^\/?#]+)/) else { return url }
    return String(match.1)
  }

  static func managerAppsNote(appName: String, inApplicationsFolder: Bool?) -> String {
    let apps = "1Password, Bitwarden, KeePassXC and Proton Pass extensions connect to their Mac apps."
    if inApplicationsFolder == false {
      return "\(apps) For 1Password, move \(appName) to your Applications folder and reopen it (1Password only connects to browsers there), then in the 1Password app open Settings › Browser › Add Browser and choose it."
    }
    return "\(apps) For 1Password, add \(appName) once: in the 1Password app, open Settings › Browser › Add Browser and choose \(appName)."
  }

  static func exportMessage(_ result: PasswordExportResult) -> String {
    switch result.status {
    case .succeeded:
      let parts = (result.path ?? "").split(separator: "/", omittingEmptySubsequences: false)
      let folder = parts.count >= 2 ? String(parts[parts.count - 2]) : ""
      return "Saved to “\(folder)”. Delete the file once you're done with it."
    case .writeFailed: return "Couldn't write the file. Try another folder."
    case .inProgress: return "An export is already running."
    case .cancelled, .reauthFailed: return ""
    }
  }

  static func maskedPassword(_ password: String?, revealed: Bool) -> String {
    guard let password else { return "…" }
    return revealed ? password : String(repeating: "•", count: min(password.count, 12))
  }
}

@MainActor
@Observable
public final class PasswordsPaneModel: SettingsPaneProvider {
  public static let unlockDuration: TimeInterval = 5 * 60

  @ObservationIgnored let services: PasswordsServices
  @ObservationIgnored let store: SettingsStoreSource
  @ObservationIgnored let now: () -> Date
  var autofill: [String: Bool] = [:]
  var unlockedUntil: [String: Date] = [:]
  var unlockSerial = 0
  var selectedProfileId: String?
  var listProfile: String?
  var list: [SavedPassword]?
  var never: [String] = []
  var query = ""
  var importStatus = ""
  var exportStatus = ""

  public init(services: PasswordsServices, store: SettingsStoreSource, now: @escaping () -> Date = Date.init) {
    self.services = services
    self.store = store
    self.now = now
  }

  func initialProfileId(_ place: SettingsPlace) -> String {
    place.profileId ?? store.string("defaultProfileId")
  }

  func profileId(_ place: SettingsPlace) -> String {
    selectedProfileId ?? initialProfileId(place)
  }

  func engineProfile(_ place: SettingsPlace) -> String {
    store.engineProfile(profileId(place))
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool {
    autofill.keys.contains(store.engineProfile(initialProfileId(place)))
  }

  public func prepare(_ place: SettingsPlace) async {
    await loadAutofill(store.engineProfile(initialProfileId(place)))
  }

  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(PasswordsPane(model: self, place: place).id(place))
  }

  func loadAutofill(_ profile: String) async {
    autofill[profile] = await services.passwordAutofill(profile: profile)
  }

  func autofillEnabled(_ profile: String) -> Bool { autofill[profile] ?? true }

  func setAutofill(_ on: Bool, profile: String) async {
    await services.setPasswordAutofill(on, profile: profile)
    autofill[profile] = on
  }

  func isUnlocked(_ profile: String) -> Bool {
    _ = unlockSerial
    return now() < (unlockedUntil[profile] ?? .distantPast)
  }

  func unlock(_ profile: String) async {
    guard await services.unlockPasswords(profile: profile) else { return }
    unlockedUntil[profile] = now().addingTimeInterval(Self.unlockDuration)
    unlockSerial += 1
  }

  func load(_ profile: String) async {
    let passwords = await services.listPasswords(profile: profile)
    if listProfile != profile { never = [] }
    listProfile = profile
    list = passwords
    if let origins = await services.neverSaveOrigins(profile: profile), listProfile == profile {
      never = origins
    }
  }

  func shownList(_ profile: String) -> [SavedPassword]? {
    listProfile == profile ? list : nil
  }

  func shownNever(_ profile: String) -> [String] {
    listProfile == profile ? never : []
  }

  func filtered(_ profile: String) -> [SavedPassword] {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    let all = shownList(profile) ?? []
    guard !words.isEmpty else { return all }
    return all.filter { saved in
      let haystack = services.searchText([saved.origin, saved.username])
      return words.allSatisfy { haystack.contains($0) }
    }
  }

  func importCSV(_ profile: String) async {
    guard services.passwordsImportAvailable else {
      importStatus = "Importing isn't available in this build."
      return
    }
    guard let path = await services.choosePasswordsCSV() else { return }
    do {
      let credentials = try await services.importPasswordsCSV(path: path)
      var saved = 0
      for credential in credentials where !credential.url.isEmpty && !credential.password.isEmpty {
        if await services.savePassword(profile: profile, origin: PasswordsText.originOf(credential.url), username: credential.username, password: credential.password) {
          saved += 1
        }
      }
      importStatus = "Imported \(PasswordsText.plural(saved, "password"))."
      if isUnlocked(profile) { await load(profile) }
    } catch {
      importStatus = "Couldn't import that file: \(error.localizedDescription)"
    }
  }

  func exportCSV(_ profile: String) async {
    exportStatus = PasswordsText.exportMessage(await services.exportPasswords(profile: profile))
  }

  func allowSaving(_ origin: String, profile: String) async {
    await services.allowSavingPasswords(profile: profile, origin: origin)
    await load(profile)
  }

  func selectProfile(_ id: String) {
    selectedProfileId = id
    query = ""
  }

  func paneDisappeared() {
    selectedProfileId = nil
    listProfile = nil
    list = nil
    never = []
    query = ""
    importStatus = ""
    exportStatus = ""
  }
}

enum PasswordsSheetItem: Identifiable {
  case password(SavedPassword)

  var id: String {
    switch self {
    case .password(let saved): saved.id
    }
  }
}

struct PasswordsPane: View {
  @Environment(\.settingsContext) private var context
  let model: PasswordsPaneModel
  let place: SettingsPlace
  @State private var sheet: PasswordsSheetItem?

  private struct LoadKey: Hashable {
    let profile: String
    let unlocked: Bool
  }

  var body: some View {
    let profile = model.engineProfile(place)
    let unlocked = model.isUnlocked(profile)
    let profiles = model.store.profiles
    SettingsForm {
      SettingsSection(
        "Passwords",
        description: "Saved on this Mac, separately for each profile, and encrypted with a key in your Keychain."
      ) {
        if profiles.count > 1 {
          SettingPicker(profiles.map { SettingOption($0.id, $0.name) }, selection: Binding(get: { model.profileId(place) }, set: { model.selectProfile($0) }))
        }
      } content: {
        SettingRow("passwords.offerToSave") {
          Toggle("", isOn: Binding(
            get: { model.autofillEnabled(profile) },
            set: { on in Task { await model.setAutofill(on, profile: profile) } }
          ))
          .labelsHidden()
          .toggleStyle(.settingsSwitch)
        }
        SettingRow("passwords.importPasswords", description: model.importStatus.isEmpty ? nil : model.importStatus) {
          Button("Import CSV…") { Task { await model.importCSV(profile) } }
        }
        SettingRow("passwords.exportPasswords", description: model.exportStatus.isEmpty ? nil : model.exportStatus) {
          Button("Export CSV…") { Task { await model.exportCSV(profile) } }
        }
        SettingRow(
          "passwords.managerApps",
          description: .text(PasswordsText.managerAppsNote(appName: context?.appName ?? "", inApplicationsFolder: model.services.inApplicationsFolder))
        )
      }

      if unlocked {
        PasswordsSavedSections(model: model, profile: profile, sheet: $sheet)
      } else {
        PasswordsLockedSection(model: model, profile: profile)
      }
    }
    .task(id: profile) { await model.loadAutofill(profile) }
    .task(id: LoadKey(profile: profile, unlocked: unlocked)) {
      if unlocked { await model.load(profile) }
    }
    .onDisappear { model.paneDisappeared() }
    .sheet(item: $sheet) { item in
      switch item {
      case .password(let saved):
        PasswordDetailSheet(model: model, profile: profile, saved: saved)
      }
    }
  }
}

struct PasswordsLockedSection: View {
  let model: PasswordsPaneModel
  let profile: String

  var body: some View {
    Section {
    } header: {
      VStack(spacing: 10) {
        Image(systemName: "lock.fill")
          .font(.system(size: 26))
          .foregroundStyle(.tertiary)
          .frame(width: 36, height: 36)
        Text("Passwords are locked")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.primary)
        Text("Unlock with Touch ID or your login password to see them.")
          .font(.system(size: 12))
          .fontWeight(.regular)
          .foregroundStyle(.secondary)
        Button("Unlock") { Task { await model.unlock(profile) } }
          .buttonStyle(.settingsPrimary)
          .padding(.top, 6)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 28)
    }
  }
}

struct PasswordsSavedSections: View {
  let model: PasswordsPaneModel
  let profile: String
  @Binding var sheet: PasswordsSheetItem?

  var body: some View {
    let list = model.shownList(profile)
    let shown = model.filtered(profile)
    let never = model.shownNever(profile)
    SettingsSection(list.map { PasswordsText.plural($0.count, "Saved Password") } ?? "Saved Passwords") {
      PasswordsSearchField(text: Binding(get: { model.query }, set: { model.query = $0 }))
        .frame(width: 200)
    } content: {
      if list != nil && shown.isEmpty {
        SettingRow(title: model.query.isEmpty ? "No saved passwords" : "No passwords match", description: .none)
      } else {
        ForEach(shown) { saved in
          PasswordsLinkRow(title: model.services.hostLabel(saved.origin), description: saved.username.isEmpty ? "(no username)" : saved.username) {
            SettingsFavicon(url: saved.origin, profile: profile)
          } action: {
            sheet = .password(saved)
          }
        }
      }
    }
    if !never.isEmpty {
      SettingsSection("Never saved", description: "Sites where you chose “Never on This Site”.") {
        ForEach(never, id: \.self) { origin in
          LabeledContent {
            Button("Remove") { Task { await model.allowSaving(origin, profile: profile) } }
          } label: {
            HStack(spacing: 12) {
              SettingsFavicon(url: origin, profile: profile)
              Text(model.services.hostLabel(origin))
            }
          }
        }
      }
    }
  }
}

struct PasswordsLinkRow<Icon: View>: View {
  let title: String
  let description: String?
  let icon: Icon
  let action: () -> Void
  @State private var hovered = false

  init(title: String, description: String?, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) {
    self.title = title
    self.description = description
    self.icon = icon()
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        icon
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .foregroundStyle(.primary)
          if let description, !description.isEmpty {
            Text(description)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .background {
      RoundedRectangle(cornerRadius: 5)
        .fill(Color.primary.opacity(hovered ? 0.06 : 0))
        .padding(.horizontal, -6)
        .padding(.vertical, -4)
    }
  }
}


struct PasswordsSearchField: NSViewRepresentable {
  @Binding var text: String

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Search"
    field.sendsSearchStringImmediately = true
    field.delegate = context.coordinator
    field.controlSize = .regular
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
  }

  @MainActor
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: PasswordsSearchField

    init(_ parent: PasswordsSearchField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      parent.text = field.stringValue
    }
  }
}
