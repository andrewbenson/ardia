import AppKit
import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum NativeDownloadMagnet {
  static let kind = "downloadMagnet"

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeDownloadMagnet, defaultOn: false)
  }

  static func register() {
    guard enabled else { return }
    HostedViews.register(kind) { _ in
      let view = DownloadMagnetView(frame: .zero)
      return HostedContent(
        view: view, onUnmount: { view.reset() }, takesFocus: false,
        onState: { [weak view] json in view?.apply(json: json) })
    }
  }
}
