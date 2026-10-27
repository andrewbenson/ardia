import AppKit
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

public class TopStripModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraTopStrip")

    OnCreate { DispatchQueue.main.async { MainActor.assumeIsolated { NativeTopStrip.register() } } }

    AsyncFunction("items") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeTopStrip.items(windowId: windowId) ?? "null" }
    }.runOnQueue(.main)

    AsyncFunction("hoverShifts") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeTopStrip.hoverShifts(windowId: windowId) ?? "null" }
    }.runOnQueue(.main)

    AsyncFunction("groupSize") { (windowId: String, groupId: String) -> Double? in
      MainActor.assumeIsolated { NativeTopStrip.hosts[windowId]?.view.current?.groupSize(groupId) }
    }.runOnQueue(.main)

    AsyncFunction("keys") { (windowId: String, profileId: String) -> [String] in
      MainActor.assumeIsolated { NativeStoreHandle.store.map { StripQuery($0.state).keys(windowId: windowId, profileId: profileId) } ?? [] }
    }.runOnQueue(.main)
  }
}

@MainActor
enum NativeTopStrip {
  static let kind = "topStrip"
  static var hosts: [String: TopStripHost] = [:]

  nonisolated static var enabled: Bool {
    ProcessInfo.processInfo.environment["ARDIA_NATIVE_TOP_STRIP"] == "1"
  }

  static func register() {
    guard enabled else { return }
    HostedViews.register(kind) { windowId in
      let host = TopStripHost(windowId: windowId)
      hosts[windowId] = host
      return HostedContent(
        view: host.view,
        onUnmount: { [weak host] in
          host?.stop()
          if hosts[windowId] === host { hosts[windowId] = nil }
        },
        takesFocus: false,
        onState: { [weak host] json in host?.apply(json) })
    }
  }

  static func json(_ value: Any) -> String? {
    (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) }
  }

  static func items(windowId: String) -> String? {
    guard let host = hosts[windowId], let page = host.view.current, let window = page.window, let content = window.contentView else { return nil }
    let items = page.describe().map { item -> [String: Any] in
      var out = item
      let frame = NSRect(x: item["x"] as? CGFloat ?? 0, y: item["y"] as? CGFloat ?? 0, width: item["width"] as? CGFloat ?? 0, height: item["height"] as? CGFloat ?? 0)
      let inWindow = page.convert(frame, to: nil)
      out["windowX"] = inWindow.minX
      out["windowY"] = content.bounds.height - inWindow.maxY
      return out
    }
    return json(["items": items, "chip": page.pageLayout.chip, "scrolled": page.scrolledX, "keys": page.pageLayout.items.map(\.key)])
  }

  static func hoverShifts(windowId: String) -> String? {
    guard let page = hosts[windowId]?.view.current else { return nil }
    let result = page.hoverShifts()
    return json(["hovered": result.hovered, "shifts": result.shifts])
  }
}

final class TopStripCommits: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: BrowserState?
  private var scheduled = false
  weak var host: TopStripHost?

  func receive(_ state: BrowserState) {
    if Thread.isMainThread {
      lock.withLock { latest = nil }
      MainActor.assumeIsolated { host?.commit(state) }
      return
    }
    let schedule = lock.withLock { () -> Bool in
      latest = state
      if scheduled { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      let state = lock.withLock { () -> BrowserState? in
        scheduled = false
        defer { latest = nil }
        return latest
      }
      guard let state else { return }
      MainActor.assumeIsolated { host?.commit(state) }
    }
  }
}

@MainActor
final class TopStripHost {
  let windowId: String
  let view: TopStripView
  private var hostState: StripHostState?
  private var state: BrowserState?
  private var listener: Int?
  private let commits = TopStripCommits()
  private var markUri: String?
  private var pagerObserver: NSObjectProtocol?

  init(windowId: String) {
    self.windowId = windowId
    view = TopStripView(windowId: windowId)
    view.favicons.loader = { request in try await NativeSidebar.favicon(request) }
    view.onAction = { [weak self] action in self?.handle(action) }
    commits.host = self
    pagerObserver = NotificationCenter.default.addObserver(forName: Notification.Name("ArdiaPagerPosition"), object: nil, queue: nil) {
      [weak self] note in
      guard note.userInfo?["key"] as? String == windowId, let position = note.userInfo?["position"] as? Double else { return }
      MainActor.assumeIsolated { self?.view.setPagerPosition(position) }
    }
    if let store = NativeStoreHandle.store {
      state = store.state
      let sink = commits
      listener = store.subscribe { commit in sink.receive(commit.state) }
    }
  }

  func stop() {
    if let listener { NativeStoreHandle.store?.unsubscribe(listener) }
    listener = nil
    if let pagerObserver { NotificationCenter.default.removeObserver(pagerObserver) }
    pagerObserver = nil
  }

  func apply(_ json: String) {
    guard let next = StripHostState.decode(json) else { return }
    if next == hostState { return }
    hostState = next
    loadMark(next.newTabMark)
    render()
  }

  func commit(_ next: BrowserState) {
    state = next
    render()
  }

  private func render() {
    guard let hostState, let state = state ?? NativeStoreHandle.store?.state else { return }
    self.state = state
    view.update(state: state, host: hostState)
  }

  private func loadMark(_ uri: String?) {
    guard let uri, uri != markUri else { return }
    markUri = uri
    if let image = SettingsAdapters.image(uri) {
      image.isTemplate = true
      view.favicons.newTabMark = image
      return
    }
    guard let url = URL(string: uri) else { return }
    Task { @MainActor [weak self] in
      let image = await Task.detached { (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) }.value
      guard let self, let image else { return }
      image.isTemplate = true
      self.view.favicons.newTabMark = image
      self.render()
    }
  }

  private func handle(_ action: StripAction) {
    switch action {
    case .click(let tabId, let mods):
      call("click", tabId, ["meta": mods.meta, "shift": mods.shift, "alt": mods.alt])
    case .activate(let tabId):
      if !dispatch("activate", tabId) { call("activate", tabId) }
    case .close(let tabId): call("close", tabId)
    case .toggleMute(let tabId): call("toggleMute", tabId)
    case .tabMenu(let tabId): call("tabMenu", tabId)
    case .groupMenu(let groupId): call("groupMenu", groupId)
    case .toggleGroup(let groupId, let collapse): call("toggleGroup", groupId, ["collapse": collapse])
    case .closeGroup(let groupId): call("closeGroup", groupId)
    case .tuck(let groupId): call("tuck", groupId)
    case .folderMenu(let groupId): call("folderMenu", groupId)
    case .tileFolder(let folderId): call("tileFolder", folderId)
    case .tileFolderMenu(let folderId): call("tileFolderMenu", folderId)
    case .newTab(let split): call("newTab", "", ["split": split])
    }
  }

  private func dispatch(_ name: String, _ tabId: String) -> Bool {
    guard let store = NativeStoreHandle.store else { return false }
    do {
      _ = try store.dispatch(Command(name, [.string(tabId)]), origin: .native)
      return true
    } catch {
      return false
    }
  }

  private func call(_ name: String, _ id: String, _ extra: [String: Any] = [:]) {
    let windowId = windowId
    let payload = SidebarPayload(extra)
    Task { @MainActor in
      _ = await SettingsAdapters.js("topStrip.action", windowId, name, id, payload.value)
    }
  }
}
