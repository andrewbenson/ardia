import AppKit
import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum NativeToolTour {
  nonisolated static let kind = "toolTour"

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeToolTour, defaultOn: false)
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
