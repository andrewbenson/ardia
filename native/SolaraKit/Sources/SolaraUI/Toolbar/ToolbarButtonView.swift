import AppKit

final class ToolbarButtonView: NSView {
  var state: ToolbarButtonState { didSet { if state != oldValue { apply() } } }
  var palette: ToolbarPaletteState { didSet { if palette != oldValue { apply() } } }
  var onClick: (ToolbarClick) -> Void = { _ in }
  var forcedHover = false { didSet { apply() } }

  private let plate = CALayer()
  private let image = NSImageView()
  private var badge: NSTextField?
  private var decoded: (uri: String, image: NSImage?)?
  private var hovered = false
  private var pressed = false
  private var longPressTimer: Timer?
  private var longPressFired = false
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  var box: CGFloat { CGFloat(state.box ?? 30) }

  init(state: ToolbarButtonState, palette: ToolbarPaletteState) {
    self.state = state
    self.palette = palette
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(plate)
    image.imageScaling = .scaleNone
    addSubview(image)
    apply()
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
    apply()
  }

  var enabled: Bool { state.enabled ?? true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    apply()
  }

  func recheckHover() {
    guard hovered, let window else { return }
    let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    if !inside {
      hovered = false
      apply()
    }
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard enabled || state.menu == true else { return nil }
    return super.hitTest(point) == nil ? nil : self
  }

  override func mouseDown(with event: NSEvent) {
    guard enabled else { return }
    pressed = true
    longPressFired = false
    apply()
    if state.longPress == true {
      longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.pressed else { return }
          self.longPressFired = true
          self.pressed = false
          self.apply()
          self.onClick(ToolbarClick(id: self.state.id, kind: .menu))
        }
      }
    }
  }

  override func mouseUp(with event: NSEvent) {
    longPressTimer?.invalidate()
    longPressTimer = nil
    let wasPressed = pressed
    pressed = false
    apply()
    guard wasPressed, !longPressFired, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick(ToolbarClick(id: state.id, kind: .press, flags: event.modifierFlags))
  }

  override func rightMouseDown(with event: NSEvent) {
    guard state.menu == true, enabled else { return super.rightMouseDown(with: event) }
    onClick(ToolbarClick(id: state.id, kind: .menu))
  }

  override func otherMouseDown(with event: NSEvent) {
    guard event.buttonNumber == 2, state.middle == true, enabled else { return super.otherMouseDown(with: event) }
    onClick(ToolbarClick(id: state.id, kind: .middle, flags: event.modifierFlags))
  }

  override func layout() {
    super.layout()
    apply()
  }

  func apply() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let b = box
    plate.frame = CGRect(x: (bounds.width - b) / 2, y: (bounds.height - b) / 2, width: b, height: b)
    plate.cornerRadius = CGFloat(state.radius ?? 7)
    let plain = state.plain == true
    let background: String? =
      plain || !enabled ? nil : pressed || state.active == true ? palette.pressed : (hovered || forcedHover) ? palette.hover : nil
    plate.backgroundColor = toolbarColor(background)?.cgColor
    CATransaction.commit()
    let tint = toolbarColor(state.color) ?? toolbarColor(enabled ? palette.icon : palette.iconDisabled) ?? .labelColor
    if let picture = picture() {
      let side = CGFloat(state.imageSize ?? 16)
      image.image = picture
      image.imageScaling = .scaleProportionallyUpOrDown
      image.contentTintColor = nil
      image.alphaValue = state.dimmed == true ? 0.45 : 1
      image.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    } else {
      let config = NSImage.SymbolConfiguration(pointSize: CGFloat(state.size ?? 15), weight: ToolbarButtonView.weight(state.weight))
      image.image = NSImage(systemSymbolName: state.icon, accessibilityDescription: state.tooltip)?.withSymbolConfiguration(config)
      image.imageScaling = .scaleNone
      image.contentTintColor = tint
      image.alphaValue = 1
      image.frame = CGRect(x: (bounds.width - b) / 2, y: (bounds.height - b) / 2, width: b, height: b)
    }
    applyBadge()
    toolTip = state.tooltip
    setAccessibilityLabel(state.tooltip)
    setAccessibilityRole(.button)
  }

  private func picture() -> NSImage? {
    guard let uri = state.image, !uri.isEmpty else { return nil }
    if let decoded, decoded.uri == uri { return decoded.image }
    let made = PromptBodyView.image(uri)
    decoded = (uri, made)
    return made
  }

  private func applyBadge() {
    guard let spec = state.badge, !spec.text.isEmpty else {
      badge?.removeFromSuperview()
      badge = nil
      return
    }
    let field = badge ?? {
      let f = NSTextField(labelWithString: "")
      f.wantsLayer = true
      f.layer?.cornerRadius = 3
      f.alignment = .center
      f.isSelectable = false
      addSubview(f)
      badge = f
      return f
    }()
    let text = String(spec.text.prefix(4))
    let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    field.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: toolbarColor(spec.textColor) ?? .white])
    field.layer?.backgroundColor = toolbarColor(spec.color)?.cgColor
    let w = max(13, ceil(field.attributedStringValue.size().width) + 5)
    field.frame = CGRect(x: bounds.width - 1 - w, y: bounds.height - 3 - 11, width: w, height: 11)
  }

  static func weight(_ name: String?) -> NSFont.Weight {
    switch name {
    case "medium": .medium
    case "semibold": .semibold
    case "bold": .bold
    case "light": .light
    default: .regular
    }
  }
}
