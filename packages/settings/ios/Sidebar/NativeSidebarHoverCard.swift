import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativeSidebarHoverCard {
  static let topic = "sidebar.hoverCard"
  private static var observer: UUID?
  private static var hosts: [String: SidebarHoverCardHost] = [:]

  static func start() {
    guard NativeWindowShell.enabled, observer == nil else { return }
    observer = SettingsJS.shared.observe(topic) { value in receive(value) }
    receive(SettingsJS.shared.latestValue(topic))
  }

  private static func receive(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, host) in hosts where windows[windowId] == nil { host.show(nil) }
    for (windowId, card) in windows {
      let host = hosts[windowId] ?? SidebarHoverCardHost(windowId: windowId)
      hosts[windowId] = host
      host.show(card as? [String: Any])
    }
  }

  static func describe(_ windowId: String) -> String {
    guard let info = hosts[windowId]?.describe(), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }

  static func send(_ windowId: String, _ id: String, _ event: String, _ extra: [String: Any] = [:]) {
    var payload = extra
    if payload["clickAt"] == nil {
      payload["clickAt"] = NSApp.currentEvent.map { $0.type == .leftMouseUp ? $0.timestamp * 1000 : 0 } ?? 0
    }
    let sendable = MediaPayload(payload)
    Task { @MainActor in
      _ = await SettingsAdapters.js(topic, windowId, id, event, sendable.value)
    }
  }
}

@MainActor
final class SidebarHoverCardHost {
  let windowId: String
  private let motion = HoverCardView()
  private lazy var tabCard: SidebarTabCardView = {
    let card = SidebarTabCardView()
    card.onAction = { [weak self, weak card] action in
      guard let self, let id = card?.state?.tabId else { return }
      NativeSidebarHoverCard.send(self.windowId, id, action)
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    return card
  }()
  private lazy var groupCard: SidebarGroupCardView = {
    let card = SidebarGroupCardView(favicons: NativeSidebar.hosts[windowId]?.view.favicons ?? SidebarFavicons())
    card.onEvent = { [weak self, weak card] event in
      guard let self, let id = card?.state?.groupId else { return }
      switch event {
      case .choose(let tabId): NativeSidebarHoverCard.send(self.windowId, id, "choose", ["tabId": tabId])
      case .close: NativeSidebarHoverCard.send(self.windowId, id, "close")
      case .hold(let on): NativeSidebarHoverCard.send(self.windowId, id, on ? "hold" : "release")
      case .focusPage: NativeSidebarHoverCard.send(self.windowId, id, "focusPage")
      }
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    return card
  }()
  private var kind: String?

  init(windowId: String) {
    self.windowId = windowId
    motion.autoresizingMask = [.width, .height]
    motion.onHidden = { [weak self] in self?.coverChanged() }
  }

  private func coverChanged() {
    NativeWindowShell.host(windowId)?.shell.coverChanged()
  }

  func show(_ card: [String: Any]?) {
    guard let card, let kind = card["kind"] as? String else {
      if kind == "group" { groupCard.live = false }
      motion.hide()
      return coverChanged()
    }
    guard let overlay = NativeWindowShell.overlay(windowId) else { return }
    if motion.superview !== overlay {
      motion.frame = overlay.bounds
      overlay.addSubview(motion)
    }
    guard let placed = place(kind, card) else {
      motion.hide()
      return coverChanged()
    }
    if self.kind == "group", kind != "group" { groupCard.live = false }
    self.kind = kind
    motion.show(placed.view, origin: placed.origin)
    NativeSidebarHoverCard.send(windowId, "", "layout", ["frame": [placed.origin.x, placed.origin.y, placed.view.frame.width, placed.view.frame.height]])
    coverChanged()
    DispatchQueue.main.asyncAfter(deadline: .now() + HoverCardMotion.fadeDuration) { [weak self] in self?.coverChanged() }
  }

  private func place(_ kind: String, _ card: [String: Any]) -> (view: NSView, origin: CGPoint)? {
    switch kind {
    case "tab":
      guard let state = SidebarTabCardState.decode(card) else { return nil }
      tabCard.set(state)
      return (tabCard, SidebarTabCardMetrics.origin(anchor: state.anchorRect, sidebarWidth: state.sidebarWidth, cardHeight: tabCard.height, windowHeight: state.windowHeight))
    case "group":
      guard let state = Self.decode(SidebarGroupCardState.self, card) else { return nil }
      groupCard.live = true
      groupCard.set(state)
      return (groupCard, SidebarGroupCardMetrics.origin(anchor: state.anchorRect, height: groupCard.frame.height, windowHeight: state.windowHeight))
    default:
      return nil
    }
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) -> T? {
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private func pointer(_ inside: Bool) {
    NativeSidebarHoverCard.send(windowId, "", inside ? "enter" : "leave")
  }

  func describe() -> [String: Any] {
    var info: [String: Any] = ["kind": kind ?? NSNull(), "phase": motion.phase.rawValue, "opacity": motion.presentedOpacity, "scale": motion.scaleValue()]
    if let content = motion.content, let window = content.window, let root = window.contentView {
      let r = content.convert(content.bounds, to: nil)
      info["frame"] = [r.minX, root.bounds.height - r.maxY, r.width, r.height]
      info["inWindow"] = root.bounds.contains(r)
      info["typingInCard"] = (window.firstResponder as? NSView)?.isDescendant(of: content) ?? false
      info["onScreen"] = window.isVisible && !content.isHiddenOrHasHiddenAncestor && motion.superview != nil
      var buttons: [String: [Double]] = [:]
      func walk(_ view: NSView) {
        if view.accessibilityRole() == .button, let label = view.accessibilityLabel(), !label.isEmpty {
          let b = view.convert(view.bounds, to: nil)
          buttons[label] = [b.minX, root.bounds.height - b.maxY, b.width, b.height]
        }
        view.subviews.forEach(walk)
      }
      walk(content)
      info["buttons"] = buttons
      if kind == "tab", let look = tabCard.state?.look { info["fill"] = look.fill }
      if kind == "group" { info["rows"] = groupCard.state?.rows.map(\.id) ?? [] }
    }
    return info
  }
}
