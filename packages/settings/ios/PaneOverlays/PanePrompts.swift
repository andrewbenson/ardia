import AppKit
import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum PanePrompts {
  nonisolated static let kind = "panePrompts"
  static let topic = "pane.prompts"
  private static var started = false
  private static var pages: [String: PanePromptPage] = [:]
  private static var themes: [String: [String: Any]] = [:]
  private(set) static var activatedAt: TimeInterval = 0

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativePanePrompts, defaultOn: false)
  }

  static func start() {
    guard enabled, NativeWindowShell.enabled, !started else { return }
    started = true
    TabPoolHost.shared.pageEventObservers.append { tabId, name, payload in pageEvent(tabId, name, payload) }
    for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { activatedAt = ProcessInfo.processInfo.systemUptime }
      }
    }
    _ = SettingsJS.shared.observe(topic) { value in applyThemes(value) }
    applyThemes(SettingsJS.shared.latestValue(topic))
  }

  static func owns(_ tabId: String) -> Bool { started && TabPoolHost.shared.pageView(tabId) != nil }

  static func sadTabs(in windowId: String) -> [String] {
    pages.compactMap { tabId, page in page.sadMode != nil && TabPoolHost.shared.windowOf(tabId) == windowId ? tabId : nil }
  }

  static func passwordTabs(in windowId: String) -> [String] {
    pages.compactMap { tabId, page in page.password != nil && TabPoolHost.shared.windowOf(tabId) == windowId ? tabId : nil }
  }

  static func holds(_ windowId: String) -> Bool { !sadTabs(in: windowId).isEmpty || !passwordTabs(in: windowId).isEmpty }

  static func pageEvent(_ tabId: String, _ name: String, _ payload: [String: Any]) {
    if name == "onPageGone" {
      guard let gone = pages.removeValue(forKey: tabId), gone.shown != PanePromptPage().shown else { return }
      return refreshAll()
    }
    var page = pages[tabId] ?? PanePromptPage()
    let shown = page.shown
    guard page.take(name, payload) else { return pages[tabId] = page }
    pages[tabId] = page
    if page.shown != shown { changed(tabId) }
  }

  static func sadTabAction(_ windowId: String, _ tabId: String, _ action: SadTabAction) {
    if var page = pages[tabId] {
      if action == .reload { page.crashed = false } else { page.unresponsive = false }
      pages[tabId] = page
      changed(tabId)
    }
    Task { @MainActor in _ = await SettingsAdapters.js("pane.sadTab", windowId, tabId, action.rawValue) }
  }

  static func password(_ windowId: String, _ tabId: String) -> (key: String, json: String)? {
    guard owns(tabId), let page = pages[tabId], let prompt = page.password, let look = (themes[windowId]?["prompt"] as? [String: Any]) else { return nil }
    let spec = PanePromptSpecs.password(prompt, chosen: page.chosenUsername).merging(look) { _, theme in theme }
    guard let data = try? JSONSerialization.data(withJSONObject: spec), let json = String(data: data, encoding: .utf8) else { return nil }
    return (prompt.key, json)
  }

  static func choosePassword(_ tabId: String, _ username: String) {
    guard var page = pages[tabId], page.password != nil else { return }
    page.chosenUsername = username
    pages[tabId] = page
    changed(tabId)
  }

  static func answerPassword(_ windowId: String, _ tabId: String, _ action: String) {
    guard var page = pages[tabId], let prompt = page.password else { return }
    let username = page.chosenUsername ?? prompt.username
    page.password = nil
    page.chosenUsername = nil
    pages[tabId] = page
    changed(tabId)
    Task { @MainActor in _ = await SettingsAdapters.js("pane.password", windowId, tabId, action, username) }
  }

  static func sadTab(_ windowId: String, _ tabId: String) -> SadTabState? {
    guard owns(tabId), let mode = pages[tabId]?.sadMode, let theme = themes[windowId] else { return nil }
    var object = theme
    object["mode"] = mode.rawValue
    guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return nil }
    return SadTabState.decode(json)
  }

  private static func changed(_ tabId: String) {
    guard let windowId = TabPoolHost.shared.windowOf(tabId) else { return refreshAll() }
    NativePaneOverlays.refresh(windowId)
  }

  private static func refreshAll() {
    for windowId in Set(themes.keys) { NativePaneOverlays.refresh(windowId) }
  }

  private static func applyThemes(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    themes = windows.compactMapValues { ($0 as? [String: Any])?["theme"] as? [String: Any] }
    refreshAll()
  }
}
