import AppKit
import ExpoModulesCore
import SolaraModel
import SolaraStore
import SolaraUI

public class SidebarDragModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraSidebarDrag")

    OnCreate { DispatchQueue.main.async { MainActor.assumeIsolated { SidebarDragHub.bridge = NativeSidebarDrag.shared } } }

    AsyncFunction("tabDrag") { (outside: Bool, onPage: Bool) in
      MainActor.assumeIsolated { SidebarDragHub.tabDragChanged(outside: outside, onPage: onPage) }
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
  private var pendingMove: (windowId: String, x: CGFloat, y: CGFloat)?

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
    send("sidebar.drag.begin", [windowId, tabId ?? NSNull(), tabIds])
  }

  func dragPicture(windowId: String, size: CGSize, grab: CGPoint) {
    send("sidebar.drag.picture", [windowId, size.width, size.height, grab.x, grab.y])
  }

  func dragMoved(windowId: String, x: CGFloat, y: CGFloat) {
    let queued = pendingMove != nil
    pendingMove = (windowId, x, y)
    if queued { return }
    let previous = chain
    chain = Task { @MainActor in
      await previous?.value
      guard let move = self.pendingMove else { return }
      self.pendingMove = nil
      _ = try? await SettingsJS.shared.invoke("sidebar.drag.move", [move.windowId, move.x, move.y])
    }
  }

  func dragEnded(windowId: String, commit: Bool, done: @escaping @MainActor (Bool) -> Void) {
    send("sidebar.drag.end", [windowId, commit]) { result in done((result as? Bool) ?? false) }
  }

  func drop(windowId: String, ids: [String], drop: JSONValue, sequence: [String]?) {
    if let store = NativeStoreHandle.store {
      _ = try? store.dispatch(Command("dropTabs", [JSONValue(ids), drop]), origin: .native)
    }
    if let sequence, sequence.contains(where: { $0.hasPrefix(SidebarLive.prefix) }) {
      send("sidebar.drag.live", [sequence])
    }
  }

  func escapeCapture(_ on: Bool) { send("sidebar.drag.escape", [on]) }

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
