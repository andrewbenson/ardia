import AppKit
import Synchronization

public struct HostedContent {
  public let view: NSView
  public let onUnmount: (() -> Void)?

  public init(view: NSView, onUnmount: (() -> Void)? = nil) {
    self.view = view
    self.onUnmount = onUnmount
  }
}

@MainActor
public enum HostedViews {
  public typealias Make = (_ windowId: String) -> HostedContent?

  private static var makers: [String: Make] = [:]
  nonisolated private static let registered = Mutex<Set<String>>([])

  public static func register(_ kind: String, _ make: @escaping Make) {
    makers[kind] = make
    registered.withLock { _ = $0.insert(kind) }
  }

  public static func unregister(_ kind: String) {
    makers[kind] = nil
    registered.withLock { _ = $0.remove(kind) }
  }

  static func make(_ kind: String, windowId: String) -> HostedContent? {
    makers[kind]?(windowId)
  }

  nonisolated static var kinds: [String] { registered.withLock { $0.sorted() } }
}

@MainActor
final class HostedMount {
  let content: HostedContent
  private weak var window: NSWindow?
  private weak var savedResponder: NSResponder?
  private let savedSelection: NSRange?
  private var ended = false

  init(content: HostedContent, in host: NSView, window: NSWindow) {
    self.content = content
    self.window = window
    let responder = window.firstResponder
    if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
      savedResponder = field
      savedSelection = editor.selectedRange()
    } else {
      savedResponder = responder
      savedSelection = nil
    }
    content.view.frame = host.bounds
    content.view.autoresizingMask = [.width, .height]
    host.addSubview(content.view)
    window.makeFirstResponder(content.view)
  }

  func end() {
    guard !ended else { return }
    ended = true
    let hadFocus = window.map { focus(in: $0) } ?? false
    content.view.removeFromSuperview()
    content.onUnmount?()
    guard hadFocus, let window, let responder = savedResponder, restorable(responder, in: window) else { return }
    guard window.makeFirstResponder(responder) else { return }
    if let savedSelection, let editor = (responder as? NSTextField)?.currentEditor() as? NSTextView,
      NSMaxRange(savedSelection) <= (editor.string as NSString).length
    {
      editor.setSelectedRange(savedSelection)
    }
  }

  private func focus(in window: NSWindow) -> Bool {
    guard let responder = window.firstResponder as? NSView else { return window.firstResponder === window }
    if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
      return field === content.view || field.isDescendant(of: content.view)
    }
    return responder === content.view || responder.isDescendant(of: content.view)
  }

  private func restorable(_ responder: NSResponder, in window: NSWindow) -> Bool {
    if responder === window { return true }
    guard let view = responder as? NSView else { return false }
    return view.window === window && !view.isHiddenOrHasHiddenAncestor && view.acceptsFirstResponder
  }
}
