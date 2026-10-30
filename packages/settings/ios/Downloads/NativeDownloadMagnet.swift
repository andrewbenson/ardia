import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativeDownloadMagnet {
  static let kind = "downloadMagnet"
  private static let views = NSMapTable<NSString, DownloadMagnetView>.strongToWeakObjects()

  static func register() {
    HostedViews.register(kind) { windowId in
      let view = DownloadMagnetView(frame: .zero)
      views.setObject(view, forKey: windowId as NSString)
      return HostedContent(
        view: view, onUnmount: { view.reset() }, takesFocus: false,
        onState: { [weak view] json in view?.apply(json: json) })
    }
  }

  static func describe(_ windowId: String) -> String {
    guard let view = views.object(forKey: windowId as NSString) else { return "null" }
    let icon = view.layer?.sublayers?.first
    let shown = icon?.presentation() ?? icon
    var info: [String: Any] = [
      "flights": view.flights,
      "animating": !(icon?.animationKeys() ?? []).isEmpty,
      "inWindow": view.window != nil,
      "size": [view.bounds.width, view.bounds.height],
      "hasIcon": icon?.contents != nil,
      "position": [shown?.position.x ?? 0, shown?.position.y ?? 0],
      "opacity": Double(shown?.opacity ?? 0),
      "restingPosition": [icon?.position.x ?? 0, icon?.position.y ?? 0],
      "restingOpacity": Double(icon?.opacity ?? 0),
    ]
    if let flying = view.flying { info["flying"] = flying }
    guard let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}
