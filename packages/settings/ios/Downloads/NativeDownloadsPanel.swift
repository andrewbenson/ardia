import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativeDownloadsPanel {
  static let topic = "downloads.panel"
  private static var started = false
  private static var panels: [String: DownloadsPanelView] = [:]

  static func start() {
    guard NativeWindowShell.enabled, !started else { return }
    started = true
    _ = SettingsJS.shared.observe(topic) { value in apply(value) }
    apply(SettingsJS.shared.latestValue(topic))
  }

  private static func apply(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, panel) in panels where windows[windowId] == nil {
      panel.removeFromSuperview()
      panels[windowId] = nil
    }
    for (windowId, json) in windows {
      guard let json = json as? String, let state = DownloadsPanelState.decode(json), let overlay = NativeWindowShell.overlay(windowId) else { continue }
      let panel = panels[windowId] ?? make(windowId)
      if panel.superview !== overlay {
        panel.frame = overlay.bounds
        panel.autoresizingMask = [.width, .height]
        overlay.addSubview(panel)
      }
      panel.update(state)
    }
  }

  private static func make(_ windowId: String) -> DownloadsPanelView {
    let panel = DownloadsPanelView(frame: .zero)
    DownloadsHoverShifts.shown.add(panel.list)
    panel.onDismiss = { send(windowId, ["kind": "dismiss"]) }
    panel.onClosed = { send(windowId, ["kind": "closed"]) }
    panel.onEvent = { e in
      let (kind, id): (String, String?) =
        switch e {
        case .open(let id): ("open", id)
        case .reveal(let id): ("reveal", id)
        case .pause(let id): ("pause", id)
        case .resume(let id): ("resume", id)
        case .keep(let id): ("keep", id)
        case .cancel(let id): ("cancel", id)
        case .menu(let id): ("menu", id)
        case .clear: ("clear", nil)
        case .viewAll: ("viewAll", nil)
        }
      send(windowId, ["kind": kind, "id": id ?? NSNull()])
    }
    panels[windowId] = panel
    return panel
  }

  private static func send(_ windowId: String, _ event: [String: Any]) {
    Task { @MainActor in _ = await SettingsAdapters.js("downloads.panel", windowId, event) }
  }

  static func describe(_ windowId: String) -> String {
    guard let info = read(windowId) else { return "null" }
    let data = try? JSONSerialization.data(withJSONObject: info)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }

  static func read(_ windowId: String) -> [String: Any]? {
    guard let panel = panels[windowId], panel.superview != nil else { return nil }
    func inWindow(_ view: NSView, _ r: CGRect) -> [Double] {
      let w = view.convert(r, to: nil)
      let h = view.window?.contentView?.bounds.height ?? 0
      return [w.minX, h - w.maxY, w.width, w.height]
    }
    var controls: [String: [Double]] = [:]
    func walk(_ view: NSView) {
      if view.accessibilityRole() == .button, let name = view.accessibilityLabel(), !name.isEmpty { controls[name] = inWindow(view, view.bounds) }
      view.subviews.forEach(walk)
    }
    walk(panel.list)
    let info: [String: Any] = [
      "card": panel.cardFrame.map { inWindow(panel, $0) } ?? NSNull(), "list": inWindow(panel.list, panel.list.bounds), "opacity": panel.presentedOpacity,
      "progress": panel.progress, "closing": panel.isClosing, "controls": controls,
    ]
    return info
  }
}

#if SOLARA_PROBES
@MainActor
public enum DownloadsPanelRead {
  public static func panel(windowId: String) -> [String: Any]? {
    guard var info = NativeDownloadsPanel.read(windowId) else { return nil }
    let controls = info["controls"] as? [String: [Double]] ?? [:]
    info["controls"] = controls.filter { ["View all downloads", "Clear"].contains($0.key) }
    return info
  }
}
#endif
