import AppKit
import Foundation
import SolaraLive
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
  private lazy var liveCard: SidebarLiveCardView = {
    let card = SidebarLiveCardView(favicons: NativeSidebar.hosts[windowId]?.view.favicons)
    card.onEvent = { [weak self, weak card] event in
      guard let self, let id = card?.state?.id else { return }
      switch event {
      case .openItem: NativeSidebarHoverCard.send(self.windowId, id, "openItem")
      case .open(let url): NativeSidebarHoverCard.send(self.windowId, id, "open", ["url": url])
      }
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    card.onResize = { [weak self] in self?.coverChanged() }
    return card
  }()
  private lazy var playerCard: HoverPlayerCardView = {
    let card = HoverPlayerCardView()
    card.player.onAction = { [weak self, weak card] action in
      guard let self, let id = card?.state?.tabId else { return }
      NativeMedia.player("hoverPlayer", self.windowId, id, action)
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    return card
  }()
  private lazy var calendarCard: SidebarCalendarCardView = {
    PageProbe.enabled = ProcessInfo.processInfo.environment["ARDIA_BACKGROUND"] == "1"
    let card = SidebarCalendarCardView()
    card.onEvent = { [weak self, weak card] event in
      guard let self, let tabId = card?.tabId else { return }
      switch event {
      case .activate: NativeSidebarHoverCard.send(self.windowId, tabId, "calendar", ["action": "activate"])
      case .join(let id, _): NativeSidebarHoverCard.send(self.windowId, tabId, "calendar", ["action": "join", "eventId": id])
      case .refresh: NativeSidebarHoverCard.send(self.windowId, tabId, "calendar", ["action": "refresh"])
      case .connect: NativeSidebarHoverCard.send(self.windowId, tabId, "calendar", ["action": "connect"])
      case .height, .dismiss, .view: break
      }
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    card.onResize = { [weak self] in self?.coverChanged() }
    return card
  }()
  private lazy var folderPeek: SidebarFolderPeekView = {
    let card = SidebarFolderPeekView(favicons: NativeSidebar.hosts[windowId]?.view.favicons ?? SidebarFavicons())
    card.onChoose = { [weak self, weak card] tabId in
      guard let self, let id = card?.state?.folderId else { return }
      NativeSidebarHoverCard.send(self.windowId, id, "choose", ["tabId": tabId])
    }
    card.onPointer = { [weak self] inside in self?.pointer(inside) }
    return card
  }()
  private var kind: String?
  private var liveCardInput: [String: Any]?
  private var liveObserver: NSObjectProtocol?

  init(windowId: String) {
    self.windowId = windowId
    motion.autoresizingMask = [.width, .height]
    motion.onHidden = { [weak self] in self?.coverChanged() }
    liveObserver = NotificationCenter.default.addObserver(forName: SidebarLiveFeed.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.liveChanged() }
    }
  }

  private func liveChanged() {
    guard kind == "live", motion.phase != .leaving, motion.phase != .hidden, let card = liveCardInput else { return }
    show(card)
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
    case "player":
      guard let json = card["state"] as? String, let state = MediaPlayerState.decode(json), let anchor = card["anchor"] as? [Double], anchor.count == 4 else { return nil }
      playerCard.set(state)
      let edge = card["edge"] as? Double ?? anchor[0] + anchor[2]
      return (playerCard, HoverCardMotion.origin(anchor: CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3]), edge: edge))
    case "calendar":
      guard let tabId = card["tabId"] as? String, let json = card["state"] as? String, let data = json.data(using: .utf8),
        let state = try? JSONDecoder().decode(LiveCardModel.State.self, from: data),
        let lookValue = card["look"] as? [String: Any], let look = Self.decode(SidebarSurfaceLook.self, lookValue),
        let anchor = card["anchor"] as? [Double], anchor.count == 4
      else { return nil }
      calendarCard.set(tabId: tabId, state: state, look: look)
      return (calendarCard, HoverCardMotion.origin(anchor: CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3])))
    case "live":
      liveCardInput = card
      guard let state = Self.liveState(card) else { return nil }
      liveCard.set(state)
      return (liveCard, HoverCardMotion.origin(anchor: state.anchorRect))
    case "folder":
      guard let state = Self.decode(SidebarFolderPeekState.self, card) else { return nil }
      folderPeek.set(state)
      return (folderPeek, HoverCardMotion.origin(anchor: state.anchorRect))
    default:
      return nil
    }
  }

  private static func liveState(_ card: [String: Any]) -> SidebarLiveCardState? {
    guard let id = card["id"] as? String, let anchor = card["anchor"] as? [Double],
      let lookValue = card["look"] as? [String: Any], let look = decode(SidebarLiveCardState.Look.self, lookValue)
    else { return nil }
    let key = SidebarLiveCardState.itemKey(id)
    guard let item = SidebarLiveFeed.shared.live?.state.items[key.folderId]?.first(where: { $0.id == key.itemId }) else { return nil }
    return SidebarLiveCardState(id: id, item: item, anchor: anchor, look: look, now: Date().timeIntervalSince1970 * 1000)
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
      if kind == "tab", let look = tabCard.state?.look {
        info["fill"] = look.fill
        info["titleShown"] = tabCard.titleShown
      }
      if kind == "group" { info["rows"] = groupCard.state?.rows.map(\.id) ?? [] }
      if kind == "folder" { info["title"] = folderPeek.state?.title ?? ""; info["more"] = folderPeek.state?.more ?? NSNull() }
      if kind == "calendar" {
        let card = CGRect(x: r.minX, y: root.bounds.height - r.maxY, width: r.width, height: r.height)
        info["events"] = Dictionary(uniqueKeysWithValues: PageProbe.items.values.filter { $0.label.hasPrefix("event:") && card.contains($0.frame) }.map { ($0.label, [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]) })
      }
    }
    return info
  }
}
