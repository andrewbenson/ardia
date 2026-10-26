import AppKit
import Foundation
import Observation
import SolaraModel
import SwiftUI

@MainActor
@Observable
public final class OnboardingModel {
  @ObservationIgnored public let services: OnboardingServices
  @ObservationIgnored public let store: SettingsStoreSource
  @ObservationIgnored public let diagnostics: DiagnosticsSharingServices?
  @ObservationIgnored public var powerUpView: ((PowerUpSpec) -> AnyView)?
  @ObservationIgnored public var settled = false
  public let copy: OnboardingCopy
  public var appIcon: NSImage?

  public private(set) var windowId: String?
  public private(set) var step: OnboardingStep = .intro
  public private(set) var sub = 0
  public private(set) var leaving = false
  public private(set) var session = 0
  public private(set) var tourAfter = false
  public private(set) var preset: OnboardingPreset = .dia
  public private(set) var source: BrowserSourceId?
  public private(set) var draft: JSONObject = [:]
  public private(set) var extras = OnboardingExtras()
  public private(set) var baseline: JSONObject = [:]
  public private(set) var picked: [OnboardingQuestion: [String]] = [:]
  var settingsRevision = 0

  public var system: OnboardingSystemState?
  public var busy = false
  public var icons: [OnboardingAppIcon] = []
  public var currentIcon: String?
  public var sourceTiles: [BrowserSourceTile] = []
  public var importing: BrowserSourceId?
  public var introMuted = false

  public init(services: OnboardingServices, store: SettingsStoreSource, diagnostics: DiagnosticsSharingServices?, appName: String, appIcon: NSImage? = nil) {
    self.services = services
    self.store = store
    self.diagnostics = diagnostics
    copy = OnboardingCopy(product: appName)
    self.appIcon = appIcon
  }

  public var isActive: Bool { windowId != nil }
  public func isActive(in windowId: String) -> Bool { self.windowId == windowId }

  public func questions(for step: OnboardingStep) -> [OnboardingQuestion] {
    _ = settingsRevision
    let list = OnboardingQuestion.all(in: step)
    if step == .searchPrivacy && !(diagnostics?.available ?? false) { return list.filter { $0 != .crash } }
    if step != .layout { return list }
    return resolve(["tabLayout"])["tabLayout"]?.string == "top" ? list.filter { $0 != .address } : list
  }

  public var question: OnboardingQuestion? {
    let list = questions(for: step)
    return list.indices.contains(sub) ? list[sub] : nil
  }

  public var isFirstPage: Bool { step.advanced(by: -1) == .intro && sub == 0 }

  func base(_ key: String) -> JSONValue {
    if key == "tabLayout" { return .string(services.windowTabLayout(windowId)) }
    return store.settingValue(key) ?? .null
  }

  public func resolve(_ keys: [String]) -> JSONObject {
    _ = settingsRevision
    let presetValues = preset.settings
    let chosen = store.settingValue("chosen")?.array?.compactMap(\.string) ?? []
    var out: JSONObject = [:]
    for key in keys {
      if let drafted = draft[key] {
        out[key] = drafted
      } else if let presetValue = presetValues[key], !chosen.contains(key) {
        out[key] = presetValue
      } else {
        out[key] = base(key)
      }
    }
    return out
  }

  public func value(_ key: String) -> JSONValue { resolve([key])[key] ?? .null }
  public func string(_ key: String) -> String { value(key).string ?? "" }
  public func bool(_ key: String) -> Bool { value(key).truthy }

  public func mock(_ keys: [String]) -> MockSettings {
    let values = resolve(keys)
    func pick(_ key: String) -> JSONValue { values[key] ?? base(key) }
    return MockSettings(
      tabLayout: pick("tabLayout").string ?? "sidebar",
      addressBar: pick("addressBar").string ?? "toolbar",
      appearance: pick("appearance").string ?? "auto",
      extendWebsiteColor: pick("extendWebsiteColor").bool ?? true
    )
  }

  public var accent: String {
    _ = settingsRevision
    guard let windowId, let color = services.profileColor(windowId) else { return ProfileColorValue.plum.swatch }
    return color.swatch
  }

  public func go(_ step: OnboardingStep, sub: Int = 0) {
    self.step = step
    self.sub = sub
    save(["step": .string(step.rawValue), "sub": .number(Double(sub))])
  }

  public func next() {
    if sub < questions(for: step).count - 1 { return go(step, sub: sub + 1) }
    if let after = step.advanced(by: 1) {
      go(after)
    } else {
      finish()
    }
  }

  public func back() {
    if sub > 0 { return go(step, sub: sub - 1) }
    if let before = step.advanced(by: -1), before != .intro {
      go(before, sub: max(0, questions(for: before).count - 1))
    }
  }

  public func chooseSource(_ source: BrowserSourceId?) {
    let preset = OnboardingPreset.forSource(source)
    self.source = source
    self.preset = preset
    save(["source": JSONValue(source?.rawValue), "preset": .string(preset.rawValue)])
  }

  public func setDraft(_ patch: JSONObject) {
    for (key, value) in patch { draft[key] = value }
  }

  public func setExtras(_ change: (inout OnboardingExtras) -> Void) {
    change(&extras)
  }

  public func previewLive(_ patch: JSONObject) {
    var recorded = baseline
    for key in patch.keys where !recorded.contains(key) {
      recorded[key] = base(key)
    }
    baseline = recorded
    var rest = patch
    let tabLayout = rest.removeValue(forKey: "tabLayout")
    if let layout = tabLayout?.string, !layout.isEmpty, let windowId { services.setWindowTabLayout(windowId, layout) }
    if !rest.isEmpty { services.previewSettings(rest) }
    settingsRevision += 1
  }

  public func previewColor(_ color: ProfileColorValue) {
    guard let windowId, let current = services.profileColor(windowId) else { return }
    if !baseline.contains("color") { baseline["color"] = .string(current.rawValue) }
    services.setProfileColor(windowId, color)
    settingsRevision += 1
  }

  public func confirm(_ question: OnboardingQuestion, patch: JSONObject, picked lines: [String]) {
    if let layout = patch["tabLayout"]?.string, !layout.isEmpty, let windowId { services.setWindowTabLayout(windowId, layout) }
    if !patch.isEmpty { store.updateSettings(patch) }
    var kept = baseline
    for key in patch.keys { _ = kept.removeValue(forKey: key) }
    if question == .color { _ = kept.removeValue(forKey: "color") }
    picked[question] = lines
    baseline = kept
    settingsRevision += 1
    save(["picked": pickedJSON])
    next()
  }

  public func skip() {
    let rest = Array(questions(for: step).dropFirst(sub))
    let keys = rest.flatMap(\.keys)
    revertLive(keys + (rest.contains(.color) ? ["color"] : []))
    for key in keys { _ = draft.removeValue(forKey: key) }
    if let after = step.advanced(by: 1) {
      go(after)
    } else {
      finish()
    }
  }

  func revertLive(_ keys: [String]) {
    var restore: JSONObject = [:]
    for key in keys { if let value = baseline[key] { restore[key] = value } }
    if restore.isEmpty { return }
    let color = restore.removeValue(forKey: "color")
    let tabLayout = restore.removeValue(forKey: "tabLayout")
    if let layout = tabLayout?.string, !layout.isEmpty, let windowId { services.setWindowTabLayout(windowId, layout) }
    if !restore.isEmpty { services.previewSettings(restore) }
    if let name = color?.string, let value = ProfileColorValue(rawValue: name), let windowId { services.setProfileColor(windowId, value) }
    var kept = baseline
    for key in keys { _ = kept.removeValue(forKey: key) }
    baseline = kept
    settingsRevision += 1
  }

  public func finish(tour: Bool = false) {
    revertLive(baseline.keys)
    save(["completedAt": .number(services.now())])
    services.stopIntroMusic(fade: 0.6)
    if windowId != nil {
      leaving = true
      tourAfter = tour
    }
  }

  public func dismiss(session: Int) {
    guard session == self.session else { return }
    let windowId = self.windowId
    let tour = tourAfter
    self.windowId = nil
    step = .intro
    leaving = false
    tourAfter = false
    if tour, let windowId { services.startToolTour(windowId) }
  }

  private func reset() {
    preset = .dia
    source = nil
    draft = [:]
    extras = OnboardingExtras()
    baseline = [:]
    picked = [:]
    system = nil
    busy = false
    importing = nil
    leaving = false
    tourAfter = false
    sub = 0
  }

  public func start(windowId: String? = nil, step: OnboardingStep = .intro) {
    guard let id = services.resolveWindowId(windowId) else { return }
    services.endToolTour()
    reset()
    self.windowId = id
    self.step = step
    session += 1
    introMuted = introMusicMuted
    save(["step": .string(step.rawValue), "sub": 0, "source": nil, "preset": "dia", "picked": [:]])
  }

  func resume(_ saved: JSONObject) {
    guard let id = services.resolveWindowId(nil) else { return }
    let savedStep = saved["step"]?.string.flatMap(OnboardingStep.init(rawValue:))
    let step = savedStep.flatMap { $0 == .intro ? nil : $0 } ?? .source
    let source = saved["source"]?.string.flatMap(BrowserSourceId.init(rawValue:))
    reset()
    windowId = id
    self.step = step
    self.source = source
    preset = saved["preset"]?.string.flatMap(OnboardingPreset.init(rawValue:)) ?? OnboardingPreset.forSource(source)
    picked = Self.pickedFrom(saved["picked"])
    session += 1
    introMuted = introMusicMuted
    let sub = min(saved["sub"]?.int ?? 0, questions(for: step).count - 1)
    if sub > 0 { self.sub = sub }
  }

  public func maybeStart() {
    let saved = readSaved()
    if saved?["completedAt"]?.truthy == true { return }
    if let saved, saved["startedAt"]?.truthy == true { return resume(saved) }
    if services.hasSessionDocument() { return save(["completedAt": .number(services.now())]) }
    if !services.startsOnFirstLaunch { return }
    save(["startedAt": .number(services.now())])
    start()
  }

  public var completedAt: Double? { readSaved()?["completedAt"]?.number }
  public var introMusicMuted: Bool { readSaved()?["introMusicMuted"]?.bool ?? false }
  public var defaultBrowserTrialStartedAt: Double? { readSaved()?["defaultBrowserTrialStartedAt"]?.number }
  public var defaultBrowserCheckInDoneAt: Double? { readSaved()?["defaultBrowserCheckInDoneAt"]?.number }
  public func recordDefaultBrowserTrial() { save(["defaultBrowserTrialStartedAt": .number(services.now())]) }
  public func recordDefaultBrowserCheckInDone() { save(["defaultBrowserCheckInDoneAt": .number(services.now())]) }

  public func toggleIntroMute() {
    introMuted.toggle()
    services.setIntroMusicMuted(introMuted)
    save(["introMusicMuted": .bool(introMuted)])
  }

  var pickedJSON: JSONValue {
    var object: JSONObject = [:]
    for question in OnboardingQuestion.allCases { if let lines = picked[question] { object[question.rawValue] = JSONValue(lines) } }
    return .object(object)
  }

  static func pickedFrom(_ value: JSONValue?) -> [OnboardingQuestion: [String]] {
    var out: [OnboardingQuestion: [String]] = [:]
    for (key, lines) in value?.object ?? [:] {
      if let question = OnboardingQuestion(rawValue: key) { out[question] = lines.array?.compactMap(\.string) ?? [] }
    }
    return out
  }

  public var pickedLines: [String] { OnboardingQuestion.order.flatMap { picked[$0] ?? [] } }

  func readSaved() -> JSONObject? { OnboardingDocument.parse(services.readOnboardingDocument()) }

  func save(_ patch: JSONObject) {
    services.writeOnboardingDocument(OnboardingDocument.stringify(.object(OnboardingDocument.merged(readSaved(), patch))))
  }

  public func refreshSettings() { settingsRevision += 1 }
}

public struct MockSettings: Equatable, Sendable {
  public var tabLayout: String
  public var addressBar: String
  public var appearance: String
  public var extendWebsiteColor: Bool

  public init(tabLayout: String = "sidebar", addressBar: String = "toolbar", appearance: String = "auto", extendWebsiteColor: Bool = true) {
    self.tabLayout = tabLayout
    self.addressBar = addressBar
    self.appearance = appearance
    self.extendWebsiteColor = extendWebsiteColor
  }

  public var top: Bool { tabLayout == "top" }
  public var addressInSidebar: Bool { !top && addressBar == "sidebar" }
}
