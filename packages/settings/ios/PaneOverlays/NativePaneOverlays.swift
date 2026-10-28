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
final class PaneZoomPopover {
  let wrap = PaneOverlayContainer()
  let popover: PopoverView
  let body = ZoomPanelView(frame: .zero)

  init() {
    popover = PopoverView(body: body)
    popover.autoresizingMask = [.width, .height]
    wrap.addSubview(popover)
    body.onHeight = { [weak self] h in DispatchQueue.main.async { self?.popover.set(bodyHeight: h) } }
  }
}

@MainActor
final class PaneOverlayHost {
  let windowId: String
  let container = PaneOverlayContainer()
  private var sadTabs: [String: SadTabView] = [:]
  private var zooms: [String: PaneZoomPopover] = [:]
  private var pageFrames: [String: [String: CGRect]] = [:]

  init(windowId: String) {
    self.windowId = windowId
  }

  private var card: NSView? { NativeWindowShell.host(windowId)?.shell.card }

  private func entry(_ value: Any?, kind: String, tabId: String) -> Data? {
    guard let object = (value as? [String: Any])?[kind] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    if let f = object["frame"] as? [Double], f.count == 4, let card, let height = card.window?.contentView?.bounds.height {
      pageFrames[kind, default: [:]][tabId] = card.convert(CGRect(x: f[0], y: height - f[1] - f[3], width: f[2], height: f[3]), from: nil)
    }
    return data
  }

  func apply(_ tabs: [String: Any]) {
    var sad = Set<String>()
    var zoomed = Set<String>()
    for (tabId, value) in tabs {
      if let data = entry(value, kind: "sadTab", tabId: tabId), let json = String(data: data, encoding: .utf8), let state = SadTabState.decode(json), state.mode != nil {
        sad.insert(tabId)
        (sadTabs[tabId] ?? makeSadTab(tabId)).update(state)
      }
      if let data = entry(value, kind: "zoom", tabId: tabId), let state = try? JSONDecoder().decode(ZoomPanelState.self, from: data), let placement = PanelPopover.placement(data) {
        zoomed.insert(tabId)
        let zoom = zooms[tabId] ?? makeZoom(tabId)
        zoom.body.update(state)
        zoom.popover.set(placement: placement, dark: state.dark)
      }
    }
    for (tabId, view) in sadTabs where !sad.contains(tabId) {
      view.removeFromSuperview()
      sadTabs[tabId] = nil
      pageFrames["sadTab"]?[tabId] = nil
    }
    for (tabId, zoom) in zooms where !zoomed.contains(tabId) {
      zoom.wrap.removeFromSuperview()
      zooms[tabId] = nil
      pageFrames["zoom"]?[tabId] = nil
    }
    relayout()
  }

  private func makeSadTab(_ tabId: String) -> SadTabView {
    let view = SadTabView(frame: .zero)
    let windowId = windowId
    view.onAction = { action in
      Task { @MainActor in _ = await SettingsAdapters.js("pane.sadTab", windowId, tabId, action.rawValue) }
    }
    container.addSubview(view, positioned: .below, relativeTo: nil)
    sadTabs[tabId] = view
    return view
  }

  private func makeZoom(_ tabId: String) -> PaneZoomPopover {
    let zoom = PaneZoomPopover()
    let windowId = windowId
    zoom.popover.onDismiss = { Task { @MainActor in _ = await SettingsAdapters.js("pane.zoom", windowId, tabId, "dismiss", 0) } }
    zoom.body.onEvent = { event in
      switch event {
      case .step(let step): Task { @MainActor in _ = await SettingsAdapters.js("pane.zoom", windowId, tabId, "step", step) }
      }
    }
    container.addSubview(zoom.wrap)
    zooms[tabId] = zoom
    return zoom
  }

  func relayout() {
    guard let card else { return container.removeFromSuperview() }
    if sadTabs.isEmpty && zooms.isEmpty {
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
      let rect = pageFrames["sadTab"]?[tabId]
      view.isHidden = rect == nil || view.showing == nil
      if let rect, view.frame != rect { view.frame = rect }
    }
    for (tabId, zoom) in zooms {
      let rect = pageFrames["zoom"]?[tabId]
      zoom.wrap.isHidden = rect == nil
      if let rect, zoom.wrap.frame != rect {
        zoom.wrap.frame = rect
        zoom.popover.frame = zoom.wrap.bounds
      }
    }
  }

  func describe() -> [String: Any] {
    var tabs: [String: [String: Any]] = [:]
    func inWindow(_ view: NSView, _ r: CGRect) -> [Double] {
      let w = view.convert(r, to: nil)
      let h = view.window?.contentView?.bounds.height ?? 0
      return [w.minX, h - w.maxY, w.width, w.height]
    }
    for (tabId, view) in sadTabs {
      tabs[tabId, default: [:]]["sadTab"] = ["mode": (view.showing?.rawValue).map { $0 as Any } ?? NSNull(), "hidden": view.isHiddenOrHasHiddenAncestor, "frame": inWindow(view, view.bounds), "controls": view.controlFrames.mapValues { inWindow(view, $0) }]
    }
    for (tabId, zoom) in zooms {
      let p = zoom.popover
      var controls: [String: [Double]] = [:]
      func walk(_ view: NSView) {
        if view.accessibilityRole() == .button, let name = view.accessibilityLabel() { controls[name] = inWindow(view, view.bounds) }
        view.subviews.forEach(walk)
      }
      walk(zoom.body)
      tabs[tabId, default: [:]]["zoom"] = ["hidden": zoom.wrap.isHiddenOrHasHiddenAncestor, "frame": inWindow(zoom.wrap, zoom.wrap.bounds), "card": inWindow(p, p.cardFrame), "opacity": p.presentedOpacity, "progress": p.progress, "controls": controls]
    }
    return ["top": container.superview?.subviews.last === container, "inCard": container.superview === card, "tabs": tabs]
  }
}
