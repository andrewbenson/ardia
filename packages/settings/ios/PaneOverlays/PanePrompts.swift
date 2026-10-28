import AppKit
import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum PanePrompts {
  struct Shown {
    let tabId: String
    let kind: PanePromptKind
    let key: String
    let json: String
  }

  nonisolated static let kind = "panePrompts"
  static let topic = "pane.prompts"
  private static var started = false
  private static var pages: [String: PanePromptPage] = [:]
  private static var windows: [String: [String: Any]] = [:]
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
    _ = SettingsJS.shared.observe(topic) { value in applyWindows(value) }
    applyWindows(SettingsJS.shared.latestValue(topic))
  }

  static func owns(_ tabId: String) -> Bool { started && TabPoolHost.shared.pageView(tabId) != nil }

  private static func tabs(in windowId: String, where test: (PanePromptPage) -> Bool) -> [String] {
    pages.compactMap { tabId, page in test(page) && TabPoolHost.shared.windowOf(tabId) == windowId ? tabId : nil }
  }

  static func sadTabs(in windowId: String) -> [String] { tabs(in: windowId) { $0.sadMode != nil } }

  static func holds(_ windowId: String) -> Bool { !tabs(in: windowId) { $0.shown != PanePromptPage().shown }.isEmpty }

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
    js("pane.sadTab", windowId, tabId, action.rawValue)
  }

  static func sadTab(_ windowId: String, _ tabId: String) -> SadTabState? {
    guard owns(tabId), let mode = pages[tabId]?.sadMode, let theme = windows[windowId]?["theme"] as? [String: Any] else { return nil }
    var object = theme
    object["mode"] = mode.rawValue
    return encode(object).flatMap(SadTabState.decode)
  }

  static func prompts(in windowId: String, paneWidth: (String) -> Double?) -> [Shown] {
    guard let window = windows[windowId], let look = (window["theme"] as? [String: Any])?["prompt"] as? [String: Any] else { return [] }
    let panes = window["panes"] as? [String: [String: Any]] ?? [:]
    var shown: [Shown] = []
    let asking = Set(tabs(in: windowId, where: { $0.password != nil || $0.autofill != nil || $0.externalApp != nil }))
    for tabId in asking.union(panes.compactMap { $0.value["popups"] is [String: Any] ? $0.key : nil }).sorted() where owns(tabId) {
      let page = pages[tabId] ?? PanePromptPage()
      let pane = panes[tabId] ?? [:]
      func add(_ kind: PanePromptKind, _ key: String, _ spec: [String: Any]) {
        if let json = encode(spec.merging(look) { _, theme in theme }) { shown.append(Shown(tabId: tabId, kind: kind, key: key, json: json)) }
      }
      if let prompt = page.password { add(.password, prompt.key, PanePromptSpecs.password(prompt, chosen: page.chosenUsername)) }
      if let prompt = page.autofill { add(.autofill, prompt.key, PanePromptSpecs.autofill(prompt)) }
      if let request = page.externalApp, pane["newTabShown"] as? Bool != true {
        let left = PanePromptSpecs.externalAppLeft(urlLeft: (pane["urlLeft"] as? NSNumber)?.doubleValue ?? 0, paneWidth: paneWidth(tabId) ?? 0)
        add(.externalApp, request.key, PanePromptSpecs.externalApp(request, always: page.alwaysOpen, left: left))
      }
      if let hint = pane["popups"] as? [String: Any], let popups = PanePromptSpecs.popups(hint) { add(.popups, popups.key, popups.spec) }
    }
    return shown
  }

  static func urlLeft(_ tabId: String) -> Double? {
    guard let windowId = TabPoolHost.shared.windowOf(tabId), let panes = windows[windowId]?["panes"] as? [String: [String: Any]] else { return nil }
    return (panes[tabId]?["urlLeft"] as? NSNumber)?.doubleValue
  }

  static func promptEvent(_ windowId: String, _ tabId: String, _ kind: PanePromptKind, _ event: PromptEvent) {
    if kind == .popups {
      switch event {
      case .button(let id): js("pane.popups", windowId, tabId, id, "")
      case .row(let id): js("pane.popups", windowId, tabId, "row", id)
      case .close: js("pane.popups", windowId, tabId, "dismiss", "")
      default: break
      }
      return
    }
    guard var page = pages[tabId] else { return }
    switch kind {
    case .password:
      guard let prompt = page.password else { return }
      if case .choice(let name) = event {
        page.chosenUsername = name
        return update(tabId, page)
      }
      let action: String
      switch event {
      case .button(let id): action = id
      case .close: action = "dismiss"
      default: return
      }
      let username = page.chosenUsername ?? prompt.username
      page.password = nil
      page.chosenUsername = nil
      update(tabId, page)
      js("pane.password", windowId, tabId, action, username)
    case .autofill:
      guard let prompt = page.autofill else { return }
      let action: String
      switch event {
      case .button(let id): action = id
      case .close: action = "dismiss"
      default: return
      }
      page.autofill = nil
      update(tabId, page)
      js("pane.autofill", windowId, tabId, prompt.id, action)
    case .externalApp:
      guard let request = page.externalApp else { return }
      if case .toggle(let on) = event {
        page.alwaysOpen = on
        return update(tabId, page)
      }
      let open: Bool
      switch event {
      case .button(let id): open = id == "open"
      case .close: open = false
      default: return
      }
      let remember = open && page.alwaysOpen
      page.externalApp = nil
      page.alwaysOpen = false
      update(tabId, page)
      js("pane.externalApp", windowId, tabId, request.id, open, remember)
    case .popups:
      return
    }
  }

  private static func js(_ name: String, _ args: Any...) {
    Task { @MainActor in
      do {
        _ = try await SettingsJS.shared.invoke(name, args)
      } catch {
        NSLog("[pane prompts] %@ failed: %@", name, String(describing: error))
      }
    }
  }

  private static func update(_ tabId: String, _ page: PanePromptPage) {
    pages[tabId] = page
    changed(tabId)
  }

  private static func encode(_ object: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func changed(_ tabId: String) {
    guard let windowId = TabPoolHost.shared.windowOf(tabId) else { return refreshAll() }
    NativePaneOverlays.refresh(windowId)
  }

  private static func refreshAll() {
    for windowId in Set(windows.keys) { NativePaneOverlays.refresh(windowId) }
  }

  private static func applyWindows(_ value: Any?) {
    windows = ((value as? [String: Any])?["windows"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    refreshAll()
  }
}
