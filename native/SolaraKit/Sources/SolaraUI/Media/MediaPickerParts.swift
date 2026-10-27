import AppKit
import QuartzCore

enum PickerMetrics {
  static let inset: CGFloat = 16
  static let rowInset: CGFloat = 6
  static let rowPadding: CGFloat = 10
  static let rowRadius: CGFloat = 6
  static let iconSlot: CGFloat = 20
  static let iconGap: CGFloat = 10
  static let headerGap: CGFloat = 8
  static let titleLine: CGFloat = 16
  static let subtitleLine: CGFloat = 14
  static let buttonHeight: CGFloat = 28

  static func lineHeight(_ font: NSFont) -> CGFloat {
    ceil((font.ascender - font.descender + font.leading) * 2) / 2
  }

  static func textHeight(_ text: String, font: NSFont, width: CGFloat, lines: Int = 0, lineHeight: CGFloat? = nil) -> CGFloat {
    let line = lineHeight ?? Self.lineHeight(font)
    guard !text.isEmpty, width > 0 else { return line }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    let rect = (text as NSString).boundingRect(
      with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font, .paragraphStyle: style])
    let count = max(1, Int((rect.height / Self.lineHeight(font)).rounded()))
    return CGFloat(lines > 0 ? min(lines, count) : count) * line
  }
}

func pickerLabel(_ size: CGFloat, weight: NSFont.Weight = .regular, lines: Int = 1) -> NSTextField {
  let label = lines == 1 ? NSTextField(labelWithString: "") : NSTextField(wrappingLabelWithString: "")
  label.font = .systemFont(ofSize: size, weight: weight)
  label.isSelectable = false
  label.maximumNumberOfLines = lines
  label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
  label.cell?.truncatesLastVisibleLine = true
  label.drawsBackground = false
  label.isBordered = false
  return label
}

final class PickerHeaderView: NSView {
  let icon = NSView()
  let title = pickerLabel(13, weight: .semibold)
  let subtitle = pickerLabel(11, lines: 2)
  var accessory: NSView? { didSet { oldValue?.removeFromSuperview(); if let accessory { addSubview(accessory) }; needsLayout = true } }
  var iconSize: CGFloat = PickerMetrics.iconSlot
  var large = false { didSet { title.font = .systemFont(ofSize: large ? 14 : 13, weight: .semibold); subtitle.font = .systemFont(ofSize: large ? 11.5 : 11) } }
  var subtitleLines = 1 { didSet { subtitle.maximumNumberOfLines = subtitleLines } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(icon)
    addSubview(title)
    addSubview(subtitle)
  }

  required init?(coder: NSCoder) { fatalError() }

  private var titleLine: CGFloat { large ? PickerMetrics.titleLine + 1 : PickerMetrics.titleLine }

  private func textWidth(_ width: CGFloat) -> CGFloat {
    let accessoryWidth = accessory.map { $0.fittingSize.width - 6 + PickerMetrics.iconGap } ?? 0
    return max(0, width - 2 * PickerMetrics.inset - iconSize - PickerMetrics.iconGap - accessoryWidth)
  }

  private func subtitleHeight(_ width: CGFloat) -> CGFloat {
    guard !subtitle.stringValue.isEmpty, let font = subtitle.font else { return 0 }
    return PickerMetrics.textHeight(subtitle.stringValue, font: font, width: textWidth(width), lines: subtitleLines, lineHeight: PickerMetrics.subtitleLine)
  }

  func height(for width: CGFloat) -> CGFloat {
    let text = titleLine + subtitleHeight(width)
    let row = max(iconSize, text, accessory?.fittingSize.height ?? 0)
    let overhang = max(0, (text - iconSize) / 2)
    return PickerMetrics.inset - overhang + row + PickerMetrics.headerGap
  }

  override func layout() {
    super.layout()
    let width = bounds.width
    let sub = subtitleHeight(width)
    let text = titleLine + sub
    let row = max(iconSize, text, accessory?.fittingSize.height ?? 0)
    let top = PickerMetrics.inset - max(0, (text - iconSize) / 2)
    icon.frame = CGRect(x: PickerMetrics.inset, y: top + (row - iconSize) / 2, width: iconSize, height: iconSize)
    let x = PickerMetrics.inset + iconSize + PickerMetrics.iconGap
    let tw = textWidth(width)
    let ty = top + (row - text) / 2
    title.frame = CGRect(x: x - 2, y: ty + (titleLine - title.intrinsicContentSize.height) / 2, width: tw + 4, height: title.intrinsicContentSize.height)
    subtitle.isHidden = sub == 0
    subtitle.preferredMaxLayoutWidth = tw + 4
    subtitle.frame = CGRect(x: x - 2, y: ty + titleLine, width: tw + 4, height: sub)
    if let accessory {
      let size = accessory.fittingSize
      accessory.frame = CGRect(x: width - PickerMetrics.inset + 6 - size.width, y: top + (row - size.height) / 2, width: size.width, height: size.height)
    }
  }
}

final class PopoverValueView: NSView {
  private let label = pickerLabel(12)
  private let chevron = SymbolView()
  private var tracking: NSTrackingArea?
  private var hovered = false { didSet { if hovered != oldValue { paint() } } }
  var hoverFill: NSColor = .clear { didSet { paint() } }
  var onPress: (() -> Void)?

  override var isFlipped: Bool { true }

  init(title: String, chevron name: String = "chevron.up.chevron.down") {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.actions = SurfaceLayer.noActions
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    label.stringValue = title
    addSubview(label)
    addSubview(chevron)
    chevronName = name
  }

  required init?(coder: NSCoder) { fatalError() }

  var chevronName = "" { didSet { needsLayout = true } }

  func set(color: NSColor) {
    label.textColor = color
    chevron.set(chevronName, size: 9, weight: chevronName == "chevron.down" ? .semibold : .regular, color: color)
  }

  @objc private func devPointerChanged(_ note: Notification) { hovered = DevPointer.inside(self, note) }

  override var fittingSize: NSSize { NSSize(width: 8 + label.intrinsicContentSize.width + 3 + 8 + 6, height: 22) }

  override func layout() {
    super.layout()
    let lw = label.intrinsicContentSize.width
    let lh = label.intrinsicContentSize.height
    label.frame = CGRect(x: 8 - 2, y: (22 - lh) / 2, width: lw + 4, height: lh)
    chevron.frame = CGRect(x: 8 + lw + 3, y: 4, width: 8, height: 14)
  }

  private func paint() {
    MediaMotion.setInstantly { layer?.backgroundColor = hovered ? hoverFill.cgColor : nil }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
  }
}

final class PickerSpinner: NSView {
  private let indicator = NSProgressIndicator()

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    indicator.style = .spinning
    indicator.controlSize = .mini
    indicator.isDisplayedWhenStopped = false
    addSubview(indicator)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil, !isHidden { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
  }

  override var isHidden: Bool {
    didSet { if isHidden { indicator.stopAnimation(nil) } else if window != nil { indicator.startAnimation(nil) } }
  }

  override func layout() {
    super.layout()
    let side: CGFloat = 10
    indicator.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class PickerRowView: HoverFillView {
  let fill = CALayer()
  var hoverColor: NSColor = .clear
  var selectedColor: NSColor = .clear
  var selected = false { didSet { if selected != oldValue { refresh() } } }
  var hoverEnabled = true { didSet { refresh() } }
  var onDoubleClick: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    fill.cornerRadius = PickerMetrics.rowRadius
    fill.actions = SurfaceLayer.noActions
    layer?.addSublayer(fill)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    if event.clickCount == 2 { onDoubleClick?() }
  }

  override func layout() {
    super.layout()
    MediaMotion.setInstantly { fill.frame = bounds }
  }

  override func refresh() {
    MediaMotion.setInstantly {
      fill.backgroundColor = selected ? selectedColor.cgColor : hovered && hoverEnabled ? hoverColor.cgColor : nil
    }
  }
}
