import AppKit
import SolaraUI

@MainActor
enum SettingsDev {
  static func drive(_ action: String, _ argument: String?) -> String {
    let window = NativeSettingsWindow.window
    switch action {
    case "state":
      break
    case "close":
      window?.performClose(nil)
    case "type":
      guard let window else { return #"{"error":"no window"}"# }
      for character in argument ?? "" {
        let text = String(character)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: keyCode(text))
          if let event { window.sendEvent(event) }
        }
      }
    case "windows":
      let list = NSApp.windows.map { "\(type(of: $0)) #\($0.windowNumber) '\($0.title)' visible=\($0.isVisible) key=\($0.isKeyWindow)" }
      return json(["windows": list])
    default:
      return #"{"error":"unknown action"}"#
    }
    return json(state(window))
  }

  static func keyCode(_ text: String) -> UInt16 {
    switch text {
    case "\r": 36
    case "\t": 48
    case "\u{1b}": 53
    default: 0
    }
  }

  static func state(_ window: NSWindow?) -> [String: Any] {
    guard let window else { return ["window": false] }
    let context = NativeSettingsWindow.makeContext()
    return [
      "window": window.windowNumber, "visible": window.isVisible, "key": window.isKeyWindow, "canBecomeKey": window.canBecomeKey,
      "title": window.title, "toolbarItems": window.toolbar?.items.count ?? -1,
      "firstResponder": describe(window.firstResponder), "query": context?.search.query ?? "",
      "pane": context?.navigation.pane.rawValue ?? "",
    ]
  }

  static func describe(_ responder: NSResponder?) -> String {
    var parts: [String] = []
    var view = responder as? NSView
    if view == nil, let responder { return String(describing: type(of: responder)) }
    while let current = view, parts.count < 4 {
      parts.append(String(describing: type(of: current)))
      view = current.superview
    }
    return parts.joined(separator: " < ")
  }

  static func json(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }
}
