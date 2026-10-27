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
    applyHover()
    needsLayout = true
  }

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
    for b in (hoverButtons + trailing).reversed() {
      let w = b.box
      right -= w
      b.frame = CGRect(x: right, y: (h - w) / 2, width: w, height: w)
    }
    let size = label.intrinsicContentSize
    let textRight = right
    label.frame = CGRect(
      x: x - ToolbarUrlFieldView.labelInset, y: ((h - size.height) / 2 - ToolbarUrlFieldView.labelRaise).rounded(), width: max(0, textRight - x + ToolbarUrlFieldView.labelInset),
      height: size.height)
  }
}
