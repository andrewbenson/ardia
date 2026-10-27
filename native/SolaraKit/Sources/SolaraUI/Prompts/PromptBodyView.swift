import AppKit

public struct PromptLine: Decodable, Equatable, Sendable {
  public var text: String
  public var strong: Bool?
  public var tone: String?
  public var size: Double?
  public var kern: Double?
  public var maxLines: Int?
}

public struct PromptSection: Decodable, Equatable, Sendable {
  public var label: String?
  public var lines: [PromptLine]
}

public struct PromptChoice: Decodable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var selected: Bool
}

public struct PromptDetail: Decodable, Equatable, Sendable {
  public var kind: String
  public var sections: [PromptSection]?
  public var choices: [PromptChoice]?
  public var label: String?
  public var value: Bool?
  public var text: String?
}

public struct PromptButtonSpec: Decodable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var primary: Bool?
}

public struct PromptState: Decodable, Equatable, Sendable {
  public var icons: [String]
  public var image: String?
  public var title: String
  public var message: String?
  public var details: [PromptDetail]
  public var buttons: [PromptButtonSpec]
  public var close: Bool
  public var dark: Bool
  public var theme: [String: String]
  public var control: String
  public var controlBorder: String
  public var goButton: String
  public var goButtonText: String

  public static func decode(_ json: String) -> PromptState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(PromptState.self, from: data)
  }
}

public enum PromptEvent: Sendable, Equatable {
  case button(String)
  case choice(String)
  case toggle(Bool)
  case close
}

enum PromptMetrics {
  static let inset: CGFloat = 16
  static let gap: CGFloat = 10
}

final class PromptPressable: HoverFillView {
  var fill: (Bool, Bool) -> CGColor? = { _, _ in nil }
  override func refresh() { layer?.backgroundColor = fill(hovered, pressed) }
}

@MainActor
public final class PromptBodyView: NSView {
  public var onEvent: (PromptEvent) -> Void = { _ in }
  public var onHeight: (CGFloat) -> Void = { _ in }
  private var state: PromptState?
  private var reported: CGFloat = 0

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ next: PromptState) {
    state = next
    rebuild()
  }

  private func label(_ text: String, size: Double, weight: NSFont.Weight = .regular, color: NSColor, kern: Double? = nil, lineHeight: CGFloat? = nil, maxLines: Int = 0) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: "")
    var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    if let kern { attrs[.kern] = kern }
    if let lineHeight {
      let p = NSMutableParagraphStyle()
      p.minimumLineHeight = lineHeight
      p.maximumLineHeight = lineHeight
      attrs[.paragraphStyle] = p
    }
    field.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
    field.maximumNumberOfLines = maxLines
    field.lineBreakMode = maxLines == 1 ? .byTruncatingTail : .byWordWrapping
    field.cell?.truncatesLastVisibleLine = true
    field.isSelectable = false
    return field
  }

  private func fit(_ field: NSTextField, width: CGFloat) -> CGFloat {
    field.preferredMaxLayoutWidth = width
    return ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width + 4, height: 10_000)).height ?? field.intrinsicContentSize.height)
  }

  private func rebuild() {
    subviews.forEach { $0.removeFromSuperview() }
    guard let s = state else { return }
    let theme = NewTabTheme(dark: s.dark, tokens: s.theme)
    let w = bounds.width
    let inner = w - 2 * PromptMetrics.inset
    var y = PromptMetrics.inset
    if s.image != nil || !s.icons.isEmpty {
      var x = PromptMetrics.inset
      if let image = s.image, let img = PromptBodyView.image(image) {
        let v = NSImageView()
        v.image = img
        v.imageScaling = .scaleProportionallyUpOrDown
        v.frame = CGRect(x: x - 1, y: y - 1, width: 32, height: 32)
        addSubview(v)
        x += 30 + 6
      }
      for icon in s.icons {
        let tile = NSView(frame: CGRect(x: x, y: y, width: 30, height: 30))
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 8
        tile.layer?.backgroundColor = (s.dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.06)).cgColor
        let glyph = NSImageView(frame: CGRect(x: 5, y: 5, width: 20, height: 20))
        glyph.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = theme.icon.ns
        tile.addSubview(glyph)
        addSubview(tile)
        x += 30 + 6
      }
      y += 30 + PromptMetrics.gap
    }
    let title = label(s.title, size: 13, weight: .semibold, color: theme.textPrimary.ns)
    let th = fit(title, width: inner)
    title.frame = CGRect(x: PromptMetrics.inset - 2, y: y, width: inner + 4, height: th)
    addSubview(title)
    y += th
    if let message = s.message, !message.isEmpty {
      y += 3
      let m = label(message, size: 12, color: theme.textSecondary.ns)
      let mh = fit(m, width: inner)
      m.frame = CGRect(x: PromptMetrics.inset - 2, y: y, width: inner + 4, height: mh)
      addSubview(m)
      y += mh
    }
    for d in s.details {
      y += PromptMetrics.gap
      y += detail(d, at: y, width: inner, state: s, theme: theme)
    }
    y += PromptMetrics.gap + 2
    y += buttons(s, at: y, width: inner, theme: theme)
    y += PromptMetrics.inset
    if s.close {
      let offset = PromptMetrics.inset - (22 - 7) / 2
      let close = PromptPressable(frame: CGRect(x: w - offset - 22, y: offset, width: 22, height: 22))
      close.wantsLayer = true
      close.layer?.cornerRadius = 6
      close.fill = { hovered, _ in hovered ? theme.toolbarHover.cg : nil }
      close.toolTip = "Dismiss"
      close.setAccessibilityRole(.button)
      close.setAccessibilityLabel("Dismiss")
      let x = NSImageView(frame: CGRect(x: 4, y: 4, width: 14, height: 14))
      x.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
      x.imageScaling = .scaleNone
      x.contentTintColor = theme.textSecondary.ns
      close.addSubview(x)
      close.onPress = { [weak self] in self?.onEvent(.close) }
      addSubview(close)
    }
    if bounds.width > 0, y != reported {
      reported = y
      onHeight(y)
    }
  }

  private func detail(_ d: PromptDetail, at top: CGFloat, width: CGFloat, state s: PromptState, theme: NewTabTheme) -> CGFloat {
    let well = s.dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.04)
    switch d.kind {
    case "well":
      let box = FlippedView()
      box.wantsLayer = true
      box.layer?.cornerRadius = 8
      box.layer?.backgroundColor = well.cgColor
      addSubview(box)
      var y: CGFloat = 8
      for (si, section) in (d.sections ?? []).enumerated() {
        if si > 0 { y += 8 }
        var first = true
        if let l = section.label {
          let f = label(l, size: 11, color: theme.textSecondary.ns)
          let h = fit(f, width: width - 20)
          f.frame = CGRect(x: 10 - 2, y: y, width: width - 20 + 4, height: h)
          box.addSubview(f)
          y += h
          first = false
        }
        for line in section.lines {
          if !first { y += 3 }
          first = false
          let tone = line.tone == "secondary" ? theme.textSecondary.ns : theme.textPrimary.ns
          let f = label(line.text, size: line.size ?? 12, weight: line.strong == true ? .medium : .regular, color: tone, kern: line.kern, maxLines: line.maxLines ?? 0)
          let h = fit(f, width: width - 20)
          f.frame = CGRect(x: 10 - 2, y: y, width: width - 20 + 4, height: h)
          box.addSubview(f)
          y += h
        }
      }
      y += 8
      box.frame = CGRect(x: PromptMetrics.inset, y: top, width: width, height: y)
      return y
    case "choices":
      let box = FlippedView()
      box.wantsLayer = true
      box.layer?.cornerRadius = 8
      box.layer?.backgroundColor = well.cgColor
      addSubview(box)
      var y: CGFloat = 3
      for choice in d.choices ?? [] {
        let row = PromptPressable(frame: CGRect(x: 3, y: y, width: width - 6, height: 28))
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.fill = { hovered, _ in hovered ? theme.rowHover.cg : nil }
        if choice.selected {
          let check = NSImageView(frame: CGRect(x: 7, y: 7, width: 14, height: 14))
          check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
          check.imageScaling = .scaleNone
          check.contentTintColor = theme.textPrimary.ns
          row.addSubview(check)
        }
        let f = label(choice.title.isEmpty ? "No username" : choice.title, size: 12, color: theme.textPrimary.ns, maxLines: 1)
        let h = f.intrinsicContentSize.height
        f.frame = CGRect(x: 7 + 14 + 6 - 2, y: (28 - h) / 2, width: width - 6 - 27 - 7 + 4, height: h)
        row.addSubview(f)
        let id = choice.id
        row.onPress = { [weak self] in self?.onEvent(.choice(id)) }
        row.setAccessibilityRole(.button)
        row.setAccessibilityLabel(choice.title)
        box.addSubview(row)
        y += 28
      }
      y += 3
      box.frame = CGRect(x: PromptMetrics.inset, y: top, width: width, height: y)
      return y
    case "checkbox":
      let on = d.value == true
      let row = PromptPressable(frame: .zero)
      let boxView = NSView(frame: CGRect(x: 0, y: 1, width: 14, height: 14))
      boxView.wantsLayer = true
      boxView.layer?.cornerRadius = 3.5
      boxView.layer?.backgroundColor = on ? theme.accent.cg : (CSSColor(s.control)?.cg ?? NSColor.white.cgColor)
      boxView.layer?.borderWidth = on ? 0 : 1 / (window?.backingScaleFactor ?? 2) * 2
      boxView.layer?.borderColor = CSSColor(s.controlBorder)?.cg
      if on {
        let check = NSImageView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        check.imageScaling = .scaleNone
        check.contentTintColor = .white
        boxView.addSubview(check)
      }
      row.addSubview(boxView)
      let f = label(d.label ?? "", size: 12, color: theme.textPrimary.ns, lineHeight: 16)
      let lw = width - 14 - 7
      let h = max(16, fit(f, width: lw))
      f.frame = CGRect(x: 14 + 7 - 2, y: 0, width: lw + 4, height: h)
      row.addSubview(f)
      row.frame = CGRect(x: PromptMetrics.inset, y: top, width: width, height: h)
      row.onPress = { [weak self] in self?.onEvent(.toggle(!on)) }
      row.setAccessibilityRole(.checkBox)
      row.setAccessibilityLabel(d.label)
      addSubview(row)
      return h
    default:
      let f = label(d.text ?? "", size: 11, color: theme.textSecondary.ns)
      let h = fit(f, width: width)
      f.frame = CGRect(x: PromptMetrics.inset - 2, y: top, width: width + 4, height: h)
      addSubview(f)
      return h
    }
  }

  private func buttons(_ s: PromptState, at top: CGFloat, width: CGFloat, theme: NewTabTheme) -> CGFloat {
    var made: [(PromptPressable, CGFloat)] = []
    for spec in s.buttons {
      let primary = spec.primary == true
      let f = label(spec.title, size: 13, weight: .medium, color: primary ? (CSSColor(s.goButtonText)?.ns ?? .white) : theme.textPrimary.ns, maxLines: 1)
      let tw = ceil(f.intrinsicContentSize.width)
      let bw = tw + 24
      let b = PromptPressable(frame: CGRect(x: 0, y: 0, width: bw, height: 28))
      b.wantsLayer = true
      b.layer?.cornerRadius = 8
      let dark = s.dark
      let go = CSSColor(s.goButton)?.cg
      b.fill = { hovered, pressed in
        if primary {
          if dark { return pressed ? CSSColor("#C9B8C5")!.cg : hovered ? CSSColor("#E6D8E2")!.cg : go }
          return pressed ? CSSColor("#26314A")!.cg : hovered ? CSSColor("#1B2640")!.cg : go
        }
        let a: CGFloat = pressed ? (dark ? 0.18 : 0.12) : hovered ? (dark ? 0.14 : 0.09) : (dark ? 0.1 : 0.06)
        return NSColor(white: dark ? 1 : 0, alpha: a).cgColor
      }
      b.refresh()
      let h = f.intrinsicContentSize.height
      f.frame = CGRect(x: 12 - 2, y: (28 - h) / 2, width: tw + 4, height: h)
      b.addSubview(f)
      let id = spec.id
      b.onPress = { [weak self] in self?.onEvent(.button(id)) }
      b.setAccessibilityRole(.button)
      b.setAccessibilityLabel(spec.title)
      made.append((b, bw))
      addSubview(b)
    }
    var rows: [[(PromptPressable, CGFloat)]] = [[]]
    var used: CGFloat = 0
    for item in made {
      let need = (rows[rows.count - 1].isEmpty ? 0 : 8) + item.1
      if used + need > width && !rows[rows.count - 1].isEmpty {
        rows.append([item])
        used = item.1
      } else {
        rows[rows.count - 1].append(item)
        used += need
      }
    }
    var y = top
    for (i, row) in rows.enumerated() {
      if i > 0 { y += 8 }
      var x = PromptMetrics.inset + width
      for (b, bw) in row.reversed() {
        x -= bw
        b.frame.origin = CGPoint(x: x, y: y)
        x -= 8
      }
      y += 28
    }
    return y - top
  }

  static func image(_ uri: String) -> NSImage? {
    if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
      return Data(base64Encoded: String(uri[uri.index(after: comma)...])).flatMap(NSImage.init(data:))
    }
    if let url = URL(string: uri), url.isFileURL { return NSImage(contentsOf: url) }
    if uri.hasPrefix("/") { return NSImage(contentsOfFile: uri) }
    return nil
  }

  public override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed { rebuild() }
  }
}
