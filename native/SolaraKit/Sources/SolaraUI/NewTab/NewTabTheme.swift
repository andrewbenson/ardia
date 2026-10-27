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
  public var icon: CSSColor
  public var iconDisabled: CSSColor

  public static let keys = NewTabThemeTokens.keys

  public init(dark: Bool, tokens: [String: String]) {
    let defaults = dark ? NewTabThemeTokens.dark : NewTabThemeTokens.light
    func c(_ key: String) -> CSSColor { tokens[key].flatMap { CSSColor($0) } ?? CSSColor(defaults[key]!)! }
    self.dark = dark
    textPrimary = c("textPrimary")
    textSecondary = c("textSecondary")
    textTertiary = c("textTertiary")
    placeholder = c("placeholder")
    selection = c("selection")
    chipBorder = c("chipBorder")
    chipText = c("chipText")
    rowHover = c("rowHover")
    rowSelected = c("rowSelected")
    commandBarSelected = c("commandBarSelected")
    commandBarHover = c("commandBarHover")
    goButton = c("goButton")
    goButtonText = c("goButtonText")
    goButtonIdle = c("goButtonIdle")
    ntpBarSolid = c("ntpBarSolid")
    ntpBarBorder = c("ntpBarBorder")
    toolbarHover = c("toolbarHover")
    toolbarPressed = c("toolbarPressed")
    icon = c("icon")
    iconDisabled = c("iconDisabled")
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
