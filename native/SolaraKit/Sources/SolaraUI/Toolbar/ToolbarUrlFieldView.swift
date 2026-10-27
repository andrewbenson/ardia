import AppKit

final class ToolbarUrlFieldView: NSView {
  static let height: CGFloat = 30
  static let lockLeft: CGFloat = 7
  static let lockWidth: CGFloat = 18
  static let lockGap: CGFloat = 3
  static let textLeft: CGFloat = 8
  static let labelInset: CGFloat = 2
  static let labelRaise: CGFloat = 1

  var onClick: (ToolbarClick) -> Void = { _ in }
  private(set) var state: ToolbarUrlState?
  private var palette: ToolbarPaletteState?
  private let pill = CALayer()
  private let label = NSTextField(labelWithString: "")
  private var lock: ToolbarButtonView?
  private var hoverButtons: [ToolbarButtonView] = []
  private var trailing: [ToolbarButtonView] = []
  private var hovered = false
  private var tracking: NSTrackingArea?
  private var pressedOnText = false
  private var dividers: [CALayer] = []
  private var editor: DeveloperUrlField?
  private var handledEditRequest = 0

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    pill.cornerRadius = 8
    layer?.addSublayer(pill)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    label.isSelectable = false
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  func update(_ next: ToolbarUrlState, palette nextPalette: ToolbarPaletteState) {
    let changed = next != state || nextPalette != palette
    state = next
    palette = nextPalette
    guard changed else { return }
    if let insecure = next.insecure {
      let spec = ToolbarButtonState(
        id: "lock", icon: "lock.open.trianglebadge.exclamationmark.fill", size: 12, box: ToolbarUrlFieldView.lockWidth, radius: 0, weight: nil,
        color: insecure == "certificateError" ? "#FF5F57" : nextPalette.secondary, enabled: true, active: false, tooltip: "Connection is not secure",
        menu: false, longPress: false, middle: false, plain: true)
      if let lock { lock.state = spec; lock.palette = nextPalette } else {
        let made = ToolbarButtonView(state: spec, palette: nextPalette)
        made.onClick = { [weak self] click in self?.onClick(click) }
        addSubview(made)
        lock = made
      }
    } else {
      lock?.removeFromSuperview()
      lock = nil
    }
    hoverButtons = sync(hoverButtons, next.hoverButtons, nextPalette)
    trailing = sync(trailing, next.trailing, nextPalette)
    syncEditor(next, nextPalette)
    applyHover()
    needsLayout = true
  }

  private func syncEditor(_ next: ToolbarUrlState, _ palette: ToolbarPaletteState) {
    guard let dev = next.developer, dev.editing else {
      editor?.removeFromSuperview()
      editor = nil
      return
    }
    let field = editor ?? {
      let made = DeveloperUrlField()
      made.onFinish = { [weak self] kind, text in self?.onClick(ToolbarClick(id: "urlEdit", kind: kind, text: text)) }
      made.onFocused = { [weak self] in self?.onClick(ToolbarClick(id: "urlEdit", kind: .focus)) }
      addSubview(made)
      editor = made
      return made
    }()
    field.textColor = toolbarColor(palette.text)
    if dev.request != handledEditRequest {
      handledEditRequest = dev.request
      field.stringValue = dev.text
      field.finished = false
      DispatchQueue.main.async { [weak field] in
        guard let field, let window = field.window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (field.stringValue as NSString).length)
        field.onFocused()
      }
    }
  }

  var editorView: NSView? { editor }

  private func sync(_ views: [ToolbarButtonView], _ specs: [ToolbarButtonState], _ palette: ToolbarPaletteState) -> [ToolbarButtonView] {
    var out: [ToolbarButtonView] = []
    for (i, spec) in specs.enumerated() {
      if i < views.count, views[i].state.id == spec.id {
        views[i].state = spec
        views[i].palette = palette
        out.append(views[i])
      } else {
        let made = ToolbarButtonView(state: spec, palette: palette)
        made.onClick = { [weak self] click in self?.onClick(click) }
        addSubview(made)
        out.append(made)
      }
    }
    for v in views where !out.contains(where: { $0 === v }) { v.removeFromSuperview() }
    return out
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    applyHover()
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    applyHover()
  }

  var shownHover: Bool { hovered || state?.pinned == true }

  private func applyHover() {
    guard let state, let palette else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pill.backgroundColor = shownHover ? toolbarColor(palette.pill)?.cgColor : nil
    CATransaction.commit()
    for b in hoverButtons {
      b.alphaValue = shownHover ? 1 : 0
      b.isHidden = false
    }
    if let dev = state.developer {
      label.isHidden = dev.editing
      label.attributedStringValue = NSAttributedString(
        string: dev.text, attributes: [.font: NSFont(name: ".AppleSystemUIFontMonospaced-Regular", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: toolbarColor(palette.text) ?? .labelColor])
      return
    }
    label.isHidden = false
    let trail = shownHover ? state.hoverTrail : state.restTrail
    let text = NSMutableAttributedString(
      string: state.host, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: toolbarColor(palette.text) ?? .labelColor])
    if !trail.isEmpty {
      text.append(NSAttributedString(string: trail, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: toolbarColor(palette.secondary) ?? .secondaryLabelColor]))
    }
    label.attributedStringValue = text
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local) else { return nil }
    if let editor, editor.frame.contains(local), let hit = editor.hitTest(convert(local, to: editor.superview)) { return hit }
    for b in hoverButtons + trailing + [lock].compactMap({ $0 }) where b.frame.contains(local) {
      if !shownHover && hoverButtons.contains(where: { $0 === b }) { continue }
      if let hit = b.hitTest(convert(local, to: b.superview)) { return hit }
    }
    return self
  }

  override func mouseDown(with event: NSEvent) {
    pressedOnText = true
  }

  override func mouseUp(with event: NSEvent) {
    defer { pressedOnText = false }
    guard pressedOnText, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick(ToolbarClick(id: "url", kind: .press, flags: event.modifierFlags))
  }

  override func rightMouseDown(with event: NSEvent) {
    onClick(ToolbarClick(id: "url", kind: .menu))
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pill.frame = bounds
    CATransaction.commit()
    var x: CGFloat = 0
    if let lock {
      lock.frame = CGRect(x: ToolbarUrlFieldView.lockLeft, y: 0, width: ToolbarUrlFieldView.lockWidth, height: h)
      x = ToolbarUrlFieldView.lockLeft + ToolbarUrlFieldView.lockWidth + ToolbarUrlFieldView.lockGap
    } else {
      x = ToolbarUrlFieldView.textLeft
    }
    var right = bounds.width - 3
    var usedDividers = 0
    let scale = window?.backingScaleFactor ?? 2
    for b in (hoverButtons + trailing).reversed() {
      if b.state.id.hasPrefix("divider") {
        b.isHidden = true
        if usedDividers == dividers.count {
          let l = CALayer()
          layer?.addSublayer(l)
          dividers.append(l)
        }
        let line = dividers[usedDividers]
        usedDividers += 1
        right -= 5
        let lw = 2 / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.isHidden = false
        line.backgroundColor = toolbarColor(palette?.divider)?.cgColor
        line.frame = CGRect(x: right - lw, y: (h - 16) / 2, width: lw, height: 16)
        CATransaction.commit()
        right -= lw + 5
        continue
      }
      let w = b.box
      right -= w
      b.frame = backingAlignedRect(CGRect(x: right, y: (h - w) / 2, width: w, height: w), options: .alignAllEdgesNearest)
    }
    for (i, d) in dividers.enumerated() where i >= usedDividers { d.isHidden = true }
    let size = label.intrinsicContentSize
    let textRight = right
    if let editor {
      editor.frame = CGRect(x: x - 2 - 2, y: 4 + (h - 30) / 2 + 2, width: max(0, textRight - x + 4), height: 18)
    }
    label.frame = CGRect(
      x: x - ToolbarUrlFieldView.labelInset, y: state?.developer != nil ? (((h - size.height) / 2 - 0.5) * 2).rounded() / 2 : ((h - size.height) / 2 - ToolbarUrlFieldView.labelRaise).rounded(), width: max(0, textRight - x + ToolbarUrlFieldView.labelInset),
      height: size.height)
  }
}

final class DeveloperUrlField: NSTextField, NSTextFieldDelegate {
  var onFinish: (ToolbarClick.Kind, String) -> Void = { _, _ in }
  var onFocused: () -> Void = {}
  var finished = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    isBezeled = false
    isBordered = false
    drawsBackground = false
    focusRingType = .none
    usesSingleLineMode = true
    cell?.wraps = false
    cell?.isScrollable = true
    font = NSFont(name: ".AppleSystemUIFontMonospaced-Regular", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    delegate = self
    isAutomaticTextCompletionEnabled = false
  }

  required init?(coder: NSCoder) { fatalError() }

  override var mouseDownCanMoveWindow: Bool { false }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if textView.hasMarkedText() { return false }
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      finish(.cancel)
      return true
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
      finish(.submit)
      return true
    default:
      return false
    }
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    if !finished {
      finished = true
      onFinish(.blur, stringValue)
    }
  }

  private func finish(_ kind: ToolbarClick.Kind) {
    guard !finished else { return }
    finished = true
    onFinish(kind, stringValue)
  }
}
