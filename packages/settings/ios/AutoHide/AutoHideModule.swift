import AppKit
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraUI

public class AutoHideModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraAutoHide")

    Events("onAutoHideEvent")

    Function("available") { () -> Bool in NativeWindowShell.enabled && LaunchSwitches.shared.isOn(.nativeAutoHide, defaultOn: false) }

    AsyncFunction("set") { (windowId: String, tabId: String, json: String) in
      let sink = AutoHideSink(self)
      MainActor.assumeIsolated {
        guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(AutoHideState.self, from: data) else { return }
        AutoHideHost.set(windowId: windowId, tabId: tabId, state: state) { kind, on in
          sink.module?.sendEvent("onAutoHideEvent", ["windowId": windowId, "tabId": tabId, "kind": kind, "on": on])
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("remove") { (windowId: String, tabId: String) in
      MainActor.assumeIsolated { AutoHideHost.remove(windowId: windowId, tabId: tabId) }
    }.runOnQueue(.main)
  }
}

struct AutoHideState: Decodable {
  struct Rect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
  }

  let mode: String
  let shownTop: Double
  let pane: Rect
  let card: String
  let band: String
  let divider: String
  let secondary: String
  let host: String
  let hasPage: Bool
}

@MainActor
enum AutoHideHost {
  private static var strips: [String: AutoHideStripView] = [:]

  private static func key(_ windowId: String, _ tabId: String) -> String { windowId + "\u{1}" + tabId }

  static func set(windowId: String, tabId: String, state: AutoHideState, send: @escaping (String, Bool) -> Void) {
    guard let shell = NativeWindowShell.host(windowId)?.shell else { return }
    let card = shell.card
    let created = strips[key(windowId, tabId)] == nil
    let strip = strips[key(windowId, tabId)] ?? {
      let made = AutoHideStripView(frame: .zero)
      if let overlays = card.subviews.last(where: { String(describing: type(of: $0)).contains("PaneOverlays") }) {
        card.addSubview(made, positioned: .below, relativeTo: overlays)
      } else {
        card.addSubview(made)
      }
      strips[key(windowId, tabId)] = made
      return made
    }()
    strip.frame = CGRect(x: state.pane.x, y: state.pane.y, width: state.pane.width, height: Double(ToolbarAutoHideMetrics.toolbarHeight))
    strip.onEvent = { event in
      switch event {
      case .reveal: send("reveal", true)
      case .peek(let on): send("peek", on)
      }
    }
    strip.onMotion = { [weak shell] _ in shell?.coverChanged() }
    strip.onFrame = { frame in
      PaneOverlays.shared.setLiveTop(CGFloat(frame.liveTop), windowId: windowId, tabId: tabId)
      NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId)?.setAutoHide(
        opacity: CGFloat(frame.controlsOpacity), scale: CGFloat(frame.toolbarScale), lift: CGFloat(-frame.toolbarLift), interactive: frame.interactive)
    }
    let mode = ToolbarAutoHideMode(rawValue: state.mode) ?? .shown
    let style = AutoHideStripStyle(
      card: CSSColor(state.card) ?? CSSColor("#FFFFFF")!, band: CSSColor(state.band) ?? CSSColor("#FFFFFF")!,
      divider: CSSColor(state.divider) ?? CSSColor("rgba(0,0,0,0.1)")!, secondary: CSSColor(state.secondary) ?? CSSColor("#00000080")!,
      host: state.host, hasPage: state.hasPage)
    strip.set(style: style, mode: mode, shownTop: state.shownTop)
    if created { PaneOverlays.shared.setLiveTop(CGFloat(strip.restingTop), windowId: windowId, tabId: tabId) }
  }

  static func remove(windowId: String, tabId: String) {
    guard let strip = strips.removeValue(forKey: key(windowId, tabId)) else { return }
    strip.removeFromSuperview()
    PaneOverlays.shared.setLiveTop(nil, windowId: windowId, tabId: tabId)
    NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId)?.setAutoHide(opacity: 1, scale: 1, lift: 0, interactive: true)
  }
}

private final class AutoHideSink: @unchecked Sendable {
  weak var module: AutoHideModule?
  init(_ module: AutoHideModule) { self.module = module }
}
