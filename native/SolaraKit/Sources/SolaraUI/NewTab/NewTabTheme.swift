import AppKit
import SwiftUI

public struct NewTabTheme: Equatable, Sendable {
  public var dark: Bool
  public var textPrimary: CSSColor
  public var textSecondary: CSSColor
  public var textTertiary: CSSColor
  public var placeholder: CSSColor
  public var selection: CSSColor
  public var chipBorder: CSSColor
  public var chipText: CSSColor
  public var rowHover: CSSColor
  public var rowSelected: CSSColor
  public var commandBarSelected: CSSColor
  public var commandBarHover: CSSColor
  public var goButton: CSSColor
  public var goButtonText: CSSColor
  public var goButtonIdle: CSSColor
  public var ntpBarSolid: CSSColor
  public var ntpBarBorder: CSSColor
  public var toolbarHover: CSSColor
  public var toolbarPressed: CSSColor

  public static let keys = [
    "textPrimary", "textSecondary", "textTertiary", "placeholder", "selection", "chipBorder", "chipText", "rowHover", "rowSelected",
    "commandBarSelected", "commandBarHover", "goButton", "goButtonText", "goButtonIdle", "ntpBarSolid", "ntpBarBorder", "toolbarHover", "toolbarPressed",
  ]

  public init(dark: Bool, tokens: [String: String]) {
    func c(_ key: String, _ fallback: String) -> CSSColor { CSSColor(tokens[key] ?? fallback) ?? CSSColor(fallback)! }
    self.dark = dark
    textPrimary = c("textPrimary", dark ? "#FFFFFF" : "#000000")
    textSecondary = c("textSecondary", dark ? "#FFFFFF80" : "#00000080")
    textTertiary = c("textTertiary", dark ? "#FFFFFF59" : "#00000059")
    placeholder = c("placeholder", dark ? "#FFFFFF87" : "#00000066")
    selection = c("selection", dark ? "rgba(120,125,134,0.7)" : "rgba(120,125,134,0.4)")
    chipBorder = c("chipBorder", dark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.12)")
    chipText = c("chipText", dark ? "#FFFFFF99" : "#00000099")
    rowHover = c("rowHover", dark ? "rgba(255,255,255,0.07)" : "rgba(15,24,44,0.05)")
    rowSelected = c("rowSelected", dark ? "rgba(255,255,255,0.22)" : "rgba(15,24,44,0.08)")
    commandBarSelected = c("commandBarSelected", dark ? "rgba(255,255,255,0.145)" : "rgba(15,24,44,0.08)")
    commandBarHover = c("commandBarHover", dark ? "rgba(120,125,134,0.32)" : "rgba(15,24,44,0.05)")
    goButton = c("goButton", dark ? "#DCCBD8" : "#0F182C")
    goButtonText = c("goButtonText", dark ? "#1A1418" : "#FFFFFF")
    goButtonIdle = c("goButtonIdle", dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.06)")
    ntpBarSolid = c("ntpBarSolid", dark ? "#2D2D2D" : "#FEFFFF")
    ntpBarBorder = c("ntpBarBorder", dark ? "rgba(120,125,134,0.32)" : "rgba(0,0,0,0.07)")
    toolbarHover = c("toolbarHover", dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.06)")
    toolbarPressed = c("toolbarPressed", dark ? "rgba(255,255,255,0.18)" : "rgba(0,0,0,0.1)")
  }

  public static let fallbackDark = NewTabTheme(dark: true, tokens: [:])
  public static let fallbackLight = NewTabTheme(dark: false, tokens: [:])
}

public struct CSSColor: Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public init?(_ text: String) {
    let s = text.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") {
      var h = String(s.dropFirst())
      if h.count == 3 || h.count == 4 { h = h.map { "\($0)\($0)" }.joined() }
      guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
      let rgba = h.count == 6 ? (v << 8) | 0xFF : v
      self.init(
        red: Double((rgba >> 24) & 0xFF) / 255, green: Double((rgba >> 16) & 0xFF) / 255, blue: Double((rgba >> 8) & 0xFF) / 255,
        alpha: Double(rgba & 0xFF) / 255)
      return
    }
    guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
    let parts = s[s.index(after: open)..<s.index(before: s.endIndex)].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count >= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
    self.init(red: parts[0]! / 255, green: parts[1]! / 255, blue: parts[2]! / 255, alpha: parts.count > 3 ? parts[3]! : 1)
  }

  public var ns: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
  public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
  public var cg: CGColor { ns.cgColor }

  public func withAlpha(_ a: Double) -> CSSColor { CSSColor(red: red, green: green, blue: blue, alpha: a) }
}
