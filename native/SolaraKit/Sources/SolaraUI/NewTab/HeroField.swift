import AppKit
import SwiftUI

final class HeroTextField: NSTextField {
  weak var model: HeroBarModel?
  var selectionColor: NSColor = .selectedTextBackgroundColor { didSet { styleEditor() } }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      styleEditor()
      model?.didFocus()
    }
    return became
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard currentEditor() != nil, window?.firstResponder === currentEditor(), let model else { return super.performKeyEquivalent(with: event) }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 36 || event.keyCode == 76, flags.contains(.command) || flags.contains(.control) {
      return model.key(HeroKey(.enter, shift: flags.contains(.shift), alt: flags.contains(.option), meta: flags.contains(.command), ctrl: flags.contains(.control)))
    }
    return super.performKeyEquivalent(with: event)
  }

  func styleEditor() {
    guard let editor = currentEditor() as? NSTextView else { return }
    editor.selectedTextAttributes = [.backgroundColor: selectionColor]
    editor.insertionPointColor = textColor ?? .labelColor
  }
}

@MainActor
final class HeroFieldCoordinator: NSObject, NSTextFieldDelegate, HeroFieldControl {
  let model: HeroBarModel
  weak var field: HeroTextField?
  private var applying = false
  private var before: TextSelection?

  init(model: HeroBarModel) {
    self.model = model
  }

  var fieldSelection: TextSelection {
    guard let editor = field?.currentEditor() else { return model.selection }
    let r = editor.selectedRange
    return TextSelection(start: r.location, end: r.location + r.length)
  }

  func show(value: String, selection: TextSelection) {
    guard let field else { return }
    applying = true
    defer { applying = false }
    if field.stringValue != value { field.stringValue = value }
    if let editor = field.currentEditor() {
      let length = (value as NSString).length
      let start = min(selection.start, length)
      let end = min(max(selection.end, start), length)
      let range = NSRange(location: start, length: end - start)
      if editor.selectedRange != range { editor.selectedRange = range }
    }
  }

  func focusField() {
    guard let field, let window = field.window else { return }
    if field.currentEditor() == nil || window.firstResponder !== field.currentEditor() {
      applying = true
      window.makeFirstResponder(field)
      applying = false
    }
  }

  func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
    let r = textView.selectedRange
    before = TextSelection(start: r.location, end: r.location + r.length)
    return true
  }

  func controlTextDidChange(_ obj: Notification) {
    guard !applying, let field else { return }
    let after = fieldSelection
    let edit = before.map { EditContext(before: $0, after: after) }
    before = nil
    model.textChanged(field.stringValue, edit: edit)
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard !applying, field?.currentEditor() != nil else { return }
    model.selectionChanged(fieldSelection)
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    model.didBlur()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
    func key(_ name: HeroKey.Name) -> HeroKey {
      HeroKey(name, shift: flags.contains(.shift), alt: flags.contains(.option), meta: flags.contains(.command), ctrl: flags.contains(.control))
    }
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)): return model.key(key(.escape))
    case #selector(NSResponder.moveDown(_:)): return model.key(key(.arrowDown))
    case #selector(NSResponder.moveUp(_:)): return model.key(key(.arrowUp))
    case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): return model.key(key(.pageUp))
    case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): return model.key(key(.pageDown))
    case #selector(NSResponder.insertTab(_:)): return model.key(key(.tab))
    case #selector(NSResponder.insertBacktab(_:)): return model.key(HeroKey(.tab, shift: true, alt: flags.contains(.option), meta: flags.contains(.command), ctrl: flags.contains(.control)))
    case #selector(NSResponder.deleteBackward(_:)): return model.key(key(.backspace))
    case #selector(NSResponder.deleteForward(_:)): return model.key(key(.delete))
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
      return model.key(key(.enter))
    default: return false
    }
  }

  func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
    model.selectionChanged(fieldSelection)
    model.contextMenu()
    return nil
  }
}

struct HeroFieldView: NSViewRepresentable {
  let model: HeroBarModel
  let theme: NewTabTheme

  func makeCoordinator() -> HeroFieldCoordinator { HeroFieldCoordinator(model: model) }

  func makeNSView(context: Context) -> HeroTextField {
    let field = HeroTextField()
    field.model = model
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.lineBreakMode = .byClipping
    field.font = .systemFont(ofSize: 17)
    field.delegate = context.coordinator
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    context.coordinator.field = field
    model.field = context.coordinator
    field.stringValue = model.value
    style(field)
    return field
  }

  func updateNSView(_ field: HeroTextField, context: Context) {
    style(field)
  }

  private func style(_ field: HeroTextField) {
    field.textColor = theme.textPrimary.ns
    field.selectionColor = theme.selection.ns
    let placeholder = model.placeholder
    if field.placeholderAttributedString?.string != placeholder || field.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != theme.placeholder.ns {
      field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: theme.placeholder.ns, .font: NSFont.systemFont(ofSize: 17)])
    }
  }
}
