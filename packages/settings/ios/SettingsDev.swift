import AppKit
import ArdiaShell
import SolaraStore
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
      let header = NativeSettingsWindow.window?.title == title
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
    case "backdrop":
      return json(["views": backdrop(window?.contentView?.superview, active: argument == "active")])
    case "windows":
      let list = NSApp.windows.map { "\(type(of: $0)) #\($0.windowNumber) '\($0.title)' visible=\($0.isVisible) key=\($0.isKeyWindow)" }
      return json(["windows": list])
    case "websiteEngine":
      guard let model = NativeSettingsHandle.model else { return #"{"error":"no store"}"# }
      let parts = (argument ?? "").split(separator: " ", maxSplits: 1).map(String.init)
      EnginesAdapter(model: model).setWebsiteEngine(parts.first ?? "", parts.count > 1 ? parts[1] : nil)
    case "resetDeveloperModeSites":
      guard let model = NativeSettingsHandle.model else { return #"{"error":"no store"}"# }
      AdvancedAdapter(model: model).resetDeveloperModeSites()
    case "disableSearchExtension":
      guard let model = NativeSettingsHandle.model, let argument else { return #"{"error":"no store"}"# }
      let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
      Task { await SearchEngineAdapter(model: model).disableExtension(profile: parts.count > 1 ? parts[1] : "", extensionId: parts[0]) }
    case "diagnostics":
      return json(["active": NativeAppIntegration.active, "report": NativeAppIntegration.shared.diagnostics()])
    case "feedback":
      switch NativeAppIntegration.shared.feedbackTarget() {
      case .page(let url): return json(["page": url])
      case .mail(let draft, _): return json(["mail": draft])
      }
    case "sendFeedback":
      NativeAppIntegration.shared.sendFeedback(argument)
    #if DEBUG
    case "script":
      let env = ProcessInfo.processInfo.environment
      guard env["ARDIA_BACKGROUND"] == "1", env["ARDIA_DATA_DIR"]?.isEmpty == false else { return #"{"error":"test instances only"}"# }
      guard let data = argument?.data(using: .utf8), let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let run = ShellScripting.nativeCommand
      else { return #"{"error":"no native scripting"}"# }
      let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
      var answer: [String: Any] = ["pending": true]
      let handled = run(body) { result, error in answer = ["result": result ?? NSNull(), "error": error ?? NSNull()] }
      answer["handled"] = handled
      answer["windows"] = ShellScripting.windows.count
      answer["frontBefore"] = frontBefore
      answer["frontAfter"] = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
      answer["active"] = NSApp.isActive
      return json(answer)
    #endif
    case "front":
      return json(["front": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, "active": NSApp.isActive])
    case "scriptState":
      guard let state = NativeStoreHandle.store?.state else { return #"{"error":"no store"}"# }
      return json(ScriptState.build(state, loading: ShellScripting.loadingTabs))
    case "handoff":
      let activities = NSApp.windows.compactMap { window -> [String: Any]? in
        guard let activity = window.userActivity else { return nil }
        return ["window": window.windowNumber, "url": activity.webpageURL?.absoluteString as Any, "title": activity.title as Any]
      }
      return json(["handoff": activities])
    default:
      return #"{"error":"unknown action"}"#
    }
    return json(state(window))
  }

  static func backdrop(_ view: NSView?, active: Bool) -> [[String: Any]] {
    guard let view, let window = view.window else { return [] }
    var found: [[String: Any]] = []
    let name = String(describing: type(of: view))
    let frame = view.convert(view.bounds, to: nil)
    let fill = view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0
    if let effect = view as? NSVisualEffectView {
      if active { effect.state = .active }
      found.append([
        "view": name, "frame": "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))",
        "material": effect.material.rawValue, "blending": effect.blendingMode == .behindWindow ? "behindWindow" : "withinWindow",
        "state": effect.state.rawValue, "hidden": effect.isHiddenOrHasHiddenAncestor,
      ])
    } else if name.localizedCaseInsensitiveContains("glass") || name.localizedCaseInsensitiveContains("backdrop") || view.isOpaque || fill > 0.01 {
      found.append([
        "view": name, "frame": "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))",
        "opaque": view.isOpaque, "fill": fill, "hidden": view.isHiddenOrHasHiddenAncestor,
      ])
    }
    if view === window.contentView?.superview {
      found.append(["window": "opaque=\(window.isOpaque) background=\(window.backgroundColor.alphaComponent) titlebarTransparent=\(window.titlebarAppearsTransparent)"])
    }
    for child in view.subviews { found += backdrop(child, active: active) }
    return found
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
