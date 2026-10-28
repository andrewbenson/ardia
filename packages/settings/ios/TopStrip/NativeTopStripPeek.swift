import AppKit
import Foundation
import SolaraUI

struct StripPeekHostState: Decodable, Equatable {
  var strip: String
  var controls: StripControlsState
  var theme: [String: String]
  var enabled: Bool
  var held: Bool
  var bandLeft: Double
  var look: StripPeekLook

  static func decode(_ json: String) -> StripPeekHostState? {
    json.data(using: .utf8).flatMap { try? JSONDecoder().decode(StripPeekHostState.self, from: $0) }
  }
}

@MainActor
final class TopStripPeekHost {
  static var hosts: [String: TopStripPeekHost] = [:]

  let windowId: String
  let strip: TopStripHost
  let row: StripPeekRow
  let view = StripPeekView()
  private var state: StripPeekHostState?

  init(windowId: String) {
    self.windowId = windowId
    strip = TopStripHost(windowId: windowId, takesDrops: false)
    row = StripPeekRow(strip: strip.view)
    view.content = row
    view.peek.held = { [weak self] in self?.state?.held ?? false }
    row.controls.onAction = { [weak self] action in self?.handle(action) }
    row.onPageWidth = { [weak self] width in self?.strip.pageWidth = Double(width) }
    view.onLive = { [weak self] live in self?.send("live", ["live": live, "pageWidth": Double(self?.row.pageWidth ?? 0)]) }
  }

  func stop() {
    strip.stop()
    view.peek.stop()
    view.setEnabled(false)
  }

  func apply(_ json: String) {
    guard let next = StripPeekHostState.decode(json), next != state else { return }
    let released = state?.held == true && !next.held
    state = next
    view.look = next.look
    view.bandLeft = CGFloat(next.bandLeft)
    row.controls.update(next.controls, theme: next.theme)
    row.needsLayout = true
    strip.apply(next.strip)
    view.setEnabled(next.enabled)
    if released { view.peek.recheck() }
  }

  private func handle(_ action: StripControlAction) {
    switch action {
    case .profileMenu: send("profileMenu")
    case .toggleDownloads: send("toggleDownloads")
    }
  }

  private func send(_ name: String, _ extra: [String: Any] = [:]) {
    let windowId = windowId
    let payload = SidebarPayload(extra)
    Task { @MainActor in _ = await SettingsAdapters.js("topStrip.peek.action", windowId, name, payload.value) }
  }

  func describe() -> [String: Any] {
    let content = view.window?.contentView
    func inWindow(_ rect: NSRect?) -> [Double]? {
      guard let rect, let content else { return nil }
      return [rect.minX, content.bounds.height - rect.maxY, rect.width, rect.height].map(Double.init)
    }
    return [
      "live": view.live, "slide": view.slideValue, "watching": view.watching,
      "panel": inWindow(view.live ? view.panel.convert(view.panel.bounds, to: nil) : nil) ?? NSNull(),
      "downloads": inWindow(row.controls.downloadsRect) ?? NSNull(),
      "pageWidth": strip.pageWidth ?? 0,
    ]
  }

  static func register() {
    HostedViews.register(NativeTopStrip.peekKind) { windowId in
      let host = TopStripPeekHost(windowId: windowId)
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
    TopStripControlsHost.register()
  }
}

struct StripControlsHostState: Decodable, Equatable {
  var controls: StripControlsState
  var theme: [String: String]
}

struct StripGlowHostState: Decodable, Equatable {
  var over: Bool
  var accent: String
  var dark: Bool
}

@MainActor
final class TopStripControlsHost {
  static let kind = "topStripControls"
  static var hosts: [String: TopStripControlsHost] = [:]

  let windowId: String
  let view = StripControlsView()
  private var state: StripControlsHostState?

  init(windowId: String) {
    self.windowId = windowId
    view.onAction = { [weak self] action in self?.handle(action) }
  }

  func apply(_ json: String) {
    guard let next = json.data(using: .utf8).flatMap({ try? JSONDecoder().decode(StripControlsHostState.self, from: $0) }), next != state else { return }
    state = next
    view.update(next.controls, theme: next.theme)
  }

  private func handle(_ action: StripControlAction) {
    let windowId = windowId
    let name = action == .profileMenu ? "profileMenu" : "toggleDownloads"
    Task { @MainActor in _ = await SettingsAdapters.js("topStrip.peek.action", windowId, name, SidebarPayload([:]).value) }
  }

  static func register() {
    HostedViews.register(kind) { windowId in
      let host = TopStripControlsHost(windowId: windowId)
      hosts[windowId] = host
      return HostedContent(
        view: host.view,
        onUnmount: { [weak host] in if hosts[windowId] === host { hosts[windowId] = nil } },
        takesFocus: false,
        onState: { [weak host] json in host?.apply(json) })
    }
    TopStripGlowHost.register()
  }
}

@MainActor
final class TopStripGlowHost {
  static let kind = "topStripGlow"
  static var hosts: [String: TopStripGlowHost] = [:]

  let view = StripDropGlow()

  func apply(_ json: String) {
    guard let next = json.data(using: .utf8).flatMap({ try? JSONDecoder().decode(StripGlowHostState.self, from: $0) }) else { return }
    view.set(over: next.over, accent: next.accent, dark: next.dark)
  }

  static func register() {
    HostedViews.register(kind) { windowId in
      let host = TopStripGlowHost()
      hosts[windowId] = host
      return HostedContent(
        view: host.view,
        onUnmount: { [weak host] in if hosts[windowId] === host { hosts[windowId] = nil } },
        takesFocus: false,
        onState: { [weak host] json in host?.apply(json) })
    }
  }
}
