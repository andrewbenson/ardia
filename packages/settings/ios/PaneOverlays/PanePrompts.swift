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

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativePanePrompts, defaultOn: false)
  }

  static func start() {
    guard enabled, NativeWindowShell.enabled, !started else { return }
    started = true
    TabPoolHost.shared.pageEventObservers.append { tabId, name, payload in pageEvent(tabId, name, payload) }
    _ = SettingsJS.shared.observe(topic) { value in applyThemes(value) }
    applyThemes(SettingsJS.shared.latestValue(topic))
  }

  static func owns(_ tabId: String) -> Bool { started && TabPoolHost.shared.pageView(tabId) != nil }

  static func sadTabs(in windowId: String) -> [String] {
    pages.compactMap { tabId, page in page.sadMode != nil && TabPoolHost.shared.windowOf(tabId) == windowId ? tabId : nil }
  }

  static func pageEvent(_ tabId: String, _ name: String, _ payload: [String: Any]) {
    if name == "onPageGone" {
      guard let gone = pages.removeValue(forKey: tabId), gone.sadMode != nil else { return }
      return refreshAll()
    }
    var page = pages[tabId] ?? PanePromptPage()
    let shown = page.sadMode
    guard page.take(name, payload) else { return pages[tabId] = page }
    pages[tabId] = page
    if page.sadMode != shown { changed(tabId) }
  }

  static func sadTabAction(_ windowId: String, _ tabId: String, _ action: SadTabAction) {
    if var page = pages[tabId] {
      if action == .reload { page.crashed = false } else { page.unresponsive = false }
      pages[tabId] = page
      changed(tabId)
    }
    Task { @MainActor in _ = await SettingsAdapters.js("pane.sadTab", windowId, tabId, action.rawValue) }
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
