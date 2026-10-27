import AppKit
import SwiftUI

struct SettingsSearchField: NSViewRepresentable {
  @Binding var text: String
  let focusRequest: Int
  let onSubmit: () -> Void
  let onArrow: (Int) -> Void
  var placeholder = "Search"

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.isBordered = false
    field.isBezeled = false
    field.drawsBackground = false
    field.font = .systemFont(ofSize: 13)
    field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
    field.cell?.usesSingleLineMode = true
    field.cell?.lineBreakMode = .byClipping
    field.delegate = context.coordinator
    field.focusRingType = .none
    field.setAccessibilityIdentifier("settings.search")
    field.setAccessibilityRole(.textField)
    field.setAccessibilityLabel(placeholder)
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    if focusRequest != context.coordinator.lastFocusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      DispatchQueue.main.async {
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
      }
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: SettingsSearchField
    var lastFocusRequest: Int

    init(_ parent: SettingsSearchField) {
      self.parent = parent
      lastFocusRequest = parent.focusRequest
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.moveDown(_:)):
        parent.onArrow(1)
        return true
      case #selector(NSResponder.moveUp(_:)):
        parent.onArrow(-1)
        return true
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.text = ""
        (control as? NSTextField)?.stringValue = ""
        return true
      default:
        return false
      }
    }
  }
}
