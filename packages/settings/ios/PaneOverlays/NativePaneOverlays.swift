import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativePaneOverlays {
  static let topic = "pane.overlays"
  private static var started = false
  private static var hosts: [String: PaneOverlayHost] = [:]

  static func start() {
    guard NativeWindowShell.enabled, !started else { return }
    started = true
    _ = SettingsJS.shared.observe(topic) { value in apply(value) }
    apply(SettingsJS.shared.latestValue(topic))
  }

  static func host(_ windowId: String) -> PaneOverlayHost? { hosts[windowId] }

  private static func apply(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, host) in hosts where windows[windowId] == nil {
      host.apply([:])
      if host.container.superview == nil { hosts[windowId] = nil }
    }
    for (windowId, tabs) in windows {
      guard let tabs = tabs as? [String: Any] else { continue }
      let host = hosts[windowId] ?? PaneOverlayHost(windowId: windowId)
      hosts[windowId] = host
      host.apply(tabs)
    }
  }

  static func describe(_ windowId: String) -> String {
    guard let host = hosts[windowId] else { return "null" }
    let data = try? JSONSerialization.data(withJSONObject: host.describe())
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }
}

@MainActor
final class PaneOverlayContainer: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
final class PaneOverlayHost {
  let windowId: String
  let container = PaneOverlayContainer()
  private var sadTabs: [String: SadTabView] = [:]
  private var pageFrames: [String: CGRect] = [:]

  init(windowId: String) {
    self.windowId = windowId
  }

  private var card: NSView? { NativeWindowShell.host(windowId)?.shell.card }

  func apply(_ tabs: [String: Any]) {
    var seen = Set<String>()
    for (tabId, value) in tabs {
      guard let entry = value as? [String: Any], let sad = entry["sadTab"],
        let data = try? JSONSerialization.data(withJSONObject: sad), let json = String(data: data, encoding: .utf8),
        let state = SadTabState.decode(json), state.mode != nil
      else { continue }
      seen.insert(tabId)
      if let f = (sad as? [String: Any])?["frame"] as? [Double], f.count == 4, let card, let height = card.window?.contentView?.bounds.height {
        pageFrames[tabId] = card.convert(CGRect(x: f[0], y: height - f[1] - f[3], width: f[2], height: f[3]), from: nil)
      }
      let view = sadTabs[tabId] ?? make(tabId)
      view.update(state)
    }
    for (tabId, view) in sadTabs where !seen.contains(tabId) {
      view.removeFromSuperview()
      sadTabs[tabId] = nil
      pageFrames[tabId] = nil
    }
    relayout()
  }

  private func make(_ tabId: String) -> SadTabView {
    let view = SadTabView(frame: .zero)
    let windowId = windowId
    view.onAction = { action in
      Task { @MainActor in _ = await SettingsAdapters.js("pane.sadTab", windowId, tabId, action.rawValue) }
    }
    container.addSubview(view)
    sadTabs[tabId] = view
    return view
  }

  func relayout() {
    guard let card else { return container.removeFromSuperview() }
    if sadTabs.isEmpty {
      container.removeFromSuperview()
      return
    }
    if container.superview !== card || card.subviews.last !== container {
      container.removeFromSuperview()
      card.addSubview(container)
    }
    container.frame = card.bounds
    container.autoresizingMask = [.width, .height]
    for (tabId, view) in sadTabs {
      let rect = pageFrames[tabId]
      view.isHidden = rect == nil || view.showing == nil
      if let rect, view.frame != rect { view.frame = rect }
    }
  }

  func describe() -> [String: Any] {
    var tabs: [String: Any] = [:]
    for (tabId, view) in sadTabs {
      let inWindow = { (r: CGRect) -> [Double] in
        let w = view.convert(r, to: nil)
        let h = view.window?.contentView?.bounds.height ?? 0
        return [w.minX, h - w.maxY, w.width, w.height]
      }
      tabs[tabId] = ["mode": (view.showing?.rawValue).map { $0 as Any } ?? NSNull(), "hidden": view.isHiddenOrHasHiddenAncestor, "frame": inWindow(view.bounds), "controls": view.controlFrames.mapValues(inWindow)]
    }
    return ["top": container.superview?.subviews.last === container, "inCard": container.superview === card, "tabs": tabs]
  }
}
