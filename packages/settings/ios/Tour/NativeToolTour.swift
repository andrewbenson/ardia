import AppKit
import ArdiaShell
import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum NativeToolTour {
  nonisolated static let kind = "toolTour"

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeToolTour)
  }

  static func register() {
    guard enabled else { return }
    HostedViews.register(kind) { windowId in
      let host = ToolTourHost()
      host.model.send = { name in HostedViews.send(kind, windowId: windowId, name, [:]) }
      return HostedContent(view: host, takesFocus: false, onState: { [weak host] json in host?.model.apply(json) })
    }
  }
}

#if SOLARA_PROBES
@MainActor
public enum ToolTourRead {
  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let root = WindowHost.window(id: windowId)?.contentView else { return nil }
    func find(_ view: NSView) -> ToolTourHost? {
      if let host = view as? ToolTourHost { return host }
      for child in view.subviews {
        if let host = find(child) { return host }
      }
      return nil
    }
    guard let host = find(root) else { return nil }
    let model = host.model
    return ["active": model.active, "visible": model.visible && !host.isHiddenOrHasHiddenAncestor,
      "index": model.index, "stops": model.stops.map(\.id)]
  }
}
#endif
