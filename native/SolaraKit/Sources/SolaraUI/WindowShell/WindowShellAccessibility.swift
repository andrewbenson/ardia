import AppKit

extension WindowShellView {
  public func accessibilityReach(limit: Int = 4000) -> [String: Int] {
    guard let window else { return [:] }
    var counts: [String: Int] = [:]
    var seen = Set<ObjectIdentifier>()
    var queue: [Any] = window.accessibilityChildren() ?? []
    var visited = 0
    while !queue.isEmpty, visited < limit {
      let element = queue.removeFirst()
      guard let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
      visited += 1
      counts[reachedLayer(object), default: 0] += 1
      if let children = (object as? NSAccessibilityProtocol)?.accessibilityChildren() { queue.append(contentsOf: children) }
    }
    if visited >= limit { counts["truncated"] = 1 }
    return counts
  }

  private func reachedLayer(_ element: NSObject) -> String {
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      if let button = window?.standardWindowButton(kind), element === button || element === button.cell { return "titlebar" }
    }
    var cursor: Any? = (element as? NSCell)?.controlView ?? element
    while let current = cursor {
      if let view = current as? NSView {
        if !view.isDescendant(of: self) { return "outside:\(type(of: view))" }
        for slot in Slot.allCases { if let mounted = self.view(in: slot), view.isDescendant(of: mounted) { return slot.rawValue } }
        return view.isDescendant(of: hiddenPages) ? "hiddenPages" : "shell"
      }
      cursor = (current as? NSAccessibilityProtocol)?.accessibilityParent()
    }
    return "unparented:\(type(of: element))"
  }
}
