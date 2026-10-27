import AppKit
import Foundation

public struct MediaThemeState: Decodable, Equatable, Sendable {
  public var dark: Bool
  public var colors: [String: String]
  public var panelShadowOpacity: Double

  public init(dark: Bool, colors: [String: String] = [:], panelShadowOpacity: Double = 0.2) {
    self.dark = dark
    self.colors = colors
    self.panelShadowOpacity = panelShadowOpacity
  }
}

@MainActor
struct MediaPalette {
  let dark: Bool
  let panelShadowOpacity: Double
  let panel: NSColor
  let panelBorder: NSColor
  let textPrimary: NSColor
  let textSecondary: NSColor
  let textTertiary: NSColor
  let placeholder: NSColor
  let icon: NSColor
  let accent: NSColor
  let rowHover: NSColor
  let toolbarHover: NSColor
  let toolbarPressed: NSColor
  let urlPill: NSColor
  let groupFill: NSColor
  let groupStroke: NSColor
  let badge: NSColor
  let badgeGlyph: NSColor
  let tokens: MediaTokens

  init(_ theme: MediaThemeState) {
    let d = theme.dark
    dark = d
    panelShadowOpacity = theme.panelShadowOpacity
    func color(_ key: String, _ fallback: String) -> NSColor { MediaPalette.parse(theme.colors[key]) ?? MediaPalette.parse(fallback)! }
    panel = color("panel", d ? "#2A2A2A" : "#FFFFFF")
    panelBorder = color("panelBorder", d ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)")
    textPrimary = color("textPrimary", d ? "#FFFFFF" : "#000000")
    textSecondary = color("textSecondary", d ? "#FFFFFF80" : "#00000080")
    textTertiary = color("textTertiary", d ? "#FFFFFF59" : "#00000059")
    placeholder = color("placeholder", d ? "#FFFFFF87" : "#00000066")
    icon = color("icon", d ? "#F7F5FFC6" : "#000000C6")
    accent = color("accent", d ? "#4A77D4" : "#6395FC")
    rowHover = color("rowHover", d ? "rgba(255,255,255,0.07)" : "rgba(15,24,44,0.05)")
    toolbarHover = color("toolbarHover", d ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.06)")
    toolbarPressed = color("toolbarPressed", d ? "rgba(255,255,255,0.18)" : "rgba(0,0,0,0.1)")
    urlPill = color("urlPill", d ? "rgba(255,255,255,0.07)" : "rgba(0,0,0,0.05)")
    groupFill = color("groupFill", d ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.05)")
    groupStroke = color("groupStroke", d ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)")
    badge = color("badge", d ? "rgba(255,255,255,0.9)" : "rgba(0,0,0,0.75)")
    badgeGlyph = color("badgeGlyph", d ? "#1B1618" : "#FFFFFF")
    tokens = d ? .dark : .light
  }

  static func parse(_ text: String?) -> NSColor? {
    guard let text else { return nil }
    if text == "transparent" { return .clear }
    return CSSColor(text)?.ns
  }
}

struct MediaTokens {
  let background: NSColor
  let backgroundRGB: (Double, Double, Double)
  let label: NSColor
  let secondary: NSColor
  let track: NSColor
  let fill: NSColor
  let hoverFill: NSColor
  let artPlaceholder: NSColor
  let border: NSColor

  private static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
  }

  static let light = MediaTokens(
    background: rgba(244, 244, 244, 1), backgroundRGB: (244, 244, 244), label: rgba(0, 0, 0, 0.85), secondary: rgba(0, 0, 0, 0.5),
    track: rgba(0, 0, 0, 0.1), fill: rgba(0, 0, 0, 0.35), hoverFill: rgba(0, 0, 0, 0.6), artPlaceholder: rgba(0, 0, 0, 0.06),
    border: rgba(0, 0, 0, 0.1))

  static let dark = MediaTokens(
    background: rgba(38, 38, 38, 1), backgroundRGB: (38, 38, 38), label: rgba(255, 255, 255, 0.85), secondary: rgba(255, 255, 255, 0.55),
    track: rgba(255, 255, 255, 0.2), fill: rgba(255, 255, 255, 0.5), hoverFill: rgba(255, 255, 255, 0.8),
    artPlaceholder: rgba(255, 255, 255, 0.08), border: rgba(255, 255, 255, 0.1))

  static let captureRed = NSColor(srgbRed: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
}
