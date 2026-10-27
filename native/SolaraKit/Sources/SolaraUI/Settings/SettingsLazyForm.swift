import SwiftUI

enum SettingsFormMetrics {
  static let maxWidth: CGFloat = 600
  static let sideInset: CGFloat = 24
  static let topInset: CGFloat = 20
  static let bottomInset: CGFloat = 40
  static let headerTop: CGFloat = 22
  static let headerBottom: CGFloat = 8
  static let headerLeading: CGFloat = 2
  static let headerlessSectionSpacing: CGFloat = 14
  static let footerTop: CGFloat = 8
  static let groupRadius: CGFloat = 10
  static let border: CGFloat = 1
  static let rowHorizontal: CGFloat = 12
  static let rowVertical: CGFloat = 9
  static let rowMinHeight: CGFloat = 40
  static let rowGap: CGFloat = 12
  static let separatorInset: CGFloat = 12
  static let descriptionGap: CGFloat = 2
  static let labelIconSpacing: CGFloat = 12
}

struct SettingsLazyForm<Content: View>: View {
  @Environment(\.settingsContext) private var context
  @Environment(\.colorScheme) private var scheme
  @State private var eager = false
  let content: Content

  var body: some View {
    let revealing = context?.search.reveal != nil
    Group {
      if eager || revealing {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 0) { sections }
            .modifier(SettingsFormInsets())
        }
      } else {
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: 0) { sections }
            .modifier(SettingsFormInsets())
        }
      }
    }
    .labeledContentStyle(SettingsRowStyle())
    .buttonStyle(SettingsButtonStyle())
    .textFieldStyle(SettingsTextFieldStyle())
    .onChange(of: revealing, initial: true) { _, now in
      if now { eager = true }
    }
  }

  private var sections: some View {
    Group(sections: content) { sections in
      ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
        SettingsLazySectionRows(section: section, first: index == 0)
      }
    }
  }
}

struct SettingsFormInsets: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, SettingsFormMetrics.sideInset)
      .padding(.bottom, SettingsFormMetrics.bottomInset)
      .frame(maxWidth: SettingsFormMetrics.maxWidth)
      .frame(maxWidth: .infinity)
  }
}

struct SettingsLazySectionRows: View {
  @Environment(\.colorScheme) private var scheme
  let section: SectionConfiguration
  let first: Bool

  var body: some View {
    let theme = SettingsTheme(scheme)
    let rows = section.content
    let hasHeader = !section.header.isEmpty
    Color.clear.frame(height: spacing(hasHeader: hasHeader, empty: rows.isEmpty))
    if hasHeader {
      VStack(alignment: .leading, spacing: 0) { section.header }
        .environment(\.settingsFormHeader, true)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, SettingsFormMetrics.headerLeading)
        .padding(.bottom, rows.isEmpty ? 0 : SettingsFormMetrics.headerBottom)
    }
    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
      SettingsLazyRow(first: index == 0, last: index == rows.count - 1) { row }
    }
    if !section.footer.isEmpty {
      VStack(alignment: .leading, spacing: 0) { section.footer }
        .font(.system(size: 11.5))
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, SettingsFormMetrics.headerLeading)
        .padding(.top, SettingsFormMetrics.footerTop)
    }
  }

  private func spacing(hasHeader: Bool, empty: Bool) -> CGFloat {
    if hasHeader { return SettingsFormMetrics.headerTop }
    if first { return SettingsFormMetrics.topInset }
    return empty ? 0 : SettingsFormMetrics.headerlessSectionSpacing
  }
}

struct SettingsLazyRow<Row: View>: View {
  @Environment(\.colorScheme) private var scheme
  let first: Bool
  let last: Bool
  @ViewBuilder let row: Row

  var body: some View {
    let theme = SettingsTheme(scheme)
    let radius = SettingsFormMetrics.groupRadius
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: first ? radius : 0, bottomLeadingRadius: last ? radius : 0,
      bottomTrailingRadius: last ? radius : 0, topTrailingRadius: first ? radius : 0
    )
    VStack(spacing: 0) {
      if !first {
        Rectangle().fill(theme.separator).frame(height: SettingsFormMetrics.border)
          .padding(.horizontal, SettingsFormMetrics.separatorInset)
      }
      row
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsFormMetrics.rowHorizontal)
        .padding(.vertical, SettingsFormMetrics.rowVertical)
        .frame(minHeight: SettingsFormMetrics.rowMinHeight)
    }
    .padding(.horizontal, SettingsFormMetrics.border)
    .padding(.top, first ? SettingsFormMetrics.border : 0)
    .padding(.bottom, last ? SettingsFormMetrics.border : 0)
    .background(shape.fill(theme.group))
    .overlay {
      SettingsGroupEdge(first: first, last: last, radius: radius)
        .stroke(theme.groupBorder, lineWidth: SettingsFormMetrics.border)
        .padding(SettingsFormMetrics.border / 2)
    }
  }
}

struct SettingsGroupEdge: Shape {
  let first: Bool
  let last: Bool
  let radius: CGFloat

  func path(in rect: CGRect) -> Path {
    let r = max(0, radius - 0.5)
    var path = Path()
    let top = first ? rect.minY : rect.minY - 1
    let bottom = last ? rect.maxY : rect.maxY + 1
    path.move(to: CGPoint(x: rect.minX, y: bottom - (last ? r : 0)))
    path.addLine(to: CGPoint(x: rect.minX, y: top + (first ? r : 0)))
    if first {
      path.addArc(center: CGPoint(x: rect.minX + r, y: top + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
      path.addLine(to: CGPoint(x: rect.maxX - r, y: top))
      path.addArc(center: CGPoint(x: rect.maxX - r, y: top + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
    } else {
      path.move(to: CGPoint(x: rect.maxX, y: top))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: bottom - (last ? r : 0)))
    if last {
      path.addArc(center: CGPoint(x: rect.maxX - r, y: bottom - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
      path.addLine(to: CGPoint(x: rect.minX + r, y: bottom))
      path.addArc(center: CGPoint(x: rect.minX + r, y: bottom - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
    }
    return path
  }
}

struct SettingsRowStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    SettingsRow(configuration: configuration)
  }
}

struct SettingsRow: View {
  @Namespace private var pair
  let configuration: LabeledContentStyleConfiguration

  var body: some View {
    HStack(alignment: .center, spacing: SettingsFormMetrics.rowGap) {
      SettingsRowLabelText(label: configuration.label)
        .labelStyle(SettingsRowLabelStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabeledPair(role: .label, id: "row", in: pair)
      configuration.content
        .environment(\.settingsFormRowControl, true)
        .accessibilityLabeledPair(role: .content, id: "row", in: pair)
    }
  }
}

struct SettingsRowLabelText<Label: View>: View {
  @Environment(\.colorScheme) private var scheme
  let label: Label

  var body: some View {
    let theme = SettingsTheme(scheme)
    Group(subviews: label) { parts in
      VStack(alignment: .leading, spacing: SettingsFormMetrics.descriptionGap) {
        ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
          if index == 0 {
            part.font(.system(size: 13)).foregroundStyle(theme.textPrimary)
          } else {
            part.font(.system(size: 11.5)).foregroundStyle(theme.textSecondary).lineSpacing(1).fixedSize(horizontal: false, vertical: true).frame(minHeight: 15)
          }
        }
      }
    }
  }
}

struct SettingsRowLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .center, spacing: SettingsFormMetrics.labelIconSpacing) {
      configuration.icon
      SettingsRowLabelText(label: configuration.title)
    }
  }
}

public struct SettingsSwitchStyle: ToggleStyle {
  public func makeBody(configuration: Configuration) -> some View {
    SettingsSwitch(configuration: configuration)
  }
}

struct SettingsSwitch: View {
  static let width: CGFloat = 32
  static let height: CGFloat = 18
  static let knob: CGFloat = 15
  static let inset: CGFloat = 1.5

  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  let configuration: ToggleStyleConfiguration

  var body: some View {
    let theme = SettingsTheme(scheme)
    let on = configuration.isOn
    Button { configuration.isOn.toggle() } label: {
      ZStack(alignment: .leading) {
        Capsule().fill(theme.switchOff)
        Capsule().fill(theme.accent).opacity(on ? 1 : 0)
        Circle()
          .fill(Color.white)
          .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
          .frame(width: Self.knob, height: Self.knob)
          .offset(x: Self.inset + (on ? Self.width - Self.knob - Self.inset * 2 : 0))
      }
      .frame(width: Self.width, height: Self.height)
      .animation(.rn(160, .outCubic), value: on)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
    }
  }
}

public extension ToggleStyle where Self == SettingsSwitchStyle {
  static var settingsSwitch: SettingsSwitchStyle { SettingsSwitchStyle() }
}

public struct SettingsButtonStyle: ButtonStyle {
  public enum Kind: Sendable { case standard, primary, plain }

  var kind: Kind = .standard

  public init(kind: Kind = .standard) {
    self.kind = kind
  }

  public func makeBody(configuration: Configuration) -> some View {
    SettingsButtonBody(configuration: configuration, kind: kind)
  }
}

public extension ButtonStyle where Self == SettingsButtonStyle {
  static var settingsPrimary: SettingsButtonStyle { SettingsButtonStyle(kind: .primary) }
  static var settingsPlain: SettingsButtonStyle { SettingsButtonStyle(kind: .plain) }
}

struct SettingsButtonBody: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  let configuration: ButtonStyleConfiguration
  let kind: SettingsButtonStyle.Kind
  @State private var hovered = false

  var body: some View {
    let theme = SettingsTheme(scheme)
    let destructive = configuration.role == .destructive
    let text: Color = kind == .primary ? .white : destructive ? theme.destructive : kind == .plain ? theme.accent : theme.textPrimary
    let pressed = configuration.isPressed
    let fill: Color = switch kind {
    case .plain: .clear
    case .primary: pressed ? theme.accentPressed : theme.accent
    case .standard: pressed ? theme.controlPressed : hovered ? theme.controlHover : theme.control
    }
    configuration.label
      .font(.system(size: 13))
      .foregroundStyle(text)
      .labelStyle(SettingsButtonLabelStyle())
      .lineLimit(1)
      .underline(kind == .plain && hovered)
      .padding(.horizontal, kind == .plain ? 0 : 10)
      .frame(height: kind == .plain ? nil : 22)
      .background(RoundedRectangle(cornerRadius: 5.5).fill(fill))
      .overlay {
        if kind == .standard { RoundedRectangle(cornerRadius: 5.5).strokeBorder(theme.controlBorder, lineWidth: 1) }
      }
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.45)
      .onHover { hovered = $0 }
      .fixedSize()
  }
}

struct SettingsButtonLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 5) {
      configuration.icon.font(.system(size: 11)).frame(width: 13, height: 13)
      configuration.title
    }
  }
}

public struct SettingsTextFieldStyle: TextFieldStyle {
  public init() {}

  public func _body(configuration: TextField<Self._Label>) -> some View {
    configuration.modifier(SettingsFieldChrome())
  }
}

struct SettingsFieldChrome: ViewModifier {
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    let theme = SettingsTheme(scheme)
    content
      .textFieldStyle(.plain)
      .font(.system(size: 13))
      .foregroundStyle(theme.textPrimary)
      .padding(.horizontal, 7)
      .frame(height: 24)
      .background(RoundedRectangle(cornerRadius: 5).fill(theme.field))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.fieldBorder, lineWidth: 1))
  }
}

extension EnvironmentValues {
  @Entry var settingsFormHeader = false
  @Entry var settingsFormRowControl = false
}
