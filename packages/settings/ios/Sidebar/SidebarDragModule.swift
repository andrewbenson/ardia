import AppKit
import ExpoModulesCore
import ArdiaShell
import SolaraModel
import SolaraStore
import SolaraUI

public class SidebarDragModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraSidebarDrag")

    OnCreate { DispatchQueue.main.async { MainActor.assumeIsolated { SidebarDragHub.bridge = NativeSidebarDrag.shared } } }

    AsyncFunction("tabDrag") { (onPage: Bool, insert: Bool) in
      MainActor.assumeIsolated { NativeSidebarDrag.shared.pageChanged(onPage: onPage, insert: insert) }
    }.runOnQueue(.main)

    AsyncFunction("escape") {
      MainActor.assumeIsolated { SidebarDragHub.escape() }
    }.runOnQueue(.main)

    AsyncFunction("external") { (windowId: String, phase: String, x: Double, y: Double, count: Int) -> String? in
      MainActor.assumeIsolated { NativeSidebarDrag.external(windowId: windowId, phase: phase, at: CGPoint(x: x, y: y), count: count) }
    }.runOnQueue(.main)

    AsyncFunction("panel") { (windowId: String, frameJSON: String?) in
      MainActor.assumeIsolated { NativeSidebarDrag.panel(windowId: windowId, frameJSON) }
    }.runOnQueue(.main)

    AsyncFunction("panelDrag") { (windowId: String, phase: String, tabId: String, x: Double, y: Double) in
      MainActor.assumeIsolated {
        guard let page = NativeSidebarDrag.page(windowId) else { return }
        SidebarDragController.of(page).panelDrag(phase, tabId: tabId, at: CGPoint(x: x, y: y))
      }
    }.runOnQueue(.main)

    AsyncFunction("startProbe") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeSidebarDrag.startProbe(windowId) }
    }.runOnQueue(.main)

    Function("probe") { (windowId: String) -> String in
      NativeSidebarDrag.cached(windowId)
    }

    AsyncFunction("clearLanded") { (windowId: String) in
      MainActor.assumeIsolated {
        SidebarDragHub.controller(windowId: windowId)?.clearLanded()
        NativeSidebarDrag.refresh(windowId)
      }
    }.runOnQueue(.main)

    AsyncFunction("trace") { (identifier: String, milliseconds: Double) in
      MainActor.assumeIsolated { SidebarDragTrace.shared.start(identifier, milliseconds: milliseconds) }
    }.runOnQueue(.main)

    AsyncFunction("traceSamples") { () -> String in
      MainActor.assumeIsolated {
        let data = (try? JSONSerialization.data(withJSONObject: SidebarDragTrace.shared.samples)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
      }
    }.runOnQueue(.main)

    AsyncFunction("scrollTo") { (windowId: String, y: Double) in
      MainActor.assumeIsolated {
        guard let page = NativeSidebarDrag.page(windowId) else { return }
        SidebarDragController.of(page).scroll(to: y)
        NativeSidebarDrag.refresh(windowId)
      }
    }.runOnQueue(.main)
  }
}

@MainActor
final class NativeSidebarDrag: SidebarDragBridge {
  static let shared = NativeSidebarDrag()

  private var chain: Task<Void, Never>?
  private var pendingMove: [Any]?
  private var picture: (size: CGSize, grab: CGPoint)?
  private var pointer = CGPoint.zero
  private var outside = false
  private var overWindow: String?
  private var jsOnPage = false
  private var zoneOnPage = false
  private var onPage: Bool { jsOnPage || zoneOnPage }
  private var insert = false
  private var shape = "hidden"
  private var previewShown = false
  private var previewToken = 0
  static let endDeadline: Double = 2

  private func send(_ name: String, _ args: [Any], done: (@MainActor (Any?) -> Void)? = nil) {
    let previous = chain
    let payload = SidebarPayload(["args": args])
    chain = Task { @MainActor in
      await previous?.value
      let args = payload.value["args"] as? [Any] ?? []
      let result: Any?
      do {
        result = try await SettingsJS.shared.invoke(name, args)
      } catch {
        result = nil
      }
      done?(result)
    }
  }

  func dragBegan(windowId: String, tabId: String?, tabIds: [String]) {
    pendingMove = nil
    clearDrag()
    TabDragSession.windowIdOf = { [weak self] window in
      guard let id = ShellDrag.windowId(of: window), let source = TabDragSession.current?.sourceWindow else { return nil }
      return id == source || self?.accepts(id, from: source) == true ? id : nil
    }
    TabDragSession.windowOf = { ShellDrag.window($0) }
    let session = TabDragSession.begin(tabIds: tabIds, from: windowId)
    session.sourceClosing = { [weak self] in self?.sourceClosing(windowId) }
    send("sidebar.drag.begin", [windowId, tabId ?? NSNull(), tabIds])
  }

  func dragPicture(windowId: String, size: CGSize, grab: CGPoint) {
    picture = (size, grab)
    syncPreview(windowId)
  }

  func dragMoved(windowId: String, x: CGFloat, y: CGFloat) {
    pointer = CGPoint(x: x, y: y)
    var over: String?
    var overPoint = CGPoint.zero
    if let session = session(windowId), let window = ShellDrag.window(windowId) {
      session.move(screenPoint: CGPoint(x: window.frame.minX + x, y: window.frame.maxY - y))
      outside = session.outside
      zoneOnPage = session.aim.map(Self.onPage) ?? false
      if outside, let id = session.overWindow {
        over = id
        overPoint = session.point(in: id) ?? .zero
      }
    }
    overWindow = over
    publish()
    syncPreview(windowId)
    let queued = pendingMove != nil
    pendingMove = [windowId, x, y, outside, over ?? NSNull(), overPoint.x, overPoint.y]
    if queued { return }
    let previous = chain
    chain = Task { @MainActor in
      await previous?.value
      guard let move = self.pendingMove else { return }
      self.pendingMove = nil
      _ = try? await SettingsJS.shared.invoke("sidebar.drag.move", move)
    }
  }

  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) {
    let session = session(windowId)
    let preview: Int? = previewShown ? previewToken : nil
    let tabIds = session?.tabIds ?? []
    let zoned = commit ? session?.end() ?? false : false
    if !commit { session?.cancel() }
    let outside = session?.outside ?? self.outside
    let over = outside ? session?.overWindow : nil
    let zonePage = session?.endedAim.map(Self.onPage) ?? false
    let screen = session?.pointer
    clearDrag()
    let reply = EndReply()
    let finish: @MainActor (_ end: [String: Any]?) -> Void = { [weak self] end in
      guard let self else { return done(false) }
      guard commit else {
        self.endPreview(preview, cancel: true)
        return done(false)
      }
      if zoned || end?["split"] as? Bool == true {
        self.endPreview(preview)
        if zoned, let over, self.open(over) { self.focus(over) }
        return done(true)
      }
      let onPage = !outside && (zonePage || end?["onPage"] as? Bool == true)
      self.lastDrop = [
        "outside": outside, "over": over ?? NSNull(), "zonePage": zonePage, "jsOnPage": end?["onPage"] ?? NSNull(), "jsPointer": end?["pointer"] ?? NSNull(),
        "timedOut": end == nil, "screen": screen.map { [$0.x, $0.y] } ?? NSNull(), "source": ShellDrag.window(windowId).map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? NSNull(),
      ]
      guard outside || onPage, let screen else {
        self.endPreview(preview, cancel: end == nil)
        return done(false)
      }
      let before: String?? = end?["insert"] as? Bool == true ? .some(end?["before"] as? String) : .none
      self.dropOutside(tabIds, from: windowId, at: screen, over: over.flatMap { self.open($0) ? $0 : nil }, before: before, preview: preview)
      done(true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.endDeadline) {
      MainActor.assumeIsolated {
        guard reply.open() else { return }
        finish(nil)
      }
    }
    let deadline = (Date().timeIntervalSince1970 + Self.endDeadline) * 1000
    send("sidebar.drag.end", [windowId, commit && !zoned, deadline]) { result in
      guard reply.open() else { return }
      finish(result as? [String: Any])
    }
  }

  private func sourceClosing(_ windowId: String) {
    if SidebarDragHub.cancel(windowId: windowId) { return }
    let preview: Int? = previewShown ? previewToken : nil
    clearDrag()
    endPreview(preview, cancel: true)
    escapeCapture(false)
    send("sidebar.drag.end", [windowId, false])
  }

  func pageChanged(onPage: Bool, insert: Bool) {
    jsOnPage = onPage
    self.insert = insert
    publish()
    if let source = TabDragSession.current?.sourceWindow { syncPreview(source) }
  }

  private static func onPage(_ aim: TabDropAim) -> Bool {
    switch aim {
    case .page, .split: true
    case .insert, .newWindow: false
    }
  }

  private func session(_ windowId: String) -> TabDragSession? {
    TabDragSession.current.flatMap { $0.sourceWindow == windowId ? $0 : nil }
  }

  private func clearDrag() {
    picture = nil
    outside = false
    overWindow = nil
    jsOnPage = false
    zoneOnPage = false
    insert = false
    shape = "hidden"
    previewShown = false
    publish()
  }

  private func publish() {
    let hub = SidebarDragHub.tabDrag
    guard hub.outside != outside || hub.onPage != onPage else { return }
    SidebarDragHub.tabDragChanged(outside: outside, onPage: onPage)
  }

  private func accepts(_ target: String, from source: String) -> Bool {
    guard let state = NativeStoreHandle.store?.state, let from = state.windows[source], !from.incognito, let to = state.windows[target] else { return false }
    return !to.incognito && to.kind != "small" && open(target)
  }

  private func open(_ windowId: String) -> Bool {
    guard let store = NativeStoreHandle.store, store.state.windows[windowId] != nil, !store.memory.closingWindows.contains(windowId) else { return false }
    return ShellDrag.window(windowId)?.isVisible == true
  }

  private func syncPreview(_ windowId: String) {
    guard session(windowId) != nil else { return }
    let next = outside ? (overWindow != nil && insert ? "pill" : "card") : (onPage ? "card" : "hidden")
    if next == "hidden" && shape == "hidden" { return }
    if next != "hidden", let picture {
      self.picture = nil
      previewShown = true
      let chip = NSRect(x: pointer.x - picture.grab.x, y: pointer.y - picture.grab.y, width: picture.size.width, height: picture.size.height)
      previewToken += 1
      ShellDrag.previewBegin(windowId: windowId, chip: chip, grab: pointer)
      send("sidebar.drag.capture", [windowId])
    }
    shape = next
    ShellDrag.previewUpdate(next, at: pointer)
  }

  private func endPreview(_ token: Int?, windowId: String? = nil, fallback: NSRect? = nil, cancel: Bool = false) {
    guard let token, token == previewToken else { return }
    if cancel { ShellDrag.previewCancel() } else { ShellDrag.previewEnd(windowId: windowId, fallback: fallback) }
  }

  private func dropOutside(_ tabIds: [String], from source: String, at screen: CGPoint, over: String?, before: String??, preview: Int?) {
    guard let store = NativeStoreHandle.store, let from = store.state.windows[source], !from.incognito, !tabIds.isEmpty else {
      return endPreview(preview)
    }
    if let over {
      let moved = (try? store.dispatch(Command("moveTabsToWindow", [JSONValue(tabIds), JSONValue(over)]), origin: .native))?.result?.string
      endPreview(preview)
      guard moved == over, open(over) else { return }
      if let before {
        _ = try? store.dispatch(Command("placeTabs", [JSONValue(tabIds), ["pinned": false, "beforeId": JSONValue(before)]]), origin: .native)
      }
      return focus(over)
    }
    guard !from.tabIds.allSatisfy(tabIds.contains) else { return endPreview(preview) }
    let size = from.frame.flatMap { $0.count == 4 ? CGSize(width: $0[2], height: $0[3]) : nil } ?? CGSize(width: 1200, height: 800)
    let frame = NSRect(x: (screen.x - 90 + 0.5).rounded(.down), y: (screen.y - size.height + 70 + 0.5).rounded(.down), width: size.width, height: size.height)
    let options: JSONValue = [
      "profileId": JSONValue(store.state.tabs[tabIds[0]]?.profileId),
      "tabIds": JSONValue(tabIds),
      "frame": [JSONValue(frame.minX), JSONValue(frame.minY), JSONValue(frame.width), JSONValue(frame.height)],
    ]
    let created = (try? store.dispatch(Command("createWindow", [options]), origin: .native))?.result?.string
    endPreview(preview, windowId: created, fallback: frame)
    if let created, store.state.windows[created] != nil { focus(created) }
  }

  private func focus(_ windowId: String) {
    _ = try? NativeStoreHandle.store?.dispatch(Command("setFocusedWindow", [JSONValue(windowId)]), origin: .native)
    ShellDrag.focus(windowId)
  }

  func drop(windowId: String, ids: [String], drop: JSONValue, sequence: [String]?) {
    if let store = NativeStoreHandle.store {
      _ = try? store.dispatch(Command("dropTabs", [JSONValue(ids), drop]), origin: .native)
    }
    if let sequence, sequence.contains(where: { $0.hasPrefix(SidebarLive.prefix) }) {
      send("sidebar.drag.live", [sequence])
    }
  }

  private(set) var escaping = false
  private(set) var lastDrop: [String: Any] = [:]

  func escapeCapture(_ on: Bool) {
    escaping = on
    send("sidebar.drag.escape", [on])
  }

  func haptic() { send("sidebar.drag.haptic", []) }

  func closeFolderPanel(windowId: String) { send("sidebar.drag.closePanel", [windowId]) }

  func changed(windowId: String) {
    if SidebarDragHub.probing { Self.refreshSoon(windowId) }
    if let page = Self.page(windowId), let controller = SidebarDragController.existing(page), controller.panelOpen {
      send("sidebar.drag.marks", [windowId, controller.marksJSON])
    }
  }

  nonisolated(unsafe) private static let lock = NSLock()
  nonisolated(unsafe) private static var snapshots: [String: String] = [:]

  nonisolated static func cached(_ windowId: String) -> String {
    lock.withLock { snapshots[windowId] ?? "null" }
  }

  static func page(_ windowId: String) -> SidebarView? {
    NativeSidebar.hosts[windowId]?.view.current
  }

  static func startProbe(_ windowId: String) -> String {
    SidebarDragHub.probing = true
    return refresh(windowId)
  }

  private static var pendingRefresh: Set<String> = []

  static func refreshSoon(_ windowId: String) {
    if let page = page(windowId), SidebarDragController.existing(page)?.active == true {
      refresh(windowId)
      return
    }
    guard pendingRefresh.insert(windowId).inserted else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) {
      MainActor.assumeIsolated {
        pendingRefresh.remove(windowId)
        refresh(windowId)
      }
    }
  }

  @discardableResult
  static func refresh(_ windowId: String) -> String {
    guard let page = page(windowId) else { return "null" }
    let controller = SidebarDragController.of(page)
    var probe = controller.probe()
    probe["folderPanel"] = controller.foreignFolder
    probe["escaping"] = shared.escaping
    probe["lastDrop"] = shared.lastDrop
    let json = (try? JSONSerialization.data(withJSONObject: probe)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    lock.withLock { snapshots[windowId] = json }
    return json
  }

  static func external(windowId: String, phase: String, at: CGPoint, count: Int) -> String? {
    guard let page = page(windowId) else { return nil }
    let controller = SidebarDragController.of(page)
    defer { if SidebarDragHub.probing { refresh(windowId) } }
    switch phase {
    case "enter":
      controller.beginExternal(count: count, at: at)
    case "move":
      controller.moveExternal(at)
    case "leave":
      _ = controller.finishExternal(commit: false)
    case "drop":
      controller.moveExternal(at)
      guard let placement = controller.finishExternal(commit: true) else { return nil }
      return placement.dragText
    default:
      break
    }
    return nil
  }

  static func panel(windowId: String, _ frameJSON: String?) {
    guard let page = page(windowId) else { return }
    let controller = SidebarDragController.of(page)
    controller.setFolderPanel(frameJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) })
  }
}

@MainActor
private final class EndReply {
  private var taken = false

  func open() -> Bool {
    defer { taken = true }
    return !taken
  }
}
