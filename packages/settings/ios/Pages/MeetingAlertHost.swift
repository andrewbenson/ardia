import AppKit
import SolaraUI

@MainActor
enum MeetingAlertHost {
  private static var frames: [String: MeetingAlertFrameView] = [:]

  static func show(windowId: String, json: String, left: Double, top: Double, send: @escaping ([String: Any]) -> Void) -> Bool {
    guard let overlay = NativeWindowShell.overlay(windowId) else { return false }
    let view = frames[windowId] ?? {
      let made = MeetingAlertFrameView(frame: .zero)
      overlay.addSubview(made)
      frames[windowId] = made
      return made
    }()
    if view.superview !== overlay { overlay.addSubview(view) }
    view.onEvent = { event in
      switch event {
      case .dismiss: send(["windowId": windowId, "kind": "dismiss"])
      case .join(_, let all): send(["windowId": windowId, "kind": "join", "all": all])
      case .view: send(["windowId": windowId, "kind": "view"])
      default: break
      }
    }
    view.onHeight = { [weak view] height in
      guard let view else { return }
      view.frame.size.height = height
    }
    view.frame = CGRect(x: left, y: top, width: Double(MeetingAlertFrameMetrics.width), height: Double(view.height))
    view.apply(json: json)
    return true
  }

  static func hide(windowId: String) {
    frames.removeValue(forKey: windowId)?.removeFromSuperview()
  }
}
