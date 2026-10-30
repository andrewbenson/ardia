import Foundation
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
private final class ScriptsHost: UserScriptsHost {
  var folder = UserScriptsFolder(state: "ready", generation: 1, path: "/private/tmp/data/Scripts/extension", token: "one")
  var saved: String?
  var statusReads = 0
  var heldStatusRead = false
  var statusGate: CheckedContinuation<Void, Never>?
  var statusFailure = false
  var hideInstalled = false
  var writes: [String] = []
  var watching: [Bool] = []
  var extensions: [String: [UserScriptsExtension]] = [:]
  var calls: [String] = []
  var warnings: [String] = []
  var failure: String?
  var writeFailure = false
  var heldInstall = false
  var installGate: CheckedContinuation<Void, Never>?
  var installed: UserScriptsExtension?
  var onRead: (() -> Void)?

  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
  }

  func watch(_ on: Bool) { watching.append(on) }
  func read() async throws -> UserScriptsFolder {
    onRead?()
    return folder
  }
  func readStatus() async throws -> String? {
    statusReads += 1
    if heldStatusRead { await withCheckedContinuation { statusGate = $0 } }
    if statusFailure { throw Failure("status unreadable") }
    return saved
  }
  func writeStatus(_ json: String) async throws {
    if writeFailure { throw Failure("disk full") }
    writes.append(json)
    saved = json
  }
  func list(_ profile: String) async throws -> [UserScriptsExtension] {
    if let failure { throw Failure(failure) }
    return extensions[profile] ?? []
  }
  func install(_ path: String, profile: String) async throws -> String {
    calls.append("install:\(profile)")
    if heldInstall { await withCheckedContinuation { installGate = $0 } }
    extensions[profile] = hideInstalled ? [] : [installed ?? UserScriptsExtension(id: "abc", path: path, enabled: true, state: "ENABLED")]
    return "abc"
  }
  func reload(_ id: String, profile: String) async throws { calls.append("reload:\(profile)") }
  func uninstall(_ id: String, profile: String) async throws {
    calls.append("uninstall:\(profile):\(id)")
    if let failure { throw Failure(failure) }
    extensions[profile]?.removeAll { $0.id == id }
  }
  func warn(_ message: String, error: any Error) { warnings.append(message) }

  func waitForInstall() async throws {
    for _ in 0..<1000 {
      if installGate != nil { return }
      await Task.yield()
    }
    throw Failure("install never started")
  }

  func releaseInstall() {
    heldInstall = false
    installGate?.resume()
    installGate = nil
  }

  var last: [String: Any] {
    guard let saved, let data = saved.data(using: .utf8) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  var profiles: [String: [String: Any]] { last["profiles"] as? [String: [String: Any]] ?? [:] }
}

@MainActor
@Suite struct UserScriptsTests {
  let personal = [UserScriptsTarget(engine: "", names: ["Personal"])]

  @Test func targetsUseOrderSharedDataAndJavaScriptTrimming() throws {
    let state = try BrowserState(stateJSON: [
      "profileOrder": ["default", "missing", "work", "shared", "blank", "incognito:w@work"],
      "profiles": [
        "default": ["id": "default", "name": "\u{feff}Personal\u{00a0}"],
        "work": ["id": "work", "name": "Personal"],
        "shared": ["id": "shared", "name": "Side", "dataId": "work"],
        "blank": ["id": "blank", "name": " \t"],
        "incognito:w@work": ["id": "incognito:w@work", "name": "Private"],
      ],
    ])
    #expect(UserScriptsSync.targets(state) == [
      UserScriptsTarget(engine: "", names: ["Personal"]),
      UserScriptsTarget(engine: "work", names: ["Personal (2)", "Side"]),
      UserScriptsTarget(engine: "blank", names: ["blank"]),
    ])
  }

  @Test func offDoesNothingAndOnLoadsOncePerEngine() async {
    let host = ScriptsHost()
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: false, targets: personal)
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.watching.isEmpty && host.calls.isEmpty && host.writes.isEmpty)
    let targets = personal + [UserScriptsTarget(engine: "work", names: ["Work", "Side"])]
    sync.sync(enabled: true, targets: targets)
    await sync.waitUntilIdle()
    #expect(host.watching == [true])
    #expect(host.calls == ["install:", "install:work"])
    #expect(host.profiles["Personal"]?["ok"] as? Bool == true)
    #expect(host.profiles["Side"]?["ok"] as? Bool == true)
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.calls.count == 2 && host.writes.count == 1)
  }

  @Test func newGenerationsReloadWhileDisabledCopiesStayDisabled() async {
    let host = ScriptsHost()
    host.extensions[""] = [UserScriptsExtension(id: "abc", path: "/tmp/data/Scripts/extension", enabled: false, state: "DISABLED")]
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.calls == ["reload:"])
    #expect(host.profiles["Personal"]?["disabled"] as? Bool == true)
    host.folder.generation = 2
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.calls == ["reload:", "reload:"])
  }

  @Test func policyBlockedCopiesAreInstalledAgainAndReportPolicyFailures() async {
    let host = ScriptsHost()
    let blocked = UserScriptsExtension(id: "abc", path: host.folder.path, enabled: false, state: "DISABLED", blockedByPolicy: true)
    host.extensions[""] = [blocked]
    host.installed = blocked
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:"])
    #expect(host.profiles["Personal"]?["error"] as? String == "Solara Scripts can only hold content scripts, and the engine blocked this copy.")
    host.installed = UserScriptsExtension(id: "abc", path: host.folder.path, enabled: false, state: "DISABLED")
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.profiles["Personal"]?["disabled"] as? Bool == true)
    #expect(host.calls == ["install:", "install:"])
  }

  @Test func invalidFoldersUnloadEveryMatchingCopyAndAlwaysRetry() async {
    let host = ScriptsHost()
    host.extensions[""] = [
      UserScriptsExtension(id: "a", path: "/tmp/data/Scripts/extension", enabled: true, state: "ENABLED"),
      UserScriptsExtension(id: "b", path: host.folder.path, enabled: true, state: "ENABLED"),
      UserScriptsExtension(id: "c", path: "/private/home/extension", enabled: true, state: "ENABLED"),
    ]
    host.folder.state = "invalid"
    host.folder.error = "manifest.json may not contain \"permissions\""
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.calls == ["uninstall::a", "uninstall::b"])
    #expect(host.extensions[""]?.map(\.id) == ["c"])
    #expect(host.profiles["Personal"]?["error"] as? String == host.folder.error)
    host.failure = "engine unavailable"
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.profiles["Personal"]?["error"] as? String == "manifest.json may not contain \"permissions\" (and the loaded copy couldn't be removed: engine unavailable)")
  }

  @Test func absentAndPresentAtTheSameGenerationDoDifferentWork() async {
    let host = ScriptsHost()
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    host.folder.state = "absent"
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:", "uninstall::abc"])
    #expect(host.profiles["Personal"]?["removed"] as? Bool == true)
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.calls.count == 2)
    host.folder.state = "ready"
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:", "uninstall::abc", "install:"])
  }

  @Test func newTargetsLoadAndRenamesOnlyRewriteStatus() async {
    let host = ScriptsHost()
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    sync.sync(enabled: true, targets: [UserScriptsTarget(engine: "", names: ["Renamed"]), UserScriptsTarget(engine: "work", names: ["Work", "Side"])])
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:", "install:work"])
    #expect(Set(host.profiles.keys) == Set(["Renamed", "Work", "Side"]))
    #expect(host.watching == [true, true])
  }

  @Test func busyPendingAndEmptyLeaveStatusUntouched() async {
    for state in ["busy", "pending", "empty"] {
      let host = ScriptsHost()
      host.folder.state = state
      let sync = UserScriptsSync(host: host, product: "Solara")
      sync.sync(enabled: true, targets: personal)
      await sync.waitUntilIdle()
      #expect(host.calls.isEmpty && host.writes.isEmpty)
    }
  }

  @Test func savedSuccessfulGenerationsSeedOnlyWhenSharedNamesAgree() async {
    let host = ScriptsHost()
    host.saved = "{\"generation\":1,\"profiles\":{\"Personal\":{\"disabled\":true},\"Side\":{\"disabled\":true}}}"
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: [UserScriptsTarget(engine: "", names: ["Personal", "Side"])])
    await sync.waitUntilIdle()
    #expect(host.calls.isEmpty)
    #expect(host.profiles["Side"]?["disabled"] as? Bool == true)
    let other = ScriptsHost()
    other.saved = "{\"generation\":1,\"profiles\":{\"Personal\":{\"ok\":true},\"Side\":{\"disabled\":true}}}"
    let otherSync = UserScriptsSync(host: other, product: "Solara")
    otherSync.sync(enabled: true, targets: [UserScriptsTarget(engine: "", names: ["Personal", "Side"])])
    await otherSync.waitUntilIdle()
    #expect(other.calls == ["install:"])
  }

  @Test func errorAndMalformedStatusDoNotSeedOrPreventLoading() async {
    for saved in ["invalid", "{\"generation\":1,\"profiles\":{\"Personal\":{\"error\":\"old\"}}}"] {
      let host = ScriptsHost()
      host.saved = saved
      let sync = UserScriptsSync(host: host, product: "Solara")
      sync.sync(enabled: true, targets: personal)
      await sync.waitUntilIdle()
      #expect(host.calls == ["install:"])
      #expect(host.profiles["Personal"]?["ok"] as? Bool == true)
    }
  }

  @Test func failedStatusWritesRetryWithoutRepeatingSuccessfulEngineWork() async {
    let host = ScriptsHost()
    host.writeFailure = true
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.writes.isEmpty && host.calls == ["install:"])
    host.writeFailure = false
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.writes.count == 1 && host.calls == ["install:"])
  }

  @Test func repeatedTriggersDuringInstallPublishOnlyTheNewestGeneration() async throws {
    let host = ScriptsHost()
    host.heldInstall = true
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    try await host.waitForInstall()
    host.folder.generation = 2
    host.folder.token = "two"
    sync.schedule()
    sync.schedule()
    host.releaseInstall()
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:", "install:"])
    #expect(host.writes.count == 1)
    #expect(host.last["generation"] as? Int == 2)
  }

  @Test func aSilentSwapInvalidatesTheCacheEvenWhenGenerationGoesBack() async throws {
    let host = ScriptsHost()
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    host.folder.generation = 2
    host.folder.token = "two"
    host.heldInstall = true
    sync.schedule()
    try await host.waitForInstall()
    host.folder.generation = 1
    host.folder.token = "one-again"
    host.releaseInstall()
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:", "install:", "install:"])
    #expect(host.last["generation"] as? Int == 1)
  }

  @Test func disablingDuringAnInstallDoesNotPublishOrStartAnotherProfile() async throws {
    let host = ScriptsHost()
    host.heldInstall = true
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal + [UserScriptsTarget(engine: "work", names: ["Work"])])
    try await host.waitForInstall()
    sync.sync(enabled: false, targets: [])
    host.releaseInstall()
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:"])
    #expect(host.writes.isEmpty)
    #expect(host.watching == [true, false])
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.calls.count == 1)
  }

  @Test func aTriggerDuringTheInitialReadDiscardsThatPass() async {
    let host = ScriptsHost()
    let sync = UserScriptsSync(host: host, product: "Solara")
    host.onRead = {
      host.onRead = nil
      host.folder.generation = 2
      sync.schedule()
    }
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:"])
    #expect(host.writes.count == 1)
    #expect(host.last["generation"] as? Int == 2)
  }

  @Test func statusUsesExactJavaScriptBytesAfterUnicodeEquivalentRename() async {
    let host = ScriptsHost()
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: [UserScriptsTarget(engine: "", names: ["é"])])
    await sync.waitUntilIdle()
    sync.sync(enabled: true, targets: [UserScriptsTarget(engine: "", names: ["e\u{301}"])])
    await sync.waitUntilIdle()
    #expect(host.writes.count == 2)
    #expect(host.calls == ["install:"])
    #expect(host.saved?.contains("e\u{301}") == true)
  }

  @Test func statusFormattingNumericNamesAndPrototypeSetterMatchJavaScript() async {
    let host = ScriptsHost()
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: [UserScriptsTarget(engine: "", names: ["10", "2", "__proto__", "Quoted\"", "Line\n"])])
    await sync.waitUntilIdle()
    let expected = """
      {
        "generation": 1,
        "profiles": {
          "2": {
            "ok": true
          },
          "10": {
            "ok": true
          },
          "Quoted\\\"": {
            "ok": true
          },
          "Line\\n": {
            "ok": true
          }
        }
      }
      """
    #expect(host.saved == expected)
  }

  @Test func savedAbsentOutcomeSeedsAndAnIdenticalStatusIsNotWritten() async {
    let host = ScriptsHost()
    host.folder.state = "absent"
    host.saved = "{\"generation\":1,\"profiles\":{\"Personal\":{\"removed\":true}}}"
    let first = UserScriptsSync(host: host, product: "Solara")
    first.sync(enabled: true, targets: personal)
    await first.waitUntilIdle()
    #expect(host.calls.isEmpty && host.writes.count == 1)
    let second = UserScriptsSync(host: host, product: "Solara")
    second.sync(enabled: true, targets: personal)
    await second.waitUntilIdle()
    #expect(host.calls.isEmpty && host.writes.count == 1)
  }

  @Test func failedSeedIsAttemptedOnlyOnceAndErrorsRemainRetryable() async {
    let host = ScriptsHost()
    host.statusFailure = true
    host.failure = "engine unavailable"
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.profiles["Personal"]?["error"] as? String == "engine unavailable")
    host.statusFailure = false
    host.failure = nil
    sync.schedule()
    await sync.waitUntilIdle()
    #expect(host.statusReads == 1)
    #expect(host.calls == ["install:"])
    #expect(host.warnings == ["[scripts] couldn't read status.json"])
  }

  @Test func loadReportsMissingStateAndPolicyMessagesExactly() async {
    for (extensionState, blocked, errors, missing, message) in [
      ("TERMINATED", false, [String](), false, "The extension is terminated."),
      ("DISABLED", true, ["first policy error", "second"], false, "first policy error"),
      ("ENABLED", false, [String](), true, "The extension didn't load."),
    ] {
      let host = ScriptsHost()
      host.installed = UserScriptsExtension(id: "abc", path: host.folder.path, enabled: false, state: extensionState, blockedByPolicy: blocked, errors: errors)
      host.hideInstalled = missing
      let sync = UserScriptsSync(host: host, product: "Solara")
      sync.sync(enabled: true, targets: personal)
      await sync.waitUntilIdle()
      #expect(host.profiles["Personal"]?["error"] as? String == message)
      #expect(host.calls == ["install:"])
    }
  }

  @Test func aRerunWithTheSameTokenSuppressesStaleNamesAndReusesSuccessfulWork() async throws {
    let host = ScriptsHost()
    host.heldInstall = true
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    try await host.waitForInstall()
    sync.sync(enabled: true, targets: [UserScriptsTarget(engine: "", names: ["Renamed"])])
    host.releaseInstall()
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:"])
    #expect(host.writes.count == 1)
    #expect(Set(host.profiles.keys) == Set(["Renamed"]))
  }

  @Test func anUnchangedMissingTokenIsStableAndNoTargetsStillPublishes() async {
    let host = ScriptsHost()
    host.folder.token = nil
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: [])
    await sync.waitUntilIdle()
    #expect(host.calls.isEmpty && host.writes.count == 1)
    #expect(host.profiles.isEmpty)
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:"])
  }

  @Test func settingsAndTargetsChangingDuringReadUseTheNextPass() async {
    let host = ScriptsHost()
    let sync = UserScriptsSync(host: host, product: "Solara")
    host.onRead = {
      host.onRead = nil
      sync.sync(enabled: false, targets: [])
    }
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.calls.isEmpty && host.writes.isEmpty)
    host.onRead = {
      host.onRead = nil
      sync.sync(enabled: true, targets: [UserScriptsTarget(engine: "work", names: ["Work"])])
    }
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:work"])
    #expect(Set(host.profiles.keys) == Set(["Work"]))
  }

  @Test func offOnRetriesBusyWithoutReseedingOrClearingAppliedWork() async {
    let host = ScriptsHost()
    host.folder.state = "busy"
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    host.folder.state = "ready"
    sync.sync(enabled: false, targets: personal)
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.watching == [true, false, true])
    #expect(host.calls == ["install:"])
    #expect(host.statusReads == 1)
    sync.sync(enabled: false, targets: personal)
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:"])
    #expect(host.writes.count == 1)
  }

  @Test func blockedFallbackTrimsProductAndUsesTheOriginalDefault() async {
    for (product, expected) in [(" \u{feff}Solara\u{a0}", "Solara"), (" \t", "Ardia")] {
      let host = ScriptsHost()
      host.installed = UserScriptsExtension(id: "abc", path: host.folder.path, enabled: false, state: "DISABLED", blockedByPolicy: true)
      let sync = UserScriptsSync(host: host, product: product)
      sync.sync(enabled: true, targets: personal)
      await sync.waitUntilIdle()
      #expect(host.profiles["Personal"]?["error"] as? String == "\(expected) Scripts can only hold content scripts, and the engine blocked this copy.")
    }
  }

  @Test func numericEngineIdsKeepMapInsertionOrderAndLiteralNamesKeepCollisions() throws {
    let state = try BrowserState(stateJSON: [
      "profileOrder": ["10", "2", "literal", "shared"],
      "profiles": [
        "10": ["id": "10", "name": "Same"],
        "2": ["id": "2", "name": "Same"],
        "literal": ["id": "literal", "name": "Same (2)"],
        "shared": ["id": "shared", "name": "Side", "dataId": "10"],
      ],
    ])
    #expect(UserScriptsSync.targets(state) == [
      UserScriptsTarget(engine: "10", names: ["Same", "Side"]),
      UserScriptsTarget(engine: "2", names: ["Same (2)"]),
      UserScriptsTarget(engine: "literal", names: ["Same (2)"]),
    ])
  }

  @Test func tokenComparisonUsesExactJavaScriptCodeUnits() async throws {
    let host = ScriptsHost()
    host.folder.token = "é"
    host.heldInstall = true
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    try await host.waitForInstall()
    host.folder.token = "e\u{301}"
    host.releaseInstall()
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:", "install:"])
    #expect(host.writes.count == 1)
  }

  @Test func disablingDuringSeedStillRemembersTheSavedGenerationOnReenable() async throws {
    let host = ScriptsHost()
    host.saved = "{\"generation\":1,\"profiles\":{\"Personal\":{\"ok\":true}}}"
    host.heldStatusRead = true
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: personal)
    for _ in 0..<1000 {
      if host.statusGate != nil { break }
      await Task.yield()
    }
    guard let gate = host.statusGate else { throw ScriptsHost.Failure("status read never started") }
    sync.sync(enabled: false, targets: personal)
    host.heldStatusRead = false
    gate.resume()
    host.statusGate = nil
    await sync.waitUntilIdle()
    #expect(host.calls.isEmpty && host.writes.isEmpty)
    sync.sync(enabled: true, targets: personal)
    await sync.waitUntilIdle()
    #expect(host.calls.isEmpty)
    #expect(host.statusReads == 1)
    #expect(host.profiles["Personal"]?["ok"] as? Bool == true)
  }

  @Test func aTruthyPrimitiveSeedOutcomeStopsSeedingButDoesNotStopLoading() async {
    let host = ScriptsHost()
    host.saved = "{\"generation\":1,\"profiles\":{\"0\":true}}"
    let sync = UserScriptsSync(host: host, product: "Solara")
    sync.sync(enabled: true, targets: [UserScriptsTarget(engine: "", names: ["0"])])
    await sync.waitUntilIdle()
    #expect(host.calls == ["install:"])
    #expect(host.warnings == ["[scripts] couldn't read status.json"])
  }

  @Test func nonobjectProfilesDoNotSeed() async {
    for profiles in ["null", "false", "true", "0", "42", "\"text\"", "[]", "[{\"disabled\":true}]"] {
      let host = ScriptsHost()
      host.saved = "{\"generation\":1,\"profiles\":\(profiles)}"
      let sync = UserScriptsSync(host: host, product: "Solara")
      sync.sync(enabled: true, targets: [UserScriptsTarget(engine: "", names: ["0"])])
      await sync.waitUntilIdle()
      #expect(host.calls == ["install:"])
      #expect(host.profiles["0"]?["ok"] as? Bool == true)
      #expect(host.warnings.isEmpty)
    }
  }

  @Test func prototypeNamesSeedOnlyFromExplicitObjectProperties() async {
    for name in ["__proto__", "constructor", "toString", "length"] {
      for explicit in [false, true] {
        let host = ScriptsHost()
        let profiles = explicit ? "{\"\(name)\":{\"disabled\":true}}" : "{}"
        host.saved = "{\"generation\":1,\"profiles\":\(profiles)}"
        let sync = UserScriptsSync(host: host, product: "Solara")
        sync.sync(enabled: true, targets: [UserScriptsTarget(engine: "", names: [name])])
        await sync.waitUntilIdle()
        #expect(host.calls == (explicit ? [] : ["install:"]))
        if name == "__proto__" { #expect(host.profiles.isEmpty) }
        else { #expect(host.profiles[name]?[explicit ? "disabled" : "ok"] as? Bool == true) }
      }
    }
  }

}
