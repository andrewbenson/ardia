import AppKit
import Foundation
import Observation
import SolaraOmnibox
import SolaraUI

struct PasswordsImportError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

@MainActor
@Observable
final class PasswordsAdapter: PasswordsServices {
  private var importAvailable: Bool
  @ObservationIgnored private var observer: UUID?
  let inApplicationsFolder: Bool?

  init() {
    let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    inApplicationsFolder = path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    importAvailable = SettingsJS.shared.latestValue("passwords.importAvailable") as? Bool ?? true
    observer = SettingsJS.shared.observe("passwords.importAvailable") { [weak self] value in
      self?.importAvailable = value as? Bool ?? true
    }
  }

  func passwordAutofill(profile: String) async -> Bool {
    await SettingsAdapters.js("passwords.autofill", profile) as? Bool ?? true
  }

  func setPasswordAutofill(_ on: Bool, profile: String) async {
    await SettingsAdapters.js("passwords.setAutofill", on, profile)
  }

  func unlockPasswords(profile: String) async -> Bool {
    await SettingsAdapters.js("passwords.unlock", profile) as? Bool ?? false
  }

  func listPasswords(profile: String) async -> [SavedPassword] {
    let list = await SettingsAdapters.js("passwords.list", profile) as? [[String: Any]] ?? []
    return list.compactMap { entry in
      guard let origin = entry.string("origin") else { return nil }
      return SavedPassword(origin: origin, username: entry.string("username") ?? "")
    }
  }

  func neverSaveOrigins(profile: String) async -> [String]? {
    await SettingsAdapters.js("passwords.neverSaveOrigins", profile) as? [String]
  }

  func password(profile: String, origin: String, username: String) async -> String? {
    await SettingsAdapters.js("passwords.password", profile, origin, username) as? String
  }

  func savePassword(profile: String, origin: String, username: String, password: String) async -> Bool {
    await SettingsAdapters.js("passwords.save", profile, origin, username, password) as? Bool ?? false
  }

  func updatePassword(profile: String, origin: String, username: String, newUsername: String?, newPassword: String?) async -> Bool {
    await SettingsAdapters.js("passwords.update", profile, origin, username, jsonArg(newUsername), jsonArg(newPassword)) as? Bool ?? false
  }

  func deletePassword(profile: String, origin: String, username: String) async {
    await SettingsAdapters.js("passwords.delete", profile, origin, username)
  }

  func allowSavingPasswords(profile: String, origin: String) async {
    await SettingsAdapters.js("passwords.allowSaving", profile, origin)
  }

  func exportPasswords(profile: String) async -> PasswordExportResult {
    let result = await SettingsAdapters.js("passwords.export", profile) as? [String: Any] ?? [:]
    let status = result.string("status").flatMap(PasswordExportStatus.init(rawValue:)) ?? .writeFailed
    return PasswordExportResult(status: status, path: result.string("path"))
  }

  var passwordsImportAvailable: Bool { importAvailable }

  func choosePasswordsCSV() async -> String? {
    await SettingsAdapters.js("passwords.chooseCSV") as? String
  }

  func importPasswordsCSV(path: String) async throws -> [ImportedCredential] {
    let result: Any?
    do {
      result = try await SettingsAdapters.jsThrowing("passwords.importCSV", path)
    } catch let error as SettingsJSError {
      throw PasswordsImportError(message: error.description)
    }
    let list = result as? [[String: Any]] ?? []
    return list.map { ImportedCredential(url: $0.string("url") ?? "", username: $0.string("username") ?? "", password: $0.string("password") ?? "") }
  }

  func copy(_ text: String) { SettingsAdapters.copyText(text) }

  func hostLabel(_ url: String) -> String {
    if let app = SolaraOmnibox.appUrlOrigin(url) { return app }
    guard let match = url.firstMatch(of: /^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\/([^\/?#:]+)/) else { return url }
    let host = SolaraOmnibox.displayHost(String(match.1).lowercased())
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  func searchText(_ fields: [String]) -> String {
    fields.map { $0.range(of: "xn--", options: .caseInsensitive) != nil ? "\($0) \(SolaraOmnibox.urlForDisplay($0))" : $0 }
      .joined(separator: " ")
      .lowercased()
  }
}
