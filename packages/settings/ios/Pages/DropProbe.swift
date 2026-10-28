import AppKit
import SolaraUI

@MainActor
enum DropProbe {
  static func target(windowNumber: Int, x: Double, y: Double, type pasteboardType: String) -> [String: Any] {
    guard let window = NSApp.windows.first(where: { $0.windowNumber == windowNumber }), let frameView = window.contentView?.superview else { return ["error": "no window"] }
    let point = NSPoint(x: x, y: frameView.bounds.height - y)
    let wanted = NSPasteboard.PasteboardType(pasteboardType)
    var chosen: NSView?
    func walk(_ view: NSView) {
      guard !view.isHidden, view.alphaValue > 0 else { return }
      let local = view.convert(point, from: nil)
      guard view.bounds.contains(local) else { return }
      if view.registeredDraggedTypes.contains(wanted) { chosen = view }
      for sub in view.subviews { walk(sub) }
    }
    walk(frameView)
    var chain: [String] = []
    var node = chosen
    while let current = node, chain.count < 5 {
      chain.append(String(describing: type(of: current)))
      node = current.superview
    }
    return ["view": chain.first ?? NSNull(), "chain": chain]
  }
}

extension DropProbe {
  static func frame(windowNumber: Int, classContains query: String) -> [String: Any] {
    guard let window = NSApp.windows.first(where: { $0.windowNumber == windowNumber }), let frameView = window.contentView?.superview else { return ["error": "no window"] }
    let parts = query.split(separator: "^", maxSplits: 1)
    let needle = String(parts.first ?? "")
    let levelsUp = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    let height = frameView.bounds.height
    var found: NSView?
    func walk(_ view: NSView) {
      guard found == nil, !view.isHiddenOrHasHiddenAncestor else { return }
      if String(describing: type(of: view)).contains(needle), view.bounds.width > 20, view.bounds.height > 20 { found = view; return }
      view.subviews.forEach(walk)
    }
    walk(frameView)
    guard var found else { return ["found": false] }
    for _ in 0..<levelsUp { if let parent = found.superview { found = parent } }
    let r = found.convert((found as? PopoverView)?.cardFrame ?? found.bounds, to: nil)
    return ["found": true, "class": String(describing: type(of: found)), "x": r.minX, "y": height - r.maxY, "width": r.width, "height": r.height]
  }

  static func json(_ value: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }
}
