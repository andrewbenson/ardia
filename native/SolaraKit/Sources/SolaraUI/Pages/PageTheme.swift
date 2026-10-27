import AppKit
import SwiftUI

public struct PageTheme: Equatable, Sendable {
  public var dark: Bool
  public var base: NewTabTheme
  public var panel: CSSColor
  public var panelBorder: CSSColor
  public var panelShadowOpacity: Double

  public static let tokenKeys = NewTabTheme.keys + ["panel", "panelBorder"]

  public init(dark: Bool, tokens: [String: String], panelShadowOpacity: Double? = nil) {
    self.dark = dark
    base = NewTabTheme(dark: dark, tokens: tokens)
    panel = tokens["panel"].flatMap { CSSColor($0) } ?? CSSColor(dark ? "#2A2A2A" : "#FFFFFF")!
    panelBorder = tokens["panelBorder"].flatMap { CSSColor($0) } ?? CSSColor(dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)")!
    self.panelShadowOpacity = panelShadowOpacity ?? (dark ? 0.5 : 0.18)
  }

  public static let fallbackLight = PageTheme(dark: false, tokens: [:])

  var textPrimary: Color { base.textPrimary.color }
  var textSecondary: Color { base.textSecondary.color }
  var textTertiary: Color { base.textTertiary.color }
  var rowHover: Color { base.rowHover.color }
  var toolbarHover: Color { base.toolbarHover.color }
  var toolbarPressed: Color { base.toolbarPressed.color }
  var icon: Color { base.icon.color }
  var iconDisabled: Color { base.iconDisabled.color }
  var accentTheme: Color { base.accent.color }

  private static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
  }

  var group: Color { dark ? Self.rgba(255, 255, 255, 0.045) : Self.rgba(0, 0, 0, 0.028) }
  var groupBorder: Color { dark ? Self.rgba(255, 255, 255, 0.07) : Self.rgba(0, 0, 0, 0.07) }
  var separator: Color { dark ? Self.rgba(255, 255, 255, 0.07) : Self.rgba(0, 0, 0, 0.07) }
  var control: Color { dark ? Self.rgba(255, 255, 255, 0.1) : Self.rgba(255, 255, 255) }
  var controlHover: Color { dark ? Self.rgba(255, 255, 255, 0.14) : Self.rgba(0xF7, 0xF7, 0xF7) }
  var controlPressed: Color { dark ? Self.rgba(255, 255, 255, 0.2) : Self.rgba(0xEB, 0xEB, 0xEB) }
  var controlBorder: Color { dark ? Self.rgba(255, 255, 255, 0.08) : Self.rgba(0, 0, 0, 0.14) }
  var field: Color { dark ? Self.rgba(0, 0, 0, 0.25) : Self.rgba(255, 255, 255) }
  var fieldBorder: Color { dark ? Self.rgba(255, 255, 255, 0.12) : Self.rgba(0, 0, 0, 0.14) }
  var accent: Color { dark ? Self.rgba(0x0A, 0x84, 0xFF) : Self.rgba(0x00, 0x7A, 0xFF) }
  var accentPressed: Color { Self.rgba(0x00, 0x60, 0xD0) }
  var destructive: Color { dark ? Self.rgba(0xFF, 0x45, 0x3A) : Self.rgba(0xFF, 0x3B, 0x30) }
  var selected: Color { dark ? Self.rgba(255, 255, 255, 0.1) : Self.rgba(0, 0, 0, 0.06) }
}

struct PageThemeKey: EnvironmentKey {
  static let defaultValue = PageTheme.fallbackLight
}

extension EnvironmentValues {
  var pageTheme: PageTheme {
    get { self[PageThemeKey.self] }
    set { self[PageThemeKey.self] = newValue }
  }
}
