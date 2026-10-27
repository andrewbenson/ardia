import AppKit

public enum DevPointer {
  public static let changed = Notification.Name("SolaraDevPointerChanged")

  @MainActor
  static func inside(_ view: NSView, _ note: Notification) -> Bool {
    guard let window = view.window, !view.isHiddenOrHasHiddenAncestor, let screen = (note.object as? NSValue)?.pointValue else { return false }
    return view.bounds.contains(view.convert(window.convertPoint(fromScreen: screen), from: nil))
  }

  @MainActor
  static func observe(_ view: NSView, _ selector: Selector) {
    NotificationCenter.default.addObserver(view, selector: selector, name: changed, object: nil)
  }
}
