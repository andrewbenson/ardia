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

  static func swipe(_ windowId: String, _ tabId: String, _ json: String) {
    guard NativeWindowShell.enabled, let data = json.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    let host = hosts[windowId] ?? PaneOverlayHost(windowId: windowId)
    hosts[windowId] = host
    host.swipe(tabId, message)
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
final class PanePopover<Body: NSView> {
  let wrap = PaneOverlayContainer()
  let popover: PopoverView
  let body: Body
  var mark: String?

  init(_ body: Body) {
    self.body = body
    popover = PopoverView(body: body)
    popover.autoresizingMask = [.width, .height]
    wrap.addSubview(popover)
  }

  func setHeight(_ h: CGFloat) { DispatchQueue.main.async { [weak self] in self?.popover.set(bodyHeight: h) } }

  func place(_ rect: CGRect?) {
    wrap.isHidden = rect == nil
    guard let rect, wrap.frame != rect else { return }
    wrap.frame = rect
    popover.frame = wrap.bounds
  }

  func describe(_ inWindow: (NSView, CGRect) -> [Double]) -> [String: Any] {
    var controls: [String: [Double]] = [:]
    func walk(_ view: NSView) {
      if view.accessibilityRole() == .button, let name = view.accessibilityLabel() { controls[name] = inWindow(view, view.bounds) }
      view.subviews.forEach(walk)
    }
    walk(body)
    return ["hidden": wrap.isHiddenOrHasHiddenAncestor, "frame": inWindow(wrap, wrap.bounds), "card": inWindow(popover, popover.cardFrame), "opacity": popover.presentedOpacity, "progress": popover.progress, "controls": controls]
  }
}

@MainActor
final class PaneOverlayHost {
  let windowId: String
  let container = PaneOverlayContainer()
  private var sadTabs: [String: SadTabView] = [:]
  private var zooms: [String: PanePopover<ZoomPanelView>] = [:]
  private var histories: [String: PanePopover<HistoryPanelView>] = [:]
  private var swipes: [String: (wrap: PaneOverlayContainer, capsule: SwipeCapsuleView)] = [:]
  private static let swipeFavicons: SidebarFavicons = {
    let made = SidebarFavicons()
    made.loader = { request in try await NativeSidebar.favicon(request) }
    return made
  }()
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
    var listed = Set<String>()
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
      if let data = entry(value, kind: "history", tabId: tabId), let state = try? JSONDecoder().decode(HistoryPanelState.self, from: data), let placement = PanelPopover.placement(data) {
        listed.insert(tabId)
        let history = histories[tabId] ?? makeHistory(tabId)
        if let mark = ((value as? [String: Any])?["history"] as? [String: Any])?["newTabMark"] as? String, mark != history.mark {
          history.mark = mark
          HistoryPanelMark.load(mark, into: history.body)
        }
        history.body.update(state)
        history.popover.set(placement: placement, dark: state.dark)
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
    for (tabId, history) in histories where !listed.contains(tabId) {
      history.wrap.removeFromSuperview()
      histories[tabId] = nil
      pageFrames["history"]?[tabId] = nil
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

  private func makeZoom(_ tabId: String) -> PanePopover<ZoomPanelView> {
    let zoom = PanePopover(ZoomPanelView(frame: .zero))
    let windowId = windowId
    zoom.body.onHeight = { [weak zoom] h in zoom?.setHeight(h) }
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

  private func makeHistory(_ tabId: String) -> PanePopover<HistoryPanelView> {
    let history = PanePopover(HistoryPanelView(frame: .zero))
    let windowId = windowId
    history.body.favicons.loader = { request in try await NativeSidebar.favicon(request) }
    history.body.onHeight = { [weak history] h in history?.setHeight(h) }
    history.popover.onDismiss = { Task { @MainActor in _ = await SettingsAdapters.js("pane.history", windowId, tabId, ["kind": "dismiss"]) } }
    history.body.onEvent = { event in
      let payload: [String: Any]
      switch event {
      case .open(let index, let click): payload = ["kind": "open", "index": index, "metaKey": click.meta, "shiftKey": click.shift, "altKey": click.alt, "middle": click.middle]
      case .fullHistory: payload = ["kind": "fullHistory"]
      }
      Task { @MainActor in _ = await SettingsAdapters.js("pane.history", windowId, tabId, payload) }
    }
    container.addSubview(history.wrap)
    histories[tabId] = history
    return history
  }

  func swipe(_ tabId: String, _ message: [String: Any]) {
    let op = message["op"] as? String
    if op == "show" {
      guard let card, let height = card.window?.contentView?.bounds.height, let f = message["frame"] as? [Double], f.count == 4 else { return }
      let rect = card.convert(CGRect(x: f[0], y: height - f[1] - f[3], width: f[2], height: f[3]), from: nil)
      let entry = swipes[tabId] ?? makeSwipe(tabId)
      entry.wrap.frame = rect
      entry.capsule.frame = entry.wrap.bounds
      let theme = message["theme"] as? [String: Any] ?? [:]
      let direction = SwipeCapsuleDirection(rawValue: message["direction"] as? String ?? "") ?? .back
      entry.capsule.show(direction, theme: SwipeCapsuleTheme(dark: theme["dark"] as? Bool ?? false, textPrimary: theme["textPrimary"] as? String ?? "#000000D9", textSecondary: theme["textSecondary"] as? String ?? "#00000080"), profileId: message["profileId"] as? String ?? "")
      return relayout()
    }
    guard let capsule = swipes[tabId]?.capsule else { return }
    let number = { (key: String) -> CGFloat? in (message[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
    switch op {
    case "move": capsule.move(x: number("x"), nudge: number("nudge"))
    case "confirm": capsule.setConfirmed(message["confirmed"] as? Bool ?? false)
    case "list":
      let items = (message["items"] as? [[String: Any]] ?? []).map { SwipeCapsuleItem(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", favicon: $0["favicon"] as? String, newTab: $0["newTab"] as? Bool ?? false) }
      capsule.presentList(items)
    case "select":
      capsule.move(nudge: number("nudge"))
      capsule.select(message["index"] as? Int ?? 0)
    case "dismiss": capsule.dismiss(delay: (message["delay"] as? NSNumber)?.doubleValue ?? 0)
    default: break
    }
  }

  private func makeSwipe(_ tabId: String) -> (wrap: PaneOverlayContainer, capsule: SwipeCapsuleView) {
    let wrap = PaneOverlayContainer()
    let capsule = SwipeCapsuleView(frame: .zero)
    capsule.favicons = Self.swipeFavicons
    capsule.autoresizingMask = [.width, .height]
    wrap.addSubview(capsule)
    capsule.onDismissed = { [weak self, weak capsule] in
      guard let self, let capsule, self.swipes[tabId]?.capsule === capsule else { return }
      self.swipes[tabId]?.wrap.removeFromSuperview()
      self.swipes[tabId] = nil
      self.relayout()
    }
    container.addSubview(wrap)
    swipes[tabId] = (wrap, capsule)
    return (wrap, capsule)
  }

  func relayout() {
    guard let card else { return container.removeFromSuperview() }
    if sadTabs.isEmpty && zooms.isEmpty && histories.isEmpty && swipes.isEmpty {
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
    for (tabId, zoom) in zooms { zoom.place(pageFrames["zoom"]?[tabId]) }
    for (tabId, history) in histories { history.place(pageFrames["history"]?[tabId]) }
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
    for (tabId, zoom) in zooms { tabs[tabId, default: [:]]["zoom"] = zoom.describe(inWindow) }
    for (tabId, history) in histories { tabs[tabId, default: [:]]["history"] = history.describe(inWindow) }
    for (tabId, entry) in swipes {
      let c = entry.capsule
      let s = c.sample()
      tabs[tabId, default: [:]]["swipe"] = ["shown": c.shown, "active": c.active, "direction": c.direction.rawValue, "confirmed": c.confirmed, "items": c.items?.map(\.title) ?? NSNull(), "selected": c.selected,
        "frame": inWindow(c, s.frame), "area": inWindow(entry.wrap, entry.wrap.bounds), "radius": s.radius, "opacity": s.opacity, "scale": s.scale, "iconScale": s.iconScale, "list": s.list, "pill": s.pill]
    }
    return ["top": container.superview?.subviews.last === container, "inCard": container.superview === card, "tabs": tabs]
  }
}
