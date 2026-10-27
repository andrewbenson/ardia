import AppKit

public struct ZoomPanelState: Decodable, Equatable, Sendable {
  public var zoom: Double
  public var dark: Bool
  public var theme: [String: String]
}

public enum ZoomPanelEvent: Equatable, Sendable {
  case step(Int)
}

enum ZoomPanelMetrics {
  static let height: CGFloat = 48
  static let inset: CGFloat = 16
  static let stepWidth: CGFloat = 24
  static let stepHeight: CGFloat = 22
  static let stepGap: CGFloat = 4
  static let gap: CGFloat = 8
  static let buttonHeight: CGFloat = 28
}

@MainActor
public final class ZoomPanelView: NSView {
  public var onEvent: (ZoomPanelEvent) -> Void = { _ in }
  public var onHeight: (CGFloat) -> Void = { _ in }
  private var state: ZoomPanelState?
  private var reported: CGFloat = 0

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ next: ZoomPanelState) {
    guard next != state else { return }
    state = next
    rebuild()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed { rebuild() }
  }

  private func rebuild() {
    subviews.forEach { $0.removeFromSuperview() }
    guard let s = state, bounds.width > 0 else { return }
    let theme = NewTabTheme(dark: s.dark, tokens: s.theme)
    let m = ZoomPanelMetrics.self
    var right = bounds.width - (m.height - m.buttonHeight) / 2

    let reset = NSTextField(labelWithString: "Reset")
    reset.font = .systemFont(ofSize: 13, weight: .medium)
    reset.textColor = theme.textPrimary.ns
    let rw = ceil(reset.intrinsicContentSize.width)
    let button = PromptPressable(frame: CGRect(x: right - rw - 24, y: (m.height - m.buttonHeight) / 2, width: rw + 24, height: m.buttonHeight))
    button.wantsLayer = true
    button.layer?.cornerRadius = 8
    let dark = s.dark
    button.fill = { hovered, pressed in
      let a: CGFloat = pressed ? (dark ? 0.18 : 0.12) : hovered ? (dark ? 0.14 : 0.09) : (dark ? 0.1 : 0.06)
      return NSColor(white: dark ? 1 : 0, alpha: a).cgColor
    }
    button.refresh()
    let rh = reset.intrinsicContentSize.height
    reset.frame = CGRect(x: 12 - 2, y: (m.buttonHeight - rh) / 2 - 0.5, width: rw + 4, height: rh)
    button.addSubview(reset)
    button.onPress = { [weak self] in self?.onEvent(.step(0)) }
    button.setAccessibilityRole(.button)
    button.setAccessibilityLabel("Reset")
    addSubview(button)
    right = button.frame.minX - m.gap

    for (icon, step, tip) in [("plus", 1, "Zoom In (⌘+)"), ("minus", -1, "Zoom Out (⌘-)")] {
      let b = PromptPressable(frame: CGRect(x: right - m.stepWidth, y: (m.height - m.stepHeight) / 2, width: m.stepWidth, height: m.stepHeight))
      b.wantsLayer = true
      b.layer?.cornerRadius = 6
      let rest = dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.05)
      b.fill = { hovered, pressed in pressed ? theme.toolbarPressed.cg : hovered ? theme.toolbarHover.cg : rest.cgColor }
      b.refresh()
      let glyph = NSImageView(frame: CGRect(x: (m.stepWidth - 14) / 2, y: (m.stepHeight - 14) / 2, width: 14, height: 14))
      glyph.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
      glyph.imageScaling = .scaleNone
      glyph.contentTintColor = theme.icon.ns
      b.addSubview(glyph)
      b.toolTip = tip
      b.onPress = { [weak self] in self?.onEvent(.step(step)) }
      b.setAccessibilityRole(.button)
      b.setAccessibilityLabel(tip)
      addSubview(b)
      right = b.frame.minX - m.stepGap
    }
    right += m.stepGap - m.gap

    let label = NSTextField(labelWithString: "Zoom: \(Int((s.zoom * 100).rounded()))%")
    label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    label.textColor = theme.textPrimary.ns
    label.lineBreakMode = .byTruncatingTail
    let lh = label.intrinsicContentSize.height
    label.frame = CGRect(x: m.inset - 2, y: (m.height - lh) / 2, width: max(0, right - m.inset + 4), height: lh)
    addSubview(label)

    if m.height != reported {
      reported = m.height
      onHeight(m.height)
    }
  }
}
