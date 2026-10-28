import AppKit
import ArdiaCore
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
    ArdiaCoreServices.boolPreference("credentials_enable_service", profile: profile)
  }

  func setPasswordAutofill(_ on: Bool, profile: String) async {
    ArdiaCoreServices.setBoolPreference("credentials_enable_service", value: on, profile: profile)
  }

  func unlockPasswords(profile: String) async -> Bool {
    await EngineCalls.result({ done in ArdiaCoreServices.unlockPasswords(profile: profile) { done($0) } }) {
      EngineCalls.failed($0, "unlockPasswords") ? false : $0["unlocked"] as? Bool ?? false
    }
  }

  func listPasswords(profile: String) async -> [SavedPassword] {
    await EngineCalls.result({ done in ArdiaCoreServices.listPasswords(profile: profile) { done($0) } }) {
      EngineCalls.failed($0, "listPasswords") ? [] : Self.passwords($0.list("passwords"))
    }
  }

  nonisolated static func passwords(_ list: [[String: Any]]) -> [SavedPassword] {
    list.compactMap { entry in
      guard let origin = entry.string("origin") else { return nil }
      return SavedPassword(origin: origin, username: entry.string("username") ?? "")
    }
  }

  func neverSaveOrigins(profile: String) async -> [String]? {
    await EngineCalls.result({ done in ArdiaCoreServices.neverSaveOrigins(profile: profile) { done($0) } }) {
      EngineCalls.failed($0, "neverSaveOrigins") ? [] : $0.strings("origins")
    }
  }

  func password(profile: String, origin: String, username: String) async -> String? {
    await EngineCalls.result({ done in ArdiaCoreServices.password(profile: profile, origin: origin, username: username) { done($0) } }) {
      EngineCalls.failed($0, "password") ? nil : $0.string("password")
    }
  }

  func savePassword(profile: String, origin: String, username: String, password: String) async -> Bool {
    await EngineCalls.result({ done in
      ArdiaCoreServices.savePassword(profile: profile, origin: origin, username: username, password: password) { done($0) }
    }) { !EngineCalls.failed($0, "savePassword") }
  }

  func updatePassword(profile: String, origin: String, username: String, newUsername: String?, newPassword: String?) async -> Bool {
    await EngineCalls.result({ done in
      ArdiaCoreServices.updatePassword(profile: profile, origin: origin, username: username, newUsername: newUsername, newPassword: newPassword) {
        done($0)
      }
    }) { !EngineCalls.failed($0, "updatePassword") }
  }

  func deletePassword(profile: String, origin: String, username: String) async {
    await EngineCalls.result({ done in ArdiaCoreServices.deletePassword(profile: profile, origin: origin, username: username) { done($0) } }) {
      _ = EngineCalls.failed($0, "deletePassword")
    }
  }

  func allowSavingPasswords(profile: String, origin: String) async {
    await EngineCalls.result({ done in ArdiaCoreServices.allowSaving(profile: profile, origin: origin) { done($0) } }) {
      _ = EngineCalls.failed($0, "allowSaving")
    }
  }

  func exportPasswords(profile: String) async -> PasswordExportResult {
    await EngineCalls.result({ done in ArdiaCoreServices.exportPasswords(profile: profile, path: nil) { done($0) } }) {
      if EngineCalls.failed($0, "exportPasswords") { return PasswordExportResult(status: .writeFailed, path: nil) }
      let status = $0.string("status").flatMap(PasswordExportStatus.init(rawValue:)) ?? .writeFailed
      return PasswordExportResult(status: status, path: $0.string("path"))
    }
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
