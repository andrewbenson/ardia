import AppKit
import ArdiaShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class NativeAppStartup {
  static let shared = NativeAppStartup()
  private var installed = false
  private var result: String?
  private var completed = false
  private var offered = false
  private var updated = false
  private var development = false
  private var presentation: (([String: Any]) -> Void)?
  private var pending: [[String: Any]] = []

  private init() {}

  func install() {
    guard !installed else { return }
    installed = true
    for command in ["showOnboarding", "toolTour", "videoTour", "releaseNotes"] {
      NativeMenuCommands.handlers[command] = { windowId in _ = Self.shared.perform(command, windowId: windowId) }
    }
  }

  func start(_ options: [String: Any], presentation: @escaping ([String: Any]) -> Void) -> String {
    install()
    self.presentation = presentation
    development = options["development"] as? Bool ?? false
    let refused = options["persistenceRefused"] as? Bool ?? true
    let safeMode = options["safeMode"] as? Bool ?? true
    let version = AppModule.systemInfo["appVersion"] as? String ?? ""
    let versions = Set(options["releaseNotesVersions"] as? [String] ?? [])
    let hasSession = !(DocumentStore.read("session.json") ?? "").isEmpty
    let hosted = options["hostedOnboarding"] as? Bool ?? false
    if !hosted { NSLog("[appIntegration] automatic onboarding unavailable: native onboarding host is off") }
    if result != nil {
      let saved = read("onboarding.json")
      let decision = AppStartupPolicy.onboarding(
        saved: saved, hasSession: hasSession, refused: refused, safeMode: safeMode,
        hosted: hosted, development: development, force: Self.debugEnvironment("ARDIA_ONBOARDING"))
      let pending = AppStartupPolicy.version(
        current: version, saved: read("release-notes.json"), hasSession: hasSession, refused: refused,
        safeMode: true, development: true, forcePostcard: false, now: Self.now, knownVersions: versions).pending
      return JSONValue.object([
        "pendingJSON": !version.isEmpty && !refused ? .string(pending.text()) : .null,
        "onboarding": .string(decision == .resume ? "resume" : "none"),
        "savedJSON": saved.map { .string($0.text()) } ?? .null,
      ]).text()
    }
    let tracked = AppStartupPolicy.version(
      current: version, saved: read("release-notes.json"), hasSession: hasSession, refused: refused,
      safeMode: safeMode, development: development, forcePostcard: Self.debugEnvironment("ARDIA_WHATS_NEW"),
      now: Self.now, knownVersions: versions)
    updated = tracked.updated
    if let document = tracked.document { save("release-notes.json", document) }
    let saved = read("onboarding.json")
    let onboarding = AppStartupPolicy.onboarding(
      saved: saved, hasSession: hasSession, refused: refused, safeMode: safeMode,
      hosted: hosted,
      development: development, force: Self.debugEnvironment("ARDIA_ONBOARDING"))
    var action = "none"
    switch onboarding {
    case .none: break
    case .start:
      save("onboarding.json", AppStartupPolicy.onboardingDocument(saved: saved, patch: ["startedAt": .number(Self.now)]))
      action = "start"
    case .resume: action = "resume"
    case .complete:
      save("onboarding.json", AppStartupPolicy.onboardingDocument(saved: saved, patch: ["completedAt": .number(Self.now)]))
    }
    let payload: JSONObject = [
      "pendingJSON": !version.isEmpty && !refused ? .string(tracked.pending.text()) : .null,
      "onboarding": .string(action), "savedJSON": saved.map { .string($0.text()) } ?? .null,
    ]
    let result = JSONValue.object(payload).text()
    self.result = result
    return result
  }

  func complete() {
    guard result != nil else { return NSLog("[appIntegration] presentation completed before startup") }
    let first = !completed
    completed = true
    let waiting = pending
    pending = []
    for event in waiting { emit(event) }
    guard first, AppStartupPolicy.opensReleaseNotes(
      updated: updated, development: development, isolated: Self.isolated, force: AppModule.systemInfo["forceReleaseNotes"] as? Bool ?? false)
    else { return }
    _ = perform("releaseNotes", windowId: nil)
  }

  func disconnect() {
    presentation = nil
  }

  func perform(_ command: String, windowId: String?) -> Bool {
    switch command {
    case "showOnboarding", "toolTour":
      emit(["action": command, "windowId": windowId as Any? ?? NSNull()])
    case "videoTour":
      if let url = AppStartupPolicy.videoURL(page: AppModule.systemInfo["videoTourURL"] as? String) { open(url, windowId: windowId) }
    case "releaseNotes":
      if let url = AppStartupPolicy.releaseNotesURL(
        page: AppModule.systemInfo["releaseNotesURL"] as? String, version: AppModule.systemInfo["appVersion"] as? String ?? "")
      { open(url, windowId: windowId) }
    default: return false
    }
    return true
  }

  func firstWindow(onboardingActive: Bool) async throws {
    guard !offered else { return }
    offered = true
    let saved = read("default-browser-offer.json")
    guard AppStartupPolicy.defaultOffer(saved: saved, testInstance: Self.isolated) == .eligible, let saved else { return }
    let onboarding = !(read("onboarding.json")?["completedAt"]?.truthy ?? false) || onboardingActive
    let isDefault = onboarding ? false : SystemServices.isDefaultBrowser()
    let offer = AppStartupPolicy.completeDefaultOffer(saved: saved, onboarding: onboarding, isDefault: isDefault, now: Self.now)
    try await saveDurably("default-browser-offer.json", offer.document)
    if offer.requestDefault { _ = await SettingsAdapters.setAsDefaultBrowser() }
  }

  func notification(action: String, tabId: String?, windowId: String?) {
    guard action == "click" else { return }
    guard let store = workspace else { return unavailable("notification click") }
    let writer = StoreWorkspaceWriter(store: store, showWindow: ShellScripting.showWindow)
    switch AppStartupPolicy.notificationTarget(state: store.state, action: action, tabId: tabId, windowId: windowId) {
    case .none: break
    case .tab(let id):
      let window = store.state.tabs[id]?.windowId
      writer.activate(id)
      if let window, window != store.state.ui.focusedWindowId { writer.focusWindow(window) }
    case .window(let id): writer.focusWindow(id)
    }
  }

  private var workspace: Store? {
    guard NativeStoreHandle.opened, NativeStoreHandle.ownedWorkspaceAtLaunch, NativeStoreHandle.ownsWorkspace else { return nil }
    return NativeStoreHandle.store
  }

  private func open(_ url: String, windowId: String?) {
    guard let store = workspace else {
      unavailable("opening help URL through JS")
      return emit(["action": "openURL", "url": url, "windowId": windowId as Any? ?? NSNull()])
    }
    do {
      let state = store.state
      if let target = state.resolveWindowId(windowId), state.windows[target]?.incognito != true {
        _ = try store.dispatch(Command("newTab", [.string(target), ["url": .string(url)]]), origin: .native)
      } else {
        _ = try store.dispatch(Command("createWindow", [["url": .string(url)]]), origin: .native)
      }
    } catch {
      NSLog("[appIntegration] opening help URL failed: %@", String(describing: error))
    }
  }

  private func unavailable(_ action: String) {
    let reason = NativeSettingsHandle.unavailable?.detail ?? (NativeStoreHandle.opened ? "workspace is not owned or available" : "store is not open")
    NSLog("[appIntegration] %@: %@", action, reason)
  }

  private func emit(_ event: [String: Any]) {
    guard completed, let presentation else {
      guard pending.count < 50 else { return NSLog("[appIntegration] JS presentation unavailable; action queue is full") }
      pending.append(event)
      NSLog("[appIntegration] waiting for JS presentation: %@", event["action"] as? String ?? "unknown")
      return
    }
    presentation(event)
  }

  private func read(_ name: String) -> JSONValue? {
    DocumentStore.read(name).flatMap { try? JSONValue.parse($0) }
  }

  private func save(_ name: String, _ document: JSONObject) {
    do { try DocumentStore.write(name, JSONValue.object(document).text()) }
    catch { NSLog("[appIntegration] couldn't save %@: %@", name, String(describing: error)) }
  }

  private func saveDurably(_ name: String, _ document: JSONObject) async throws {
    let text = JSONValue.object(document).text()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      do {
        try DocumentStore.write(name, text) { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      } catch { continuation.resume(throwing: error) }
    }
  }

  private static var now: Double { floor(Date().timeIntervalSince1970 * 1000) }
  private static var isolated: Bool { AppModule.systemInfo["isolatedInstance"] as? Bool != false }

  private static func debugEnvironment(_ name: String) -> Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment[name] == "1"
    #else
    false
    #endif
  }
}
