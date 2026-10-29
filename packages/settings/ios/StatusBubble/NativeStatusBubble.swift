import AppKit
import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum NativeStatusBubble {
  static let kind = "statusBubble"

  static func register() {
    HostedViews.register(kind) { _ in
      let host = StatusBubbleHost()
      return HostedContent(
        view: host, onUnmount: { host.model.reset() }, takesFocus: false,
        onState: { [weak host] json in host.map { apply(json, to: $0) } })
    }
  }

  static func apply(_ json: String, to host: StatusBubbleHost) {
    guard let data = json.data(using: .utf8), let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
    host.setDark(state["dark"] as? Bool)
    host.model.setStatus(state["text"] as? String ?? "")
  }
}
