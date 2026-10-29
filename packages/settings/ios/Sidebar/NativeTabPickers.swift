import AppKit
import Foundation
import SolaraModel
import SolaraUI

final class SwitcherPresses: @unchecked Sendable {
  private let lock = NSLock()
  private var pressed: [String: Int] = [:]

  func press(_ windowId: String, _ index: Int) { lock.withLock { pressed[windowId] = index } }
  func clear(_ windowId: String) { lock.withLock { pressed[windowId] = nil } }
  func take(_ windowId: String) -> Int { lock.withLock { pressed.removeValue(forKey: windowId) ?? -1 } }
}

@MainActor
enum NativeTabPickers {
  static let kind = "tabPickers"
  static let searchTopic = "sidebar.tabSearch"
  static let switcherTopic = "sidebar.switcher"
  private static var observers: [String: UUID] = [:]
  private static var searches: [String: TabSearchPanelView] = [:]
  private static var switchers: [String: TabSwitcherPanelView] = [:]
  nonisolated static let switcherPresses = SwitcherPresses()

  nonisolated static var enabled: Bool {
    NativeWindowShell.enabled && LaunchSwitches.shared.isOn(.nativeTabPickers)
  }

  static func register() {
    guard enabled, observers.isEmpty else { return }
    HostedViews.register(kind) { _ in nil }
    observers[searchTopic] = SettingsJS.shared.observe(searchTopic) { value in receiveSearch(value) }
    observers[switcherTopic] = SettingsJS.shared.observe(switcherTopic) { value in receiveSwitcher(value) }
    receiveSearch(SettingsJS.shared.latestValue(searchTopic))
    receiveSwitcher(SettingsJS.shared.latestValue(switcherTopic))
  }

  private static func windows(_ value: Any?) -> [String: Any] {
    ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
  }

  private static func favicons(_ windowId: String) -> SidebarFavicons {
    NativeSidebar.hosts[windowId]?.view.favicons ?? SidebarFavicons()
  }

  private static func receiveSearch(_ value: Any?) {
    let open = windows(value)
    for (windowId, view) in searches where open[windowId] == nil {
      view.removeFromSuperview()
      searches[windowId] = nil
    }
    for (windowId, raw) in open {
      guard let raw = raw as? [String: Any], let state = decode(TabSearchState.self, raw), let overlay = NativeWindowShell.overlay(windowId) else { continue }
      if let view = searches[windowId], view.superview === overlay {
        if view.openId == state.openId { view.set(state) } else { view.open(state) }
        continue
      }
      let view = TabSearchPanelView(favicons: favicons(windowId))
      view.frame = overlay.bounds
      view.autoresizingMask = [.width, .height]
      view.onEvent = { event in
        switch event {
        case .close: send(searchTopic, windowId, "close")
        case .choose(let kind, let id): send(searchTopic, windowId, "choose", kind, id)
        }
      }
      overlay.addSubview(view)
      searches[windowId] = view
      view.open(state)
    }
  }

  private static func receiveSwitcher(_ value: Any?) {
    let shown = windows(value)
    for (windowId, view) in switchers where shown[windowId] == nil {
      view.removeFromSuperview()
      switchers[windowId] = nil
      switcherPresses.clear(windowId)
    }
    for (windowId, raw) in shown {
      guard let raw = raw as? [String: Any], let state = decode(TabSwitcherState.self, raw), let overlay = NativeWindowShell.overlay(windowId) else { continue }
      let view = switchers[windowId] ?? {
        let made = TabSwitcherPanelView(favicons: favicons(windowId))
        made.onEvent = { event in
          switch event {
          case .hover(let index): send(switcherTopic, windowId, "hover", index)
          case .leave(let index): send(switcherTopic, windowId, "leave", index)
          case .commit(let index):
            switcherPresses.press(windowId, index)
            send(switcherTopic, windowId, "commit", index)
          }
        }
        return made
      }()
      switchers[windowId] = view
      if view.superview !== overlay { overlay.addSubview(view) }
      view.set(state, windowSize: overlay.bounds.size)
    }
  }

  static func describe(_ windowId: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: info(windowId)) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func info(_ windowId: String) -> [String: Any] {
    var info: [String: Any] = [:]
    if let window = NativeWindowShell.overlay(windowId)?.window {
      info["responder"] = window.firstResponder.map { $0 === window ? "window" : String(describing: type(of: $0)) } ?? "none"
    }
    func rect(_ view: NSView, _ r: CGRect) -> [Double] {
      guard let root = view.window?.contentView else { return [] }
      let w = view.convert(r, to: nil)
      return [w.minX, root.bounds.height - w.maxY, w.width, w.height]
    }
    if let search = searches[windowId] {
      info["search"] = [
        "frame": rect(search, search.panelFrame), "query": search.query, "selected": search.selectedIndex, "rows": search.shownRows.map { "\($0.kind):\($0.id)" },
        "typing": search.typing,
      ] as [String: Any]
    }
    if let switcher = switchers[windowId] {
      info["switcher"] = ["frame": rect(switcher, switcher.bounds), "ids": switcher.shownIds, "index": switcher.state?.index ?? -1] as [String: Any]
    }
    return info
  }

  private static func send(_ topic: String, _ windowId: String, _ event: String, _ args: Any...) {
    let payload = SidebarPayload(["args": args])
    Task { @MainActor in
      let args = payload.value["args"] as? [Any] ?? []
      _ = try? await SettingsJS.shared.invoke(topic, [windowId, event] + args)
    }
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) -> T? {
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }
}
