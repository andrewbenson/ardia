import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SolaraUI

struct PasswordsImportFailure: LocalizedError {
  var errorDescription: String? { "The file has no header row." }
}

@MainActor
final class FakePasswordsServices: PasswordsServices {
  var autofill: [String: Bool] = ["default": true, "work": false]
  var unlockAnswer = true
  var unlockCalls: [String] = []
  var listCalls: [String] = []
  var neverCalls: [String] = []
  var passwordCalls: [String] = []
  var saved: [String: [SavedPassword]] = [
    "default": [
      SavedPassword(origin: "https://github.com", username: "owner"),
      SavedPassword(origin: "https://www.figma.com", username: "owner@example.com"),
      SavedPassword(origin: "https://accounts.google.com", username: "owner.personal@gmail.com"),
      SavedPassword(origin: "http://192.168.1.1", username: ""),
      SavedPassword(origin: "https://news.ycombinator.com", username: "owner"),
    ],
    "work": [SavedPassword(origin: "https://linear.app", username: "owner@work.example")],
  ]
  var secrets: [String: String] = ["https://github.com|owner": "correct-horse-battery-staple-42"]
  var never: [String: [String]] = ["default": ["https://www.example.com", "https://bank.example"]]
  var importAvailable = true
  var chosenCSV: String? = "/Users/owner/Downloads/Chrome Passwords.csv"
  var csv: Result<[ImportedCredential], PasswordsImportFailure> = .success([])
  var savedPasswords: [(String, String, String, String)] = []
  var updates: [(origin: String, username: String, newUsername: String?, newPassword: String?)] = []
  var deletes: [String] = []
  var allowed: [String] = []
  var exportResult = PasswordExportResult(status: .succeeded, path: "/Users/owner/Desktop/Solara Passwords.csv")
  var applicationsFolder: Bool? = true
  var copied: [String] = []

  func passwordAutofill(profile: String) async -> Bool { autofill[profile] ?? true }
  func setPasswordAutofill(_ on: Bool, profile: String) async { autofill[profile] = on }
  func unlockPasswords(profile: String) async -> Bool {
    unlockCalls.append(profile)
    return unlockAnswer
  }
  func listPasswords(profile: String) async -> [SavedPassword] {
    listCalls.append(profile)
    return saved[profile] ?? []
  }
  func neverSaveOrigins(profile: String) async -> [String]? {
    neverCalls.append(profile)
    return never[profile] ?? []
  }
  func password(profile: String, origin: String, username: String) async -> String? {
    passwordCalls.append("\(origin)|\(username)")
    return secrets["\(origin)|\(username)"] ?? "hunter2"
  }
  func savePassword(profile: String, origin: String, username: String, password: String) async -> Bool {
    savedPasswords.append((profile, origin, username, password))
    return origin.hasPrefix("https://")
  }
  func updatePassword(profile: String, origin: String, username: String, newUsername: String?, newPassword: String?) async -> Bool {
    updates.append((origin, username, newUsername, newPassword))
    return true
  }
  func deletePassword(profile: String, origin: String, username: String) async {
    deletes.append("\(origin)|\(username)")
    saved[profile]?.removeAll { $0.origin == origin && $0.username == username }
  }
  func allowSavingPasswords(profile: String, origin: String) async {
    allowed.append(origin)
    never[profile]?.removeAll { $0 == origin }
  }
  func exportPasswords(profile: String) async -> PasswordExportResult { exportResult }
  var passwordsImportAvailable: Bool { importAvailable }
  func choosePasswordsCSV() async -> String? { chosenCSV }
  func importPasswordsCSV(path: String) async throws -> [ImportedCredential] { try csv.get() }
  var inApplicationsFolder: Bool? { applicationsFolder }
  func copy(_ text: String) { copied.append(text) }
  func favicon(url: String, profile: String) async -> NSImage? {
    guard url.contains("github") else { return nil }
    return NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
  }
}

final class TestClock: @unchecked Sendable {
  var date = Date(timeIntervalSince1970: 1_792_000_000)
  func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
struct PasswordsPaneTests {
  static func fixture(clock: TestClock = TestClock()) -> (PasswordsPaneModel, FakePasswordsServices, FakeSettingsStore, SettingsContext) {
    let (context, store) = SettingsFixture.context()
    store.values["defaultProfileId"] = .string("default")
    let services = FakePasswordsServices()
    let model = PasswordsPaneModel(services: services, store: store, now: { clock.date })
    context.panes[.passwords] = model
    return (model, services, store, context)
  }

  @Test func prepareLoadsOnlyTheAutofillToggleNeverThePasswordList() async {
    let (model, services, _, _) = Self.fixture()
    let place = SettingsPlace(pane: .passwords)
    #expect(!model.isLoaded(place))
    await model.prepare(place)
    #expect(model.isLoaded(place))
    #expect(services.listCalls.isEmpty)
    #expect(services.neverCalls.isEmpty)
    #expect(services.unlockCalls.isEmpty)
    #expect(model.autofillEnabled("default"))
    await model.prepare(SettingsPlace(pane: .passwords, profileId: "work"))
    #expect(model.autofillEnabled("work") == false)
  }

  @Test func unlockLastsFiveMinutesPerProfileAndSurvivesThePaneGoingAway() async {
    let clock = TestClock()
    let (model, services, _, _) = Self.fixture(clock: clock)
    #expect(!model.isUnlocked("default"))
    await model.unlock("default")
    #expect(services.unlockCalls == ["default"])
    #expect(model.isUnlocked("default"))
    #expect(!model.isUnlocked("work"))
    model.paneDisappeared()
    #expect(model.isUnlocked("default"))
    clock.advance(4 * 60 + 59)
    #expect(model.isUnlocked("default"))
    clock.advance(1)
    #expect(!model.isUnlocked("default"))
  }

  @Test func failedReauthKeepsPasswordsLocked() async {
    let (model, services, _, _) = Self.fixture()
    services.unlockAnswer = false
    await model.unlock("default")
    #expect(!model.isUnlocked("default"))
  }

  @Test func paneDisappearingDropsTheListQueryStatusesAndProfileChoice() async {
    let (model, _, _, _) = Self.fixture()
    let place = SettingsPlace(pane: .passwords)
    model.selectProfile("work")
    #expect(model.engineProfile(place) == "work")
    await model.load("work")
    model.query = "linear"
    model.importStatus = "Imported 2 passwords."
    model.exportStatus = "An export is already running."
    model.paneDisappeared()
    #expect(model.list == nil)
    #expect(model.never.isEmpty)
    #expect(model.query.isEmpty)
    #expect(model.importStatus.isEmpty)
    #expect(model.exportStatus.isEmpty)
    #expect(model.engineProfile(place) == "default")
    #expect(model.engineProfile(SettingsPlace(pane: .passwords, profileId: "work")) == "work")
  }

  @Test func listIsShownOnlyForTheProfileItWasLoadedFor() async {
    let (model, _, _, _) = Self.fixture()
    await model.load("default")
    #expect(model.shownList("default")?.count == 5)
    #expect(model.shownNever("default") == ["https://www.example.com", "https://bank.example"])
    #expect(model.shownList("work") == nil)
    #expect(model.shownNever("work").isEmpty)
  }

  @Test func searchMatchesEveryWordAcrossOriginAndUsername() async {
    let (model, _, _, _) = Self.fixture()
    await model.load("default")
    model.query = "OWNER git"
    #expect(model.filtered("default").map(\.origin) == ["https://github.com"])
    model.query = "gmail"
    #expect(model.filtered("default").map(\.origin) == ["https://accounts.google.com"])
    model.query = "nothing"
    #expect(model.filtered("default").isEmpty)
    model.query = "  "
    #expect(model.filtered("default").count == 5)
  }

  @Test func removingANeverSaveSiteAllowsItAndReloads() async {
    let (model, services, _, _) = Self.fixture()
    await model.load("default")
    await model.allowSaving("https://bank.example", profile: "default")
    #expect(services.allowed == ["https://bank.example"])
    #expect(model.shownNever("default") == ["https://www.example.com"])
  }

  @Test func importSavesOnlyCredentialsWithAURLAndPasswordAtTheirOrigin() async {
    let (model, services, _, _) = Self.fixture()
    services.csv = .success([
      ImportedCredential(url: "https://login.example.com/path?next=1", username: "a", password: "p1"),
      ImportedCredential(url: "", username: "b", password: "p2"),
      ImportedCredential(url: "https://other.example", username: "c", password: ""),
      ImportedCredential(url: "android://hash@com.example", username: "d", password: "p4"),
      ImportedCredential(url: "https://third.example:8443/x", username: "", password: "p5"),
    ])
    await model.importCSV("default")
    #expect(services.savedPasswords.map(\.1) == ["https://login.example.com", "android://hash@com.example", "https://third.example:8443"])
    #expect(model.importStatus == "Imported 2 passwords.")
    #expect(services.listCalls.isEmpty)
    await model.unlock("default")
    services.csv = .success([ImportedCredential(url: "https://one.example", username: "x", password: "y")])
    await model.importCSV("default")
    #expect(model.importStatus == "Imported 1 password.")
    #expect(services.listCalls == ["default"])
  }

  @Test func importReportsMissingSupportCancellationAndErrors() async {
    let (model, services, _, _) = Self.fixture()
    services.importAvailable = false
    await model.importCSV("default")
    #expect(model.importStatus == "Importing isn't available in this build.")
    services.importAvailable = true
    model.importStatus = ""
    services.chosenCSV = nil
    await model.importCSV("default")
    #expect(model.importStatus.isEmpty)
    services.chosenCSV = "/tmp/broken.csv"
    services.csv = .failure(PasswordsImportFailure())
    await model.importCSV("default")
    #expect(model.importStatus == "Couldn't import that file: The file has no header row.")
  }

  @Test func exportStatusText() async {
    let (model, services, _, _) = Self.fixture()
    await model.exportCSV("default")
    #expect(model.exportStatus == "Saved to “Desktop”. Delete the file once you're done with it.")
    services.exportResult = PasswordExportResult(status: .writeFailed)
    await model.exportCSV("default")
    #expect(model.exportStatus == "Couldn't write the file. Try another folder.")
    services.exportResult = PasswordExportResult(status: .inProgress)
    await model.exportCSV("default")
    #expect(model.exportStatus == "An export is already running.")
    services.exportResult = PasswordExportResult(status: .reauthFailed)
    await model.exportCSV("default")
    #expect(model.exportStatus.isEmpty)
    #expect(PasswordsText.exportMessage(PasswordExportResult(status: .cancelled)).isEmpty)
  }

  @Test func autofillToggleWritesThroughAndCaches() async {
    let (model, services, _, _) = Self.fixture()
    await model.setAutofill(false, profile: "default")
    #expect(services.autofill["default"] == false)
    #expect(model.autofillEnabled("default") == false)
    #expect(model.autofillEnabled("unknown"))
  }

  @Test func textHelpers() {
    #expect(PasswordsText.plural(1, "Saved Password") == "1 Saved Password")
    #expect(PasswordsText.plural(0, "Saved Password") == "0 Saved Passwords")
    #expect(PasswordsText.plainHostLabel("https://www.GitHub.com/login") == "github.com")
    #expect(PasswordsText.plainHostLabel("not a url") == "not a url")
    #expect(PasswordsText.maskedPassword(nil, revealed: true) == "…")
    #expect(PasswordsText.maskedPassword("abc", revealed: false) == "•••")
    #expect(PasswordsText.maskedPassword("correct-horse-battery-staple", revealed: false) == String(repeating: "•", count: 12))
    #expect(PasswordsText.maskedPassword("abc", revealed: true) == "abc")
    #expect(PasswordsFavicon.initial("https://www.github.com", label: "github.com") == "G")
    #expect(PasswordsFavicon.initial("http://192.168.1.1", label: "192.168.1.1") == nil)
    #expect(PasswordsFavicon.initial("android://x@com.example", label: "x") == nil)
    let moved = PasswordsText.managerAppsNote(appName: "Solara", inApplicationsFolder: false)
    #expect(moved.contains("move Solara to your Applications folder"))
    let added = PasswordsText.managerAppsNote(appName: "Solara", inApplicationsFolder: nil)
    #expect(added.hasSuffix("Add Browser and choose Solara."))
  }

  static func renderWindow(_ context: SettingsContext, _ place: SettingsPlace, named name: String, setup: () async -> Void = {}) async throws {
    let directory = try #require(Snapshot.directory)
    context.navigation.go(place.pane, profileId: place.profileId, detail: place.detail)
    context.syncShown()
    for dark in [false, true] {
      let scheme = dark ? "dark" : "light"
      for (suffix, size) in [("", Snapshot.windowSize), ("-full", Snapshot.tallSize)] {
        await setup()
        try await Snapshot.render(SettingsWindowView(context: context), size: size, dark: dark, to: directory.appendingPathComponent("\(name)-\(scheme)\(suffix).png"))
      }
    }
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersPasswords() async throws {
    let directory = try #require(Snapshot.directory)
    let (model, services, _, context) = Self.fixture()
    let place = SettingsPlace(pane: .passwords)
    await model.prepare(place)
    try await Self.renderWindow(context, place, named: "passwords-locked")
    await model.unlock("default")
    try await Self.renderWindow(context, place, named: "passwords-unlocked") { await model.load("default") }
    services.applicationsFolder = false
    try await Self.renderWindow(context, place, named: "passwords-statuses") {
      await model.load("default")
      model.exportStatus = PasswordsText.exportMessage(services.exportResult)
      model.importStatus = "Imported 12 passwords."
      model.query = "zzz"
    }
    await model.unlock("work")
    try await Self.renderWindow(context, SettingsPlace(pane: .passwords, profileId: "work"), named: "passwords-work") { await model.load("work") }
    let saved = services.saved["default"]![0]
    for dark in [false, true] {
      let scheme = dark ? "dark" : "light"
      for (name, revealed, editing) in [("view", false, false), ("revealed", true, false), ("editing", false, true)] {
        let sheet = PasswordDetailSheet(model: model, profile: "default", saved: saved, revealed: revealed, editing: editing)
          .environment(\.settingsContext, context)
        try await Snapshot.render(sheet, size: NSSize(width: 440, height: 260), dark: dark, to: directory.appendingPathComponent("passwords-sheet-\(name)-\(scheme).png"))
      }
    }
    #expect(services.passwordCalls.allSatisfy { $0 == "https://github.com|owner" })
  }
}
