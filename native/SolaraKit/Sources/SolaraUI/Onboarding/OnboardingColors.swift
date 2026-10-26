import SwiftUI

struct OnboardingColors {
  let background: Color
  let overlay: Color
  let card: Color
  let cardBorder: Color
  let title: Color
  let subtitle: Color
  let body: Color
  let footnote: Color
  let steps: Color
  let row: Color
  let rowBorder: Color
  let rowSubtitle: Color
  let primary: Color
  let primaryHover: Color
  let primaryText: Color
  let button: Color
  let buttonHover: Color
  let buttonText: Color
  let outlinedHover: Color
  let noThanksBorder: Color
  let noThanksText: Color
  let iconContainer: Color
  let separator: Color
  let preview: Color
  let previewBorder: Color
  let progressTrack: Color
  let progressFill: Color
  let checkbox: Color
  let checkboxBorder: Color
  let checkboxOn: Color
  let checkmark: Color

  static func css(_ text: String) -> Color { CSSColor(text)?.color ?? .clear }

  static let dark = OnboardingColors(
    background: css("#000000"),
    overlay: css("rgba(0,0,0,0.6)"),
    card: css("#161616"),
    cardBorder: css("rgba(254,255,255,0.3)"),
    title: css("#FEFFFF"),
    subtitle: css("rgba(254,255,255,0.6)"),
    body: css("rgba(255,255,255,0.55)"),
    footnote: css("rgba(255,255,255,0.5)"),
    steps: css("rgba(255,255,255,0.3)"),
    row: css("rgba(255,255,255,0.08)"),
    rowBorder: css("rgba(255,255,255,0.16)"),
    rowSubtitle: css("rgba(255,255,255,0.6)"),
    primary: css("rgba(255,255,255,0.85)"),
    primaryHover: css("rgba(255,255,255,0.9)"),
    primaryText: css("#000000"),
    button: css("rgba(255,255,255,0.08)"),
    buttonHover: css("rgba(255,255,255,0.1)"),
    buttonText: css("#FFFFFF"),
    outlinedHover: css("rgba(255,255,255,0.03)"),
    noThanksBorder: css("rgba(254,255,255,0.2)"),
    noThanksText: css("rgba(254,255,255,0.5)"),
    iconContainer: css("rgba(255,255,255,0.15)"),
    separator: css("rgba(254,255,255,0.1)"),
    preview: css("rgba(255,255,255,0.04)"),
    previewBorder: css("rgba(255,255,255,0.1)"),
    progressTrack: css("rgba(255,255,255,0.12)"),
    progressFill: css("#FDD023"),
    checkbox: css("rgba(255,255,255,0.1)"),
    checkboxBorder: css("rgba(255,255,255,0.25)"),
    checkboxOn: css("#FEFFFF"),
    checkmark: css("#000000")
  )

  static let light = OnboardingColors(
    background: css("#FEFFFF"),
    overlay: css("rgba(254,255,255,0.6)"),
    card: css("#FFFFFF"),
    cardBorder: css("rgba(0,0,0,0.08)"),
    title: css("#000000"),
    subtitle: css("rgba(0,0,0,0.53)"),
    body: css("rgba(0,0,0,0.55)"),
    footnote: css("rgba(0,0,0,0.5)"),
    steps: css("rgba(0,0,0,0.3)"),
    row: css("rgba(0,0,0,0.015)"),
    rowBorder: css("rgba(0,0,0,0.08)"),
    rowSubtitle: css("rgba(0,0,0,0.6)"),
    primary: css("rgba(0,0,0,0.85)"),
    primaryHover: css("rgba(0,0,0,0.9)"),
    primaryText: css("#FEFFFF"),
    button: css("rgba(0,0,0,0.08)"),
    buttonHover: css("rgba(0,0,0,0.1)"),
    buttonText: css("#000000"),
    outlinedHover: css("rgba(0,0,0,0.03)"),
    noThanksBorder: css("rgba(0,0,0,0.1)"),
    noThanksText: css("rgba(0,0,0,0.5)"),
    iconContainer: css("rgba(0,0,0,0.03)"),
    separator: css("rgba(0,0,0,0.1)"),
    preview: css("rgba(0,0,0,0.025)"),
    previewBorder: css("rgba(0,0,0,0.07)"),
    progressTrack: css("rgba(0,0,0,0.08)"),
    progressFill: css("#FDD023"),
    checkbox: css("#FFFFFF"),
    checkboxBorder: css("rgba(0,0,0,0.2)"),
    checkboxOn: css("#000000"),
    checkmark: css("#FFFFFF")
  )

  static func of(_ scheme: ColorScheme) -> OnboardingColors { scheme == .dark ? dark : light }
}
