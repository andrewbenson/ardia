import SwiftUI

public struct ClearDataRequest: Equatable, Sendable {
  public var range: String
  public var history: Bool
  public var siteData: Bool
}

struct ClearDataDialogView: View {
  @Environment(\.pageTheme) private var theme
  let profileName: String?
  let busy: Bool
  let onClose: () -> Void
  let onClear: (ClearDataRequest) -> Void
  @State private var range = "hour"
  @State private var history = true
  @State private var siteData = true

  static let ranges = [
    PageOption(value: "hour", title: "Last hour"),
    PageOption(value: "day", title: "Last 24 hours"),
    PageOption(value: "week", title: "Last 7 days"),
    PageOption(value: "month", title: "Last 4 weeks"),
    PageOption(value: "all", title: "All time"),
  ]

  var body: some View {
    ZStack {
      Rectangle()
        .fill(Color.black.opacity(theme.dark ? 0.35 : 0.15))
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        OnboardingText("Clear Browsing Data", size: 15, weight: 600, color: theme.textPrimary, lines: 1)
          .accessibilityAddTraits(.isHeader)
        if let profileName {
          OnboardingText("From your \(profileName) profile", size: 12, color: theme.textSecondary, lines: 1).padding(.top, 4)
        }
        HStack(spacing: 10) {
          OnboardingText("Time range", size: 13, color: theme.textPrimary, lines: 1).fixedSize().offset(y: -0.5)
          PagePopUp(value: range, options: Self.ranges, minWidth: 150) { range = $0 }
        }
        .padding(.top, 16)
        VStack(alignment: .leading, spacing: 12) {
          option($history, "Browsing history", "Clears the pages you visited from History and the command bar.")
          option($siteData, "Cookies, site data and cached files", "Signs you out of most sites.")
        }
        .padding(.top, 16)
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          PageButton(title: "Cancel", action: onClose)
          PageButton(title: "Clear Data", kind: .primary, disabled: busy || (!history && !siteData)) {
            onClear(ClearDataRequest(range: range, history: history, siteData: siteData))
          }
        }
        .padding(.top, 22)
      }
      .padding(20.5)
      .frame(width: 440)
      .background(RoundedRectangle(cornerRadius: 14, style: .circular).fill(theme.panel.color))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .circular).strokeBorder(theme.panelBorder.color, lineWidth: 0.5))
      .shadow(color: .black.opacity(theme.panelShadowOpacity), radius: 30, y: 12)
      .accessibilityElement(children: .contain)
      .accessibilityAddTraits(.isModal)
      .accessibilityLabel("Clear Browsing Data")
    }
    .onExitCommand(perform: onClose)
  }

  private func option(_ value: Binding<Bool>, _ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      PageCheckbox(on: value.wrappedValue, label: title) { value.wrappedValue.toggle() }
      OnboardingText(subtitle, size: 11.5, color: theme.textSecondary, lines: 1)
        .padding(.leading, 21)
        .padding(.top, 2)
    }
  }
}
