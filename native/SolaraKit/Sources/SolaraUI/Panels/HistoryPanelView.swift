import AppKit

public struct HistoryPanelItem: Decodable, Equatable, Sendable {
  public var title: String
  public var url: String
  public var favicon: String?
  public var newTab: Bool
}

public struct HistoryPanelState: Decodable, Equatable, Sendable {
  public var items: [HistoryPanelItem]
  public var profileId: String
  public var dark: Bool
  public var theme: [String: String]
}

public struct HistoryPanelClick: Equatable, Sendable {
  public var meta = false
  public var shift = false
  public var alt = false
  public var middle = false
}

public enum HistoryPanelEvent: Equatable, Sendable {
  case open(Int, HistoryPanelClick)
  case fullHistory
}

enum HistoryPanelMetrics {
  static let inset: CGFloat = 16
  static let rowInset: CGFloat = 6
  static let rowHeight: CGFloat = 32
  static let rowRadius: CGFloat = 6
  static let rowPadding: CGFloat = 10
  static let iconSlot: CGFloat = 20
  static let iconGap: CGFloat = 10
  static let listPadding: CGFloat = 10
  static let separatorGap: CGFloat = 5
}

final class HistoryPanelRow: HoverFillView {
  var dark = false
  var onClick: (HistoryPanelClick) -> Void = { _ in }

  override func refresh() {
    layer?.backgroundColor = rowFill(dark: dark, hovered: hovered, pressed: pressed)
  }

  override func mouseUp(with event: NSEvent) {
    let was = pressed
    pressed = false
    refresh()
    guard was, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    let f = event.modifierFlags
    onClick(HistoryPanelClick(meta: f.contains(.command), shift: f.contains(.shift), alt: f.contains(.option)))
  }

  override func otherMouseUp(with event: NSEvent) {
    guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else { return super.otherMouseUp(with: event) }
    onClick(HistoryPanelClick(middle: true))
  }
}

@MainActor
public final class HistoryPanelView: NSView {
  public var onEvent: (HistoryPanelEvent) -> Void = { _ in }
  public var onHeight: (CGFloat) -> Void = { _ in }
  public let favicons = SidebarFavicons()
  private var state: HistoryPanelState?
  private var reported: CGFloat = 0

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ next: HistoryPanelState) {
    guard next != state else { return }
    state = next
    rebuild()
  }

  public func rebuildIcons() { rebuild() }

  public override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed { rebuild() }
  }

  private func row(at y: CGFloat, width: CGFloat, dark: Bool, title: String, theme: NewTabTheme, icon: (NSView) -> Void, tooltip: String?) -> HistoryPanelRow {
    let m = HistoryPanelMetrics.self
    let row = HistoryPanelRow(frame: CGRect(x: m.rowInset, y: y, width: width - 2 * m.rowInset, height: m.rowHeight))
    row.wantsLayer = true
    row.layer?.cornerRadius = m.rowRadius
    row.dark = dark
    row.refresh()
    let slot = NSView(frame: CGRect(x: m.rowPadding, y: (m.rowHeight - m.iconSlot) / 2, width: m.iconSlot, height: m.iconSlot))
    icon(slot)
    row.addSubview(slot)
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 13)
    label.textColor = theme.textPrimary.ns
    label.lineBreakMode = .byTruncatingTail
    let x = m.rowPadding + m.iconSlot + m.iconGap
    let h = label.intrinsicContentSize.height
    label.frame = CGRect(x: x - 2, y: (m.rowHeight - h) / 2, width: max(0, row.frame.width - x - m.rowPadding + 4), height: h)
    row.addSubview(label)
    row.toolTip = tooltip
    row.setAccessibilityRole(.button)
    row.setAccessibilityLabel(title)
    return row
  }

  private func rebuild() {
    subviews.forEach { $0.removeFromSuperview() }
    guard let s = state, bounds.width > 0 else { return }
    let theme = NewTabTheme(dark: s.dark, tokens: s.theme)
    let palette = SidebarPalette(SidebarHostState(profileId: s.profileId, dark: s.dark))
    let m = HistoryPanelMetrics.self
    var y = m.listPadding
    for (i, item) in s.items.enumerated() {
      let r = row(at: y, width: bounds.width, dark: s.dark, title: item.title, theme: theme, icon: { slot in
        let icon = TabIconView(frame: CGRect(x: 2, y: 2, width: 16, height: 16))
        icon.favicons = self.favicons
        icon.set(TabIconSpec(url: item.newTab ? "" : item.url, favicon: item.newTab ? nil : item.favicon, customIcon: nil, profileId: s.profileId), palette: palette)
        slot.addSubview(icon)
      }, tooltip: item.url.isEmpty ? nil : item.url)
      r.onClick = { [weak self] click in self?.onEvent(.open(i, click)) }
      addSubview(r)
      y += m.rowHeight
    }
    let line = NSView(frame: CGRect(x: m.inset, y: y + m.separatorGap, width: bounds.width - 2 * m.inset, height: 1 / (window?.backingScaleFactor ?? 2)))
    line.wantsLayer = true
    line.layer?.backgroundColor = (s.dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)).cgColor
    addSubview(line)
    y += 2 * m.separatorGap + line.frame.height
    let full = row(at: y, width: bounds.width, dark: s.dark, title: "Show Full History", theme: theme, icon: { slot in
      let glyph = NSImageView(frame: slot.bounds)
      glyph.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
      glyph.imageScaling = .scaleNone
      glyph.contentTintColor = theme.icon.ns
      slot.addSubview(glyph)
    }, tooltip: nil)
    full.onClick = { [weak self] _ in self?.onEvent(.fullHistory) }
    addSubview(full)
    y += m.rowHeight + m.listPadding
    if y != reported {
      reported = y
      onHeight(y)
    }
  }
}
