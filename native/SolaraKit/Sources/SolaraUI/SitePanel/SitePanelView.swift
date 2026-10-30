import AppKit
import QuartzCore
import SwiftUI

public struct SitePanelTile: Decodable, Equatable, Sendable {
  public var id: String
  public var icon: String
  public var label: String
  public var active: Bool?
}

public struct SitePanelExtension: Decodable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var icon: String?
  public var symbol: String?
  public var dimmed: Bool?
}

public struct SitePanelAccessory: Decodable, Equatable, Sendable {
  public var kind: String
  public var title: String?
  public var value: Bool?
  public var zoom: Double?
}

public struct SitePanelFavicon: Decodable, Equatable, Sendable {
  public var url: String
  public var favicon: String?
  public var profileId: String
}

public struct SitePanelChip: Decodable, Equatable, Sendable {
  public var icon: String
  public var title: String
  public var color: String?
  public var open: Bool
}

public struct SitePanelItem: Decodable, Equatable, Sendable {
  public var kind: String
  public var id: String?
  public var icon: String?
  public var iconColor: String?
  public var title: String?
  public var value: String?
  public var detail: String?
  public var on: Bool?
  public var pressable: Bool?
  public var tight: Bool?
  public var tiles: [SitePanelTile]?
  public var extensions: [SitePanelExtension]?
  public var columns: Int?
  public var accessory: SitePanelAccessory?
  public var favicon: SitePanelFavicon?
  public var rows: [[String]]?
  public var chip: SitePanelChip?
  public var moreOpen: Bool?
  public var top: Double?
}

public struct SitePanelState: Decodable, Equatable, Sendable {
  public var items: [SitePanelItem]
  public var dark: Bool
  public var theme: [String: String]

  public static func decode(_ json: String) -> SitePanelState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(SitePanelState.self, from: data)
  }
}

public enum SitePanelEvent: Sendable, Equatable {
  case press(String, CGRect)
  case menu(String, CGRect)
  case toggle(String, Bool)
  case zoom(String, Int)
}

enum SitePanelMetrics {
  static let inset: CGFloat = 16
  static let rowInset: CGFloat = 6
  static let rowPadding: CGFloat = 10
  static let rowRadius: CGFloat = 6
  static let rowHeight: CGFloat = 32
  static let iconSlot: CGFloat = 20
  static let iconGap: CGFloat = 10
  static let gap: CGFloat = 8
  static let actionHeight: CGFloat = 40
  static let extensionHeight: CGFloat = 36
  static let tileRadius: CGFloat = 8
  static let sectionTop: CGFloat = 14
  static let settingHeight: CGFloat = 42
  static let settingBadge: CGFloat = 26
  static let footerControl: CGFloat = 26
  static let separatorGap: CGFloat = 5
  static let headerGap: CGFloat = 8
}

func sitePanelTileFill(dark: Bool, pressed: Bool, hovered: Bool) -> CGColor {
  let alpha: CGFloat = pressed ? 0.16 : hovered ? 0.11 : 0.07
  return dark ? NSColor(white: 1, alpha: alpha).cgColor : NSColor(white: 0, alpha: alpha * 0.75).cgColor
}

func textWidth(_ field: NSTextField) -> CGFloat {
  ceil(field.attributedStringValue.size().width)
}

final class SitePanelPressable: HoverFillView {
  var fill: (Bool, Bool) -> CGColor? = { _, _ in nil }
  override func refresh() { layer?.backgroundColor = fill(hovered, pressed) }
}

final class SitePanelSwitch: NSView {
  var onChange: (Bool) -> Void = { _ in }
  private(set) var value: Bool
  private let knob = CALayer()
  private let offColor: CGColor

  override var isFlipped: Bool { true }

  init(value: Bool, dark: Bool) {
    self.value = value
    offColor = dark ? NSColor(white: 1, alpha: 0.16).cgColor : NSColor(white: 0, alpha: 0.12).cgColor
    super.init(frame: CGRect(x: 0, y: 0, width: 30, height: 17))
    wantsLayer = true
    layer?.cornerRadius = 8.5
    knob.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
    knob.cornerRadius = 7
    knob.backgroundColor = NSColor.white.cgColor
    knob.shadowColor = NSColor.black.cgColor
    knob.shadowOpacity = 0.2
    knob.shadowRadius = 1
    knob.shadowOffset = CGSize(width: 0, height: -0.5)
    layer?.addSublayer(knob)
    apply(animated: false)
    setAccessibilityRole(.checkBox)
  }

  required init?(coder: NSCoder) { fatalError() }

  private func apply(animated: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    CATransaction.setAnimationDuration(0.15)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.5, 1, 0.89, 1))
    layer?.backgroundColor = value ? NSColor(srgbRed: 0x34 / 255, green: 0x78 / 255, blue: 0xF6 / 255, alpha: 1).cgColor : offColor
    let x = value ? 30 - 1.5 - 7 : 1.5 + 7
    knob.position = CGPoint(x: x, y: 8.5)
    CATransaction.commit()
    setAccessibilityValue(value)
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    value.toggle()
    apply(animated: true)
    onChange(value)
  }
}

@MainActor
public final class SitePanelView: NSView {
  public var onEvent: (SitePanelEvent) -> Void = { _ in }
  public var onHeight: (CGFloat) -> Void = { _ in }
  public var favicons: NewTabFavicons?
  private var state: SitePanelState?
  private var reported: CGFloat = 0
  private var faviconTask: Task<Void, Never>?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ next: SitePanelState) {
    state = next
    rebuild()
  }

  private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, lineHeight: CGFloat? = nil, maxLines: Int = 1, tabular: Bool = false, alignment: NSTextAlignment = .natural) -> NSTextField {
    let field = maxLines == 1 ? NSTextField(labelWithString: "") : NSTextField(wrappingLabelWithString: "")
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if tabular { font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) }
    let p = NSMutableParagraphStyle()
    p.alignment = alignment
    p.lineBreakMode = maxLines == 1 ? .byTruncatingTail : .byWordWrapping
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if let lineHeight {
      p.minimumLineHeight = lineHeight
      p.maximumLineHeight = lineHeight
    }
    attrs[.paragraphStyle] = p
    field.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
    field.maximumNumberOfLines = maxLines
    field.lineBreakMode = maxLines == 1 ? .byTruncatingTail : .byWordWrapping
    field.cell?.truncatesLastVisibleLine = true
    field.isSelectable = false
    return field
  }

  private func height(_ field: NSTextField, width: CGFloat) -> CGFloat {
    field.preferredMaxLayoutWidth = width
    return ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width + 4, height: 10_000)).height ?? field.intrinsicContentSize.height)
  }

  private func place(_ field: NSTextField, in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height h: CGFloat) {
    field.frame = CGRect(x: x - 2, y: y, width: width + 4, height: h)
    parent.addSubview(field)
  }

  private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, box: CGSize) -> NSImageView {
    let v = NSImageView(frame: CGRect(origin: .zero, size: box))
    v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    v.imageScaling = .scaleNone
    v.contentTintColor = color
    return v
  }

  private func windowRect(_ view: NSView) -> CGRect {
    guard let content = window?.contentView else { return view.frame }
    let r = view.convert(view.bounds, to: content)
    return content.isFlipped ? r : CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
  }

  private func rebuild() {
    subviews.forEach { $0.removeFromSuperview() }
    faviconTask?.cancel()
    guard let s = state, bounds.width > 0 else { return }
    let theme = NewTabTheme(dark: s.dark, tokens: s.theme)
    var y = SitePanelMetrics.inset
    for item in s.items {
      y += layoutItem(item, at: y, state: s, theme: theme)
    }
    if y != reported {
      reported = y
      onHeight(y)
    }
  }

  private func layoutItem(_ item: SitePanelItem, at top: CGFloat, state s: SitePanelState, theme: NewTabTheme) -> CGFloat {
    let w = bounds.width
    let inner = w - 2 * SitePanelMetrics.inset
    switch item.kind {
    case "tiles":
      let tiles = item.tiles ?? []
      guard !tiles.isEmpty else { return 0 }
      let tw = (inner - SitePanelMetrics.gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
      for (i, tile) in tiles.enumerated() {
        let x = SitePanelMetrics.inset + CGFloat(i) * (tw + SitePanelMetrics.gap)
        let v = SitePanelPressable(frame: backingAligned(CGRect(x: x, y: top, width: tw, height: SitePanelMetrics.actionHeight)))
        v.wantsLayer = true
        v.layer?.cornerRadius = SitePanelMetrics.tileRadius
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = (s.dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06)).cgColor
        let dark = s.dark
        v.fill = { hovered, pressed in sitePanelTileFill(dark: dark, pressed: pressed, hovered: hovered) }
        v.refresh()
        let glyph = symbol(tile.icon, size: 15, color: tile.active == true ? theme.accent.ns : theme.icon.ns, box: CGSize(width: 22, height: 22))
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        glyph.frame.origin = CGPoint(x: ((x + (tw - 22) / 2) / pixel).rounded() * pixel - v.frame.minX, y: (SitePanelMetrics.actionHeight - 22) / 2)
        v.addSubview(glyph)
        v.toolTip = tile.label
        v.setAccessibilityRole(.button)
        v.setAccessibilityLabel(tile.label)
        let id = tile.id
        v.onPress = { [weak self, weak v] in
          guard let self, let v else { return }
          self.onEvent(.press(id, self.windowRect(v)))
        }
        addSubview(v)
      }
      return SitePanelMetrics.actionHeight
    case "section":
      let f = label(item.title ?? "", size: 12, weight: .semibold, color: theme.textSecondary.ns, lineHeight: 15)
      place(f, in: self, x: SitePanelMetrics.inset, y: top + SitePanelMetrics.sectionTop, width: inner, height: 15)
      let below = item.tight == true ? SitePanelMetrics.gap - (SitePanelMetrics.settingHeight - SitePanelMetrics.settingBadge) / 2 : SitePanelMetrics.gap
      return SitePanelMetrics.sectionTop + 15 + below
    case "extensions":
      let columns = max(1, item.columns ?? 4)
      let exts = item.extensions ?? []
      let tw = (inner - SitePanelMetrics.gap * CGFloat(columns - 1)) / CGFloat(columns)
      var rowsUsed = 0
      for (i, ext) in exts.enumerated() {
        let row = i / columns
        rowsUsed = row + 1
        let x = SitePanelMetrics.inset + CGFloat(i % columns) * (tw + SitePanelMetrics.gap)
        let ty = top + CGFloat(row) * (SitePanelMetrics.extensionHeight + SitePanelMetrics.gap)
        let v = SitePanelPressable(frame: backingAligned(CGRect(x: x, y: ty, width: tw, height: SitePanelMetrics.extensionHeight)))
        v.wantsLayer = true
        v.layer?.cornerRadius = SitePanelMetrics.tileRadius
        let dark = s.dark
        v.fill = { hovered, pressed in sitePanelTileFill(dark: dark, pressed: pressed, hovered: hovered) }
        v.refresh()
        if let uri = ext.icon, let image = PromptBodyView.image(uri) {
          let iv = NSImageView(frame: CGRect(x: (v.frame.width - 18) / 2, y: (SitePanelMetrics.extensionHeight - 18) / 2, width: 18, height: 18))
          iv.image = image
          iv.imageScaling = .scaleProportionallyUpOrDown
          iv.alphaValue = ext.dimmed == true ? 0.45 : 1
          v.addSubview(iv)
        } else {
          let glyph = symbol(ext.symbol ?? "puzzlepiece.extension", size: 14, color: theme.icon.ns, box: CGSize(width: 20, height: 20))
          glyph.frame.origin = CGPoint(x: (v.frame.width - 20) / 2, y: (SitePanelMetrics.extensionHeight - 20) / 2)
          v.addSubview(glyph)
        }
        v.toolTip = ext.name
        v.setAccessibilityRole(.button)
        v.setAccessibilityLabel(ext.name)
        let id = ext.id
        v.onPress = { [weak self, weak v] in
          guard let self, let v else { return }
          self.onEvent(.press(id, self.windowRect(v)))
        }
        v.onMenu = { [weak self, weak v] in
          guard let self, let v else { return }
          self.onEvent(.menu(id, self.windowRect(v)))
        }
        addSubview(v)
      }
      return rowsUsed == 0 ? 0 : CGFloat(rowsUsed) * SitePanelMetrics.extensionHeight + CGFloat(rowsUsed - 1) * SitePanelMetrics.gap
    case "setting":
      return settingRow(item, at: top, width: w, state: s, theme: theme)
    case "row":
      return popoverRow(item, at: top, width: w, state: s, theme: theme)
    case "separator":
      let line = NSView(frame: CGRect(x: SitePanelMetrics.inset, y: top + SitePanelMetrics.separatorGap, width: inner, height: hairline))
      line.wantsLayer = true
      line.layer?.backgroundColor = separatorColor(s.dark)
      addSubview(line)
      return 2 * SitePanelMetrics.separatorGap + hairline
    case "header":
      return header(item, at: top, width: w, theme: theme)
    case "certificate":
      return certificate(item, at: top, width: inner, state: s, theme: theme)
    case "footer":
      return footer(item, at: top, width: w, state: s, theme: theme)
    default:
      return 0
    }
  }

  private var hairline: CGFloat { 1 / (window?.backingScaleFactor ?? 2) }

  private func separatorColor(_ dark: Bool) -> CGColor {
    (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)).cgColor
  }

  private func backingAligned(_ r: CGRect) -> CGRect {
    backingAlignedRect(r, options: .alignAllEdgesNearest)
  }

  private func rowBase(_ id: String?, pressable: Bool, at top: CGFloat, height h: CGFloat, width: CGFloat, dark: Bool) -> SitePanelPressable {
    let v = SitePanelPressable(frame: CGRect(x: SitePanelMetrics.rowInset, y: top, width: width - 2 * SitePanelMetrics.rowInset, height: h))
    v.wantsLayer = true
    v.layer?.cornerRadius = SitePanelMetrics.rowRadius
    if pressable, let id {
      v.fill = { hovered, pressed in rowFill(dark: dark, hovered: hovered, pressed: pressed) }
      v.onPress = { [weak self, weak v] in
        guard let self, let v else { return }
        self.onEvent(.press(id, self.windowRect(v)))
      }
      v.setAccessibilityRole(.button)
    }
    addSubview(v)
    return v
  }

  private func settingRow(_ item: SitePanelItem, at top: CGFloat, width: CGFloat, state s: SitePanelState, theme: NewTabTheme) -> CGFloat {
    let h = SitePanelMetrics.settingHeight
    let v = rowBase(item.id, pressable: item.pressable == true, at: top, height: h, width: width, dark: s.dark)
    let on = item.on == true
    let badge = NSView(frame: CGRect(x: SitePanelMetrics.rowPadding, y: (h - SitePanelMetrics.settingBadge) / 2, width: SitePanelMetrics.settingBadge, height: SitePanelMetrics.settingBadge))
    badge.wantsLayer = true
    badge.layer?.cornerRadius = SitePanelMetrics.settingBadge / 2
    badge.layer?.backgroundColor = on ? theme.accent.cg : sitePanelTileFill(dark: s.dark, pressed: false, hovered: true)
    let glyph = symbol(item.icon ?? "", size: 12, weight: .medium, color: on ? .white : theme.icon.ns, box: CGSize(width: 18, height: 18))
    glyph.frame.origin = CGPoint(x: 4, y: 4)
    badge.addSubview(glyph)
    v.addSubview(badge)
    let tx = SitePanelMetrics.rowPadding + SitePanelMetrics.settingBadge + SitePanelMetrics.iconGap
    let tw = v.frame.width - tx - SitePanelMetrics.rowPadding
    let ty = (h - 30) / 2
    place(label(item.title ?? "", size: 13, weight: .medium, color: theme.textPrimary.ns, lineHeight: 16), in: v, x: tx, y: ty, width: tw, height: 16)
    place(label(item.value ?? "", size: 11, color: theme.textSecondary.ns, lineHeight: 14), in: v, x: tx, y: ty + 16.5, width: tw, height: 14)
    v.setAccessibilityLabel("\(item.title ?? ""): \(item.value ?? "")")
    return h
  }

  private func popoverRow(_ item: SitePanelItem, at top: CGFloat, width: CGFloat, state s: SitePanelState, theme: NewTabTheme) -> CGFloat {
    let rowWidth = width - 2 * SitePanelMetrics.rowInset
    var accessory: NSView?
    if let a = item.accessory {
      accessory = makeAccessory(a, id: item.id ?? "", title: item.title ?? "", state: s, theme: theme)
    }
    let aw = accessory.map { $0.frame.width + SitePanelMetrics.iconGap - (item.accessory?.kind == "value" ? 6 : 0) } ?? 0
    let tx = SitePanelMetrics.rowPadding + (item.icon != nil ? SitePanelMetrics.iconSlot + SitePanelMetrics.iconGap : 0)
    let tw = rowWidth - tx - SitePanelMetrics.rowPadding - aw
    let title = label(item.title ?? "", size: 13, color: theme.textPrimary.ns)
    let titleH = ceil(title.intrinsicContentSize.height)
    var textH = titleH
    var detailField: NSTextField?
    if let d = item.detail, !d.isEmpty {
      let f = label(d, size: 11, color: theme.textSecondary.ns, lineHeight: 13, maxLines: 2)
      let dh = height(f, width: tw)
      detailField = f
      textH += 1 + dh
    }
    let h = max(SitePanelMetrics.rowHeight, textH + 12)
    let v = rowBase(item.id, pressable: item.pressable == true, at: top, height: h, width: width, dark: s.dark)
    if let icon = item.icon {
      let color = item.iconColor.flatMap { CSSColor($0)?.ns } ?? theme.icon.ns
      let glyph = symbol(icon, size: 13, color: color, box: CGSize(width: SitePanelMetrics.iconSlot, height: SitePanelMetrics.iconSlot))
      glyph.frame.origin = CGPoint(x: SitePanelMetrics.rowPadding, y: (h - SitePanelMetrics.iconSlot) / 2)
      v.addSubview(glyph)
    }
    let ty = (h - textH) / 2
    place(title, in: v, x: tx, y: ty, width: tw, height: titleH)
    if let detailField {
      place(detailField, in: v, x: tx, y: ty + titleH + 1, width: tw, height: textH - titleH - 1)
    }
    if let accessory {
      let trailing = item.accessory?.kind == "value" ? -6 : 0
      accessory.frame.origin = CGPoint(x: rowWidth - SitePanelMetrics.rowPadding - accessory.frame.width - CGFloat(trailing), y: ((h - accessory.frame.height) / 2).rounded())
      v.addSubview(accessory)
    }
    v.setAccessibilityLabel(item.title)
    return h
  }

  private func makeAccessory(_ a: SitePanelAccessory, id: String, title: String, state s: SitePanelState, theme: NewTabTheme) -> NSView {
    switch a.kind {
    case "toggle":
      let t = SitePanelSwitch(value: a.value == true, dark: s.dark)
      t.setAccessibilityLabel(title)
      t.onChange = { [weak self] on in self?.onEvent(.toggle(id, on)) }
      return t
    case "zoom":
      let zoom = a.zoom ?? 1
      let box = FlippedView(frame: CGRect(x: 0, y: 0, width: 24 + 2 + 44 + 2 + 24, height: 22))
      let dark = s.dark
      func step(_ icon: String, _ tip: String, _ delta: Int, x: CGFloat) {
        let b = SitePanelPressable(frame: CGRect(x: x, y: 0, width: 24, height: 22))
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.fill = { hovered, pressed in pressed ? theme.toolbarPressed.cg : hovered ? theme.toolbarHover.cg : NSColor(white: dark ? 1 : 0, alpha: dark ? 0.06 : 0.05).cgColor }
        b.refresh()
        let g = symbol(icon, size: 10, weight: .semibold, color: theme.icon.ns, box: CGSize(width: 14, height: 14))
        g.frame.origin = CGPoint(x: 5, y: 4)
        b.addSubview(g)
        b.toolTip = tip
        b.setAccessibilityRole(.button)
        b.setAccessibilityLabel(tip)
        b.onPress = { [weak self] in self?.onEvent(.zoom(id, delta)) }
        box.addSubview(b)
      }
      step("minus", "Zoom Out (⌘-)", -1, x: 0)
      let reset = SitePanelPressable(frame: CGRect(x: 26, y: 0, width: 44, height: 22))
      let text = label("\(Int((zoom * 100).rounded()))%", size: 12, color: abs(zoom - 1) < 0.0001 ? theme.textSecondary.ns : theme.textPrimary.ns, tabular: true, alignment: .center)
      let th = ceil(text.intrinsicContentSize.height)
      text.frame = CGRect(x: 0, y: (22 - th) / 2, width: 44, height: th)
      reset.addSubview(text)
      reset.toolTip = "Reset to 100%"
      reset.setAccessibilityRole(.button)
      reset.setAccessibilityLabel("Reset to 100%")
      reset.onPress = { [weak self] in self?.onEvent(.zoom(id, 0)) }
      box.addSubview(reset)
      step("plus", "Zoom In (⌘+)", 1, x: 72)
      return box
    default:
      let f = label(a.title ?? "", size: 12, color: theme.textSecondary.ns)
      let tw = textWidth(f)
      let bw = 8 + tw + 3 + 8 + 6
      let b = SitePanelPressable(frame: CGRect(x: 0, y: 0, width: bw, height: 22))
      b.wantsLayer = true
      b.layer?.cornerRadius = 6
      b.fill = { hovered, _ in hovered ? theme.toolbarHover.cg : nil }
      let th = ceil(f.intrinsicContentSize.height)
      f.frame = CGRect(x: 8 - 2, y: (22 - th) / 2 - 0.5, width: tw + 4, height: th)
      b.addSubview(f)
      let chevron = symbol("chevron.up.chevron.down", size: 9, color: theme.textSecondary.ns, box: CGSize(width: 8, height: 14))
      chevron.frame.origin = CGPoint(x: 8 + tw + 3, y: 4)
      b.addSubview(chevron)
      b.setAccessibilityRole(.popUpButton)
      b.setAccessibilityLabel(a.title)
      b.onPress = { [weak self, weak b] in
        guard let self, let b else { return }
        self.onEvent(.press(id, self.windowRect(b)))
      }
      return b
    }
  }

  private func header(_ item: SitePanelItem, at top: CGFloat, width: CGFloat, theme: NewTabTheme) -> CGFloat {
    let hasSubtitle = !(item.detail ?? "").isEmpty
    let textH: CGFloat = 16 + (hasSubtitle ? 14 : 0)
    let overhang = max(0, (textH - SitePanelMetrics.iconSlot) / 2)
    let y0 = top + SitePanelMetrics.inset - overhang
    let rowH = max(textH, SitePanelMetrics.iconSlot)
    let icon = NSImageView(frame: CGRect(x: SitePanelMetrics.inset, y: y0 + (rowH - SitePanelMetrics.iconSlot) / 2, width: SitePanelMetrics.iconSlot, height: SitePanelMetrics.iconSlot))
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 4
    icon.layer?.masksToBounds = true
    addSubview(icon)
    if let fav = item.favicon {
      if let image = favicons?.cached(fav.url, fav.favicon, profileId: fav.profileId, dark: theme.dark) {
        icon.image = image
      } else {
        let env = NewTabEnvironment(theme: theme, favicons: favicons, profileId: fav.profileId)
        let fallback = NSHostingView(rootView: AnyView(FaviconFallbackTile(url: fav.url, size: SitePanelMetrics.iconSlot).environment(\.newTab, env)))
        fallback.sizingOptions = []
        fallback.safeAreaRegions = []
        fallback.frame = icon.frame
        addSubview(fallback)
        if let favicons {
          faviconTask = Task { [weak icon, weak fallback] in
            guard let image = await favicons.fetch(fav.url, fav.favicon, profileId: fav.profileId, dark: theme.dark), !Task.isCancelled else { return }
            fallback?.removeFromSuperview()
            icon?.image = image
          }
        }
      }
    }
    let tx = SitePanelMetrics.inset + SitePanelMetrics.iconSlot + SitePanelMetrics.iconGap
    let tw = width - tx - SitePanelMetrics.inset
    let ty = y0 + (rowH - textH) / 2
    place(label(item.title ?? "", size: 13, weight: .semibold, color: theme.textPrimary.ns, lineHeight: 16), in: self, x: tx, y: ty, width: tw, height: 16)
    if hasSubtitle {
      place(label(item.detail ?? "", size: 11, color: theme.textSecondary.ns, lineHeight: 14), in: self, x: tx, y: ty + 16.5, width: tw, height: 14)
    }
    return SitePanelMetrics.inset - overhang + rowH + SitePanelMetrics.headerGap
  }

  private func certificate(_ item: SitePanelItem, at top: CGFloat, width: CGFloat, state s: SitePanelState, theme: NewTabTheme) -> CGFloat {
    let box = FlippedView()
    box.wantsLayer = true
    box.layer?.cornerRadius = 8
    box.layer?.backgroundColor = (s.dark ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.04)).cgColor
    addSubview(box)
    let pad = SitePanelMetrics.rowPadding
    let valueX = pad + 82 + 8
    let valueW = width - valueX - pad
    var y = pad
    for (i, row) in (item.rows ?? []).enumerated() where row.count == 2 {
      if i > 0 { y += 3 }
      let k = label(row[0], size: 11, color: theme.textSecondary.ns, lineHeight: 13)
      let v = label(row[1], size: 11, color: theme.textPrimary.ns, lineHeight: 13, maxLines: 2)
      v.isSelectable = true
      let kh: CGFloat = 13
      let vh = height(v, width: valueW)
      place(k, in: box, x: pad, y: y, width: 82, height: kh)
      place(v, in: box, x: valueX, y: y, width: valueW, height: vh)
      y += max(kh, vh)
    }
    y += pad
    box.frame = CGRect(x: SitePanelMetrics.inset, y: top + 2, width: width, height: y)
    return 2 + y + 4
  }

  private func footer(_ item: SitePanelItem, at top: CGFloat, width: CGFloat, state s: SitePanelState, theme: NewTabTheme) -> CGFloat {
    let ruleTop = CGFloat(item.top ?? 8)
    let line = NSView(frame: CGRect(x: SitePanelMetrics.inset, y: top + ruleTop, width: width - 2 * SitePanelMetrics.inset, height: hairline))
    line.wantsLayer = true
    line.layer?.backgroundColor = separatorColor(s.dark)
    addSubview(line)
    let rowTop = top + ruleTop + hairline + 10
    let control = SitePanelMetrics.footerControl
    let dark = s.dark
    if let chip = item.chip {
      let color = chip.color.flatMap { CSSColor($0)?.ns }
      let text = label(chip.title, size: 12, weight: .medium, color: color ?? theme.textPrimary.ns)
      let tw = textWidth(text)
      let cw = 7 + 14 + 4 + tw + 9
      let c = SitePanelPressable(frame: backingAligned(CGRect(x: SitePanelMetrics.inset, y: rowTop, width: cw, height: control)))
      c.wantsLayer = true
      c.layer?.cornerRadius = 7
      let open = chip.open
      c.fill = { hovered, pressed in sitePanelTileFill(dark: dark, pressed: pressed || open, hovered: hovered) }
      c.refresh()
      let glyph = symbol(chip.icon, size: 11, weight: .medium, color: color ?? theme.icon.ns, box: CGSize(width: 14, height: 16))
      glyph.frame.origin = CGPoint(x: 7, y: (control - 16) / 2)
      c.addSubview(glyph)
      let th = ceil(text.intrinsicContentSize.height)
      text.frame = CGRect(x: 7 + 14 + 4 - 2, y: (control - th) / 2, width: tw + 4, height: th)
      c.addSubview(text)
      c.toolTip = open ? "Hide Connection Details" : "Connection Details"
      c.setAccessibilityRole(.button)
      c.setAccessibilityLabel(chip.title)
      c.onPress = { [weak self, weak c] in
        guard let self, let c else { return }
        self.onEvent(.press("connection", self.windowRect(c)))
      }
      addSubview(c)
    }
    let moreOpen = item.moreOpen == true
    let more = SitePanelPressable(frame: CGRect(x: width - SitePanelMetrics.inset - control, y: rowTop, width: control, height: control))
    more.wantsLayer = true
    more.layer?.cornerRadius = control / 2
    more.fill = { hovered, pressed in sitePanelTileFill(dark: dark, pressed: pressed || moreOpen, hovered: hovered) }
    more.refresh()
    let dots = symbol("ellipsis", size: 12, weight: .semibold, color: theme.icon.ns, box: CGSize(width: 18, height: 18))
    dots.frame.origin = CGPoint(x: 4, y: 4)
    more.addSubview(dots)
    let tip = moreOpen ? "Fewer Site Controls" : "More Site Controls"
    more.toolTip = tip
    more.setAccessibilityRole(.button)
    more.setAccessibilityLabel(tip)
    more.onPress = { [weak self, weak more] in
      guard let self, let more else { return }
      self.onEvent(.press("more", self.windowRect(more)))
    }
    addSubview(more)
    return ruleTop + hairline + 10 + control + 12
  }

  public override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed { rebuild() }
  }
}
