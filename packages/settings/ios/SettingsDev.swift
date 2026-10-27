import AppKit
import SolaraUI

@MainActor
enum SettingsDev {
  private static var awaiting: (pane: String, asked: Date, done: (String) -> Void)?

  static func paneAppeared(_ pane: String) {
    guard let waiting = awaiting, waiting.pane == pane else { return }
    awaiting = nil
    let title = NativeSettingsWindow.makeContext().flatMap { context in context.shown.map(context.title(for:)) } ?? ""
    firstFrame(showing: title, turns: 60) { first in
      let shownAfter = Date().timeIntervalSince(waiting.asked) * 1000
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        let settled = capture()
        waiting.done(json(["shownAfter": shownAfter, "first": first, "settled": settled]))
      }
    }
  }

  static func firstFrame(showing title: String, turns: Int, _ done: @escaping ([String: Any]) -> Void) {
    DispatchQueue.main.async {
      let snapshot = capture()
      let texts = (snapshot["texts"] as? [[Any]]) ?? []
      let header = texts.contains { entry in
        (entry.first as? String)?.hasPrefix("root/_NSGraphicsView:0/") == true && (entry.last as? String) == title
      }
      if turns <= 0 || header {
        NativeSettingsWindow.window?.contentView?.layoutSubtreeIfNeeded()
        return done(capture())
      }
      firstFrame(showing: title, turns: turns - 1, done)
    }
  }

  static func switchPane(_ pane: String, done: @escaping (String) -> Void) {
    guard NativeSettingsWindow.window != nil else { return done(#"{"error":"no window"}"#) }
    awaiting = (pane, Date(), done)
    NativeSettingsWindow.navigate(pane: pane, profileId: nil, detail: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard let waiting = awaiting, waiting.pane == pane else { return }
      awaiting = nil
      done(#"{"error":"the pane never appeared"}"#)
    }
  }

  static func capture() -> [String: Any] {
    guard let window = NativeSettingsWindow.window, let root = window.contentView else { return [:] }
    var frames: [[Any]] = []
    var texts: [[Any]] = []
    func rounded(_ rect: NSRect) -> [Double] {
      let top = root.bounds.height - rect.maxY
      return [Double(rect.minX), Double(top), Double(rect.width), Double(rect.height)].map { ($0 * 2).rounded() / 2 }
    }
    func walk(_ view: NSView, _ path: String) {
      guard !view.isHidden else { return }
      frames.append([path, rounded(view.convert(view.bounds, to: root))])
      if let text = view as? OnboardingTextNSView { texts.append([path, text.text]) }
      if let field = view as? NSTextField { texts.append([path, field.stringValue]) }
      var counts: [String: Int] = [:]
      for child in view.subviews {
        let name = String(describing: type(of: child))
        let index = counts[name, default: 0]
        counts[name] = index + 1
        walk(child, "\(path)/\(name):\(index)")
      }
    }
    walk(root, "root")
    let hosting = NativeSettingsWindow.window?.contentViewController?.view
    let switches: [[Any]] = SettingsProbe.switches.values.map { probe in
      let frame = hosting.map { root.convert($0.isFlipped ? probe.frame : NSRect(x: probe.frame.minX, y: $0.bounds.height - probe.frame.maxY, width: probe.frame.width, height: probe.frame.height), from: $0) } ?? probe.frame
      return [rounded(frame).map { String($0) }.joined(separator: ","), probe.on]
    }
    return ["frames": frames, "texts": texts, "switches": switches]
  }

  static func search() -> [String: Any] {
    guard let context = NativeSettingsWindow.makeContext() else { return [:] }
    let search = context.search
    var out: [String: Any] = [
      "query": search.query, "results": search.results.map(\.id), "selected": search.selected,
      "pane": context.navigation.pane.rawValue, "focusRequest": search.focusRequest,
    ]
    if let flash = search.flash {
      out["flash"] = flash.id
      if let frame = context.anchorFrames[flash.id] {
        out["anchor"] = [frame.minX, frame.minY, frame.width, frame.height]
        out["viewport"] = [context.viewport.minX, context.viewport.minY, context.viewport.width, context.viewport.height]
      }
    }
    return out
  }

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
    case "search":
      return json(search())
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
