import Foundation
import SwiftUI

struct PreviewTheme {
  let dark: Bool
  let card: String
  let cardEdge: String
  let divider: String
  let textPrimary: String
  let textTab: String
  let textSecondary: String
  let textTertiary: String
  let icon: String
  let iconDisabled: String
  let tabSelected: String
  let tabSelectedText: String
  let tabSelectedBorder: [String]
  let tabSelectedShadow: String
  let tabSelectedShadowRadius: Double
  let pinnedResting: String
  let toolbarHover: String
  let toolbarPressed: String
  let urlPill: String
  let panel: String
  let panelBorder: String
  let panelShadowOpacity: Double
  let commandBarSelected: String
  let selection: String
  let placeholder: String
  let goButton: String
  let goButtonText: String
  let ntpBarSolid: String
  let ntpBarBorder: String
  let accent: String
  var windowTint: [String] = []

  static let darkBase = PreviewTheme(
    dark: true, card: "rgba(18,18,18,0.5)", cardEdge: "rgba(0,0,0,0.35)", divider: "rgba(255,255,255,0.08)",
    textPrimary: "#FFFFFF", textTab: "#FFFFFFC7", textSecondary: "#FFFFFF80", textTertiary: "#FFFFFF59", icon: "#F7F5FFC6", iconDisabled: "#F7F5FF4D",
    tabSelected: "rgba(18,18,18,0.5)", tabSelectedText: "#FFFFFF", tabSelectedBorder: ["rgba(255,255,255,0.15)", "rgba(255,255,255,0.15)"],
    tabSelectedShadow: "rgba(255,255,255,0.15)", tabSelectedShadowRadius: 15, pinnedResting: "rgba(255,255,255,0.1)",
    toolbarHover: "rgba(255,255,255,0.1)", toolbarPressed: "rgba(255,255,255,0.18)", urlPill: "rgba(255,255,255,0.07)",
    panel: "#2A2A2A", panelBorder: "rgba(255,255,255,0.1)", panelShadowOpacity: 0.5, commandBarSelected: "rgba(255,255,255,0.145)",
    selection: "rgba(120,125,134,0.7)", placeholder: "#FFFFFF87", goButton: "#DCCBD8", goButtonText: "#1A1418",
    ntpBarSolid: "#2D2D2D", ntpBarBorder: "rgba(120,125,134,0.32)", accent: "#4A77D4"
  )

  static let lightBase = PreviewTheme(
    dark: false, card: "rgba(255,255,255,0.7)", cardEdge: "rgba(0,0,0,0.08)", divider: "rgba(0,0,0,0.08)",
    textPrimary: "#000000", textTab: "#000000AD", textSecondary: "#00000080", textTertiary: "#00000059", icon: "#000000C6", iconDisabled: "#0000004D",
    tabSelected: "rgba(255,255,255,0.7)", tabSelectedText: "#000000", tabSelectedBorder: ["rgba(255,255,255,0.98)", "rgba(0,0,0,0.06)"],
    tabSelectedShadow: "rgba(0,0,0,0.12)", tabSelectedShadowRadius: 12.5, pinnedResting: "rgba(0,0,0,0.05)",
    toolbarHover: "rgba(0,0,0,0.06)", toolbarPressed: "rgba(0,0,0,0.1)", urlPill: "rgba(0,0,0,0.05)",
    panel: "#FFFFFF", panelBorder: "rgba(0,0,0,0.1)", panelShadowOpacity: 0.18, commandBarSelected: "rgba(15,24,44,0.08)",
    selection: "rgba(120,125,134,0.4)", placeholder: "#00000066", goButton: "#0F182C", goButtonText: "#FFFFFF",
    ntpBarSolid: "#FEFFFF", ntpBarBorder: "rgba(0,0,0,0.07)", accent: "#6395FC"
  )

  struct ColorSpec {
    let swatch: String
    let hasPalette: Bool
    let tint: String?
  }

  static func spec(_ color: ProfileColorValue) -> ColorSpec {
    ColorSpec(swatch: color.swatch, hasPalette: color != .neutral, tint: color == .plum ? "#B25B6B" : nil)
  }

  static func preset(_ color: ProfileColorValue, dark: Bool) -> PreviewTheme {
    var theme = dark ? darkBase : lightBase
    let spec = spec(color)
    let tint = backdropTint(spec.tint ?? PreviewColor.tintForHue(spec.swatch, grey: !spec.hasPalette), neutral: !spec.hasPalette)
    theme.windowTint = PreviewColor.opaqueTint(tint, dark: dark)
    return theme
  }

  struct BackdropTint {
    let color: String
    let alpha: Double
    let lightness: Double
  }

  static func backdropTint(_ color: String, neutral: Bool) -> BackdropTint {
    BackdropTint(color: color, alpha: neutral ? 0.12 : 0.36, lightness: 0.25)
  }
}

enum PreviewColor {
  static func rgb(_ hex: String) -> [Double] {
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    return (0..<3).map { i in
      let start = h.index(h.startIndex, offsetBy: min(h.count, 2 * i))
      let end = h.index(start, offsetBy: min(2, h.distance(from: start, to: h.endIndex)))
      return Double(UInt8(h[start..<end], radix: 16) ?? 0)
    }
  }

  static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }

  static func hex(_ c: [Double]) -> String {
    "#" + c.map { String(format: "%02X", Int(jsRound(min(255, max(0, $0))))) }.joined()
  }

  static func hsl(_ c: [Double]) -> (Double, Double, Double) {
    let r = c[0] / 255, g = c[1] / 255, b = c[2] / 255
    let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2, d = mx - mn
    if d == 0 { return (0, 0, l) }
    let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    let h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
    return (h / 6, s, l)
  }

  static func fromHsl(_ h: Double, _ s: Double, _ l: Double) -> [Double] {
    if s == 0 { return [l * 255, l * 255, l * 255] }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
    func ch(_ t: Double) -> Double {
      let t = t < 0 ? t + 1 : t > 1 ? t - 1 : t
      return t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p
    }
    return [ch(h + 1.0 / 3), ch(h), ch(h - 1.0 / 3)].map { $0 * 255 }
  }

  static func lighten(_ c: [Double], _ delta: Double) -> [Double] {
    let (h, s, l) = hsl(c)
    return fromHsl(h, s, min(1, max(0, l + delta)))
  }

  static func tintForHue(_ swatch: String, grey: Bool = false) -> String {
    let (h, _, _) = hsl(rgb(swatch))
    return hex(fromHsl(h, grey ? 0 : 0.36, 0.527))
  }

  static let inactiveDark = [40.7, 33.1, 31.8]
  static let inactiveLight = [235.0, 231, 230]

  static func opaqueTint(_ tint: PreviewTheme.BackdropTint, dark: Bool) -> [String] {
    let a = tint.alpha * (dark ? 0.5 : 0.75)
    let under = dark ? inactiveDark.map { 0.6 * $0 } : inactiveLight.map { 0.8 * 255 + 0.2 * $0 }
    let top = rgb(tint.color)
    let bottom = lighten(top, tint.lightness)
    func over(_ c: [Double]) -> String { hex(c.enumerated().map { a * $0.element + (1 - a) * under[$0.offset] }) }
    return [over(top), over(bottom)]
  }

  static func nearestPreset(_ hexColor: String) -> ProfileColorValue {
    let (h, s, _) = hsl(rgb(hexColor))
    if s < 0.12 { return .neutral }
    var best = ProfileColorValue.plum
    var distance = Double.infinity
    for color in ProfileColorValue.allCases where color != .neutral {
      let (sh, _, _) = hsl(rgb(color.swatch))
      let d = min(abs(sh - h), 1 - abs(sh - h))
      if d < distance {
        best = color
        distance = d
      }
    }
    return best
  }

  static func channels(_ color: String) -> (Double, Double, Double, Double) {
    let css = CSSColor(color) ?? CSSColor(red: 0, green: 0, blue: 0, alpha: 1)
    let byte = { (v: Double) in jsRound(min(255, max(0, v * 255))) }
    return (byte(css.red), byte(css.green), byte(css.blue), color.hasPrefix("#") ? (color.count >= 9 ? byte(css.alpha) / 255 : 1) : byte(css.alpha) / 255)
  }

  static func over(_ top: String, _ under: String) -> String {
    let (r, g, b, a) = channels(top)
    let (R, G, B, _) = channels(under)
    return hex([r * a + R * (1 - a), g * a + G * (1 - a), b * a + B * (1 - a)])
  }

  static func mix(_ a: String, _ b: String, _ t: Double) -> String {
    let (r, g, bl, _) = channels(a)
    let (R, G, B, _) = channels(b)
    return hex([r + (R - r) * t, g + (G - g) * t, bl + (B - bl) * t])
  }

  static func luminance(_ color: String) -> Double {
    guard color.hasPrefix("#"), color.count >= 7 else { return 0 }
    let c = rgb(String(color.prefix(7))).map { v -> Double in
      let s = v / 255
      return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
  }

  static func color(_ css: String) -> Color { CSSColor(css)?.color ?? .clear }
}

struct KitToolbarPalette {
  let background: String?
  let text: String
  let secondary: String
  let icon: String
  let divider: String

  static func make(_ theme: PreviewTheme, website: String?) -> KitToolbarPalette {
    guard let website, website.hasPrefix("#"), website.count >= 7 else {
      return KitToolbarPalette(background: nil, text: theme.textPrimary, secondary: theme.textSecondary, icon: theme.icon, divider: theme.divider)
    }
    let l = PreviewColor.luminance(website)
    let light = (1.05 / (l + 0.05)) < ((l + 0.05) / 0.05)
    let background = String(website.prefix(7))
    return light
      ? KitToolbarPalette(background: background, text: "#000000E6", secondary: "#00000080", icon: "#000000C6", divider: "rgba(0,0,0,0.1)")
      : KitToolbarPalette(background: background, text: "#FFFFFF", secondary: "#FFFFFF99", icon: "#FFFFFFD9", divider: "rgba(255,255,255,0.12)")
  }
}

struct PreviewLook {
  let dark: Bool
  let t: PreviewTheme
  let tint: [String]
  let card: String
  let page: String
  let ink: String
  let inkDim: String
  let inkFaint: String
  let site: KitToolbarPalette
  let plain: KitToolbarPalette

  @MainActor private static var cache: [String: PreviewLook] = [:]

  @MainActor
  static func of(dark: Bool, accent: String) -> PreviewLook {
    let key = "\(dark)|\(accent)"
    if let cached = cache[key] { return cached }
    let exact = ProfileColorValue.allCases.first { $0.swatch.lowercased() == accent.lowercased() }
    let t = PreviewTheme.preset(exact ?? PreviewColor.nearestPreset(accent), dark: dark)
    let tint = exact != nil ? t.windowTint : PreviewColor.opaqueTint(PreviewTheme.backdropTint(PreviewColor.tintForHue(accent), neutral: false), dark: dark)
    let look = PreviewLook(
      dark: dark,
      t: t,
      tint: tint,
      card: PreviewColor.over(t.card, PreviewColor.mix(tint[0], tint[1], 0.5)),
      page: dark ? "#161718" : "#FFFFFF",
      ink: dark ? "#ECECEE" : "#1D1D1F",
      inkDim: dark ? "rgba(236,236,238,0.62)" : "rgba(29,29,31,0.62)",
      inkFaint: dark ? "rgba(236,236,238,0.4)" : "rgba(29,29,31,0.42)",
      site: KitToolbarPalette.make(t, website: PreviewArticle.notes.band[dark ? 1 : 0]),
      plain: KitToolbarPalette.make(t, website: nil)
    )
    cache[key] = look
    return look
  }

  func with(tint: [String]) -> PreviewLook {
    PreviewLook(dark: dark, t: t, tint: tint, card: card, page: page, ink: ink, inkDim: inkDim, inkFaint: inkFaint, site: site, plain: plain)
  }

  func pick<T>(_ pair: [T]) -> T { pair[dark ? 1 : 0] }
}
