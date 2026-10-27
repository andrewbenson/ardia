import AppKit
import SwiftUI

struct OnboardingText: View {
  let text: String
  let size: CGFloat
  var weight = 400
  let color: Color
  var lineHeight: CGFloat?
  var kerning: CGFloat = 0
  var lines = 0
  var alignment: NSTextAlignment = .left
  var italic = false

  init(_ text: String, size: CGFloat, weight: Int = 400, color: Color, lineHeight: CGFloat? = nil, kerning: CGFloat = 0, lines: Int = 0, alignment: NSTextAlignment = .left, italic: Bool = false) {
    self.text = text
    self.size = size
    self.weight = weight
    self.color = color
    self.lineHeight = lineHeight
    self.kerning = kerning
    self.lines = lines
    self.alignment = alignment
    self.italic = italic
  }

  var body: some View {
    OnboardingTextRepresentable(layout: OnboardingTextLayout(text: text, size: size, weight: weight, color: NSColor(color), lineHeight: lineHeight, kerning: kerning, lines: lines, alignment: alignment, italic: italic))
      .accessibilityElement()
      .accessibilityLabel(text)
      .accessibilityAddTraits(.isStaticText)
  }
}

struct OnboardingTextRun: Equatable {
  let text: String
  var color: NSColor?
  var weight: Int?
}

struct OnboardingTextLayout: Equatable {
  let runs: [OnboardingTextRun]
  let size: CGFloat
  let weight: Int
  let color: NSColor
  let lineHeight: CGFloat?
  let kerning: CGFloat
  let lines: Int
  let alignment: NSTextAlignment
  var italic = false
  var family: String?

  init(text: String, size: CGFloat, weight: Int, color: NSColor, lineHeight: CGFloat?, kerning: CGFloat, lines: Int, alignment: NSTextAlignment, italic: Bool = false, family: String? = nil) {
    self.init(runs: [OnboardingTextRun(text: text)], size: size, weight: weight, color: color, lineHeight: lineHeight, kerning: kerning, lines: lines, alignment: alignment, italic: italic, family: family)
  }

  init(runs: [OnboardingTextRun], size: CGFloat, weight: Int, color: NSColor, lineHeight: CGFloat?, kerning: CGFloat, lines: Int, alignment: NSTextAlignment, italic: Bool = false, family: String? = nil) {
    self.runs = runs
    self.size = size
    self.weight = weight
    self.color = color
    self.lineHeight = lineHeight
    self.kerning = kerning
    self.lines = lines
    self.alignment = alignment
    self.italic = italic
    self.family = family
  }

  static func nsWeight(_ css: Int) -> NSFont.Weight {
    switch css {
    case ...100: .ultraLight
    case ...200: .thin
    case ...300: .light
    case ...400: .regular
    case ...500: .medium
    case ...600: .semibold
    case ...700: .bold
    case ...800: .heavy
    default: .black
    }
  }

  func font(weight css: Int) -> NSFont {
    let weight = Self.nsWeight(css)
    var base = NSFont.systemFont(ofSize: size, weight: weight)
    if let family {
      let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
      base = NSFont(descriptor: descriptor, size: size) ?? NSFont(name: family, size: size) ?? base
    }
    guard italic else { return base }
    return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? base
  }

  var text: String { runs.map(\.text).joined() }

  var attributed: NSAttributedString {
    let font = font(weight: weight)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakStrategy = []
    var base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    if kerning != 0 { base[.kern] = kerning }
    var offset: CGFloat?
    if let lineHeight {
      paragraph.minimumLineHeight = lineHeight
      paragraph.maximumLineHeight = lineHeight
      let natural = font.ascender - font.descender
      if lineHeight > natural { offset = (lineHeight - natural) / 2 }
    }
    if let offset { base[.baselineOffset] = offset }
    let result = NSMutableAttributedString()
    for run in runs {
      var attributes = base
      if let color = run.color { attributes[.foregroundColor] = color }
      if let weight = run.weight { attributes[.font] = self.font(weight: weight) }
      result.append(NSAttributedString(string: run.text, attributes: attributes))
    }
    return result
  }
}

final class OnboardingTextNSView: NSView {
  let storage = NSTextStorage()
  let manager = NSLayoutManager()
  let container = NSTextContainer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  func apply(_ layout: OnboardingTextLayout) {
    storage.setAttributedString(layout.attributed)
    container.maximumNumberOfLines = layout.lines
    container.lineBreakMode = layout.lines > 0 ? .byTruncatingTail : .byWordWrapping
    needsDisplay = true
  }

  func measure(width: CGFloat) -> CGSize {
    container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container).size
    let fits = width.isFinite && used.width + 0.5 > width
    return CGSize(width: fits ? width : Self.ceilPixel(used.width + 0.5), height: Self.ceilPixel(used.height))
  }

  static func ceilPixel(_ value: CGFloat) -> CGFloat { (value * 2 - 0.01).rounded(.up) / 2 }

  override func layout() {
    super.layout()
    container.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
  }

  override func draw(_ dirtyRect: NSRect) {
    container.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
    let range = manager.glyphRange(for: container)
    manager.drawBackground(forGlyphRange: range, at: .zero)
    manager.drawGlyphs(forGlyphRange: range, at: .zero)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct OnboardingTextRepresentable: NSViewRepresentable {
  let layout: OnboardingTextLayout

  func makeNSView(context: Context) -> OnboardingTextNSView {
    let view = OnboardingTextNSView()
    view.apply(layout)
    return view
  }

  func updateNSView(_ view: OnboardingTextNSView, context: Context) {
    view.apply(layout)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: OnboardingTextNSView, context: Context) -> CGSize? {
    let width = proposal.width ?? .greatestFiniteMagnitude
    let size = nsView.measure(width: width.isFinite ? width : .greatestFiniteMagnitude)
    return CGSize(width: proposal.width.map { min($0, size.width) } ?? size.width, height: size.height)
  }
}

@MainActor
public enum OnboardingProbe {
  public struct Row: Sendable {
    public var frame: CGRect
    public var on: Bool
    public var disabled: Bool
  }

  public static var enabled = false
  public static var rows: [String: Row] = [:]
}

struct OnboardingProbeModifier: ViewModifier {
  let title: String
  let on: Bool
  let disabled: Bool

  func body(content: Content) -> some View {
    if OnboardingProbe.enabled {
      content
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
          OnboardingProbe.rows[title] = OnboardingProbe.Row(frame: frame, on: on, disabled: disabled)
        }
        .onChange(of: on) { _, now in OnboardingProbe.rows[title]?.on = now }
        .onChange(of: disabled) { _, now in OnboardingProbe.rows[title]?.disabled = now }
        .onDisappear { OnboardingProbe.rows[title] = nil }
    } else {
      content
    }
  }
}
