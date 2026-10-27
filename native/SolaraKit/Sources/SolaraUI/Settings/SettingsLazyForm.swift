import SwiftUI

enum SettingsFormMetrics {
  static let sideInset: CGFloat = 20
  static let topInset: CGFloat = 20
  static let bottomInset: CGFloat = 20
  static let sectionSpacing: CGFloat = 30
  static let headerlessSectionSpacing: CGFloat = 10
  static let headerBottom: CGFloat = 10
  static let headerLeading: CGFloat = 10
  static let footerTop: CGFloat = 10
  static let boxRadius: CGFloat = 12
  static let rowHorizontal: CGFloat = 10
  static let rowTop: CGFloat = 10
  static let rowBottom: CGFloat = 10
  static let separator: CGFloat = 1
  static let controlDrop: CGFloat = 0.5
  static let controlBottom: CGFloat = 10
  static let switchRowGrowth: CGFloat = 0.5
  static let titleBaselineAboveCenter: CGFloat = 5
  static let descriptionSpacing: CGFloat = 2
  static let labelIconSpacing: CGFloat = 10
  static let controlSpacing: CGFloat = 12
  static let labelMinWidth: CGFloat = 210
  static let stackedSpacing: CGFloat = 8
  static let separatorLeading: CGFloat = 10
}

struct SettingsLazyForm<Content: View>: View {
  @Environment(\.settingsContext) private var context
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
  }
}

struct SettingsLazySectionRows: View {
  let section: SectionConfiguration
  let first: Bool

  var body: some View {
    let rows = section.content
    let hasHeader = !section.header.isEmpty
    Color.clear.frame(height: first ? SettingsFormMetrics.topInset : hasHeader ? SettingsFormMetrics.sectionSpacing : rows.isEmpty ? 0 : SettingsFormMetrics.headerlessSectionSpacing)
    if hasHeader {
      VStack(alignment: .leading, spacing: 0) { section.header }
        .environment(\.settingsFormHeader, true)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, SettingsFormMetrics.headerLeading)
        .padding(.bottom, SettingsFormMetrics.headerBottom)
    }
    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
      SettingsLazyRow(first: index == 0, last: index == rows.count - 1) { row }
    }
    if !section.footer.isEmpty {
      VStack(alignment: .leading, spacing: 0) { section.footer }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, SettingsFormMetrics.headerLeading)
        .padding(.top, SettingsFormMetrics.footerTop)
    }
  }
}

struct SettingsLazyRow<Row: View>: View {
  @Environment(\.colorScheme) private var scheme
  let first: Bool
  let last: Bool
  @ViewBuilder let row: Row

  var body: some View {
    let radius = SettingsFormMetrics.boxRadius
    row
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, SettingsFormMetrics.rowHorizontal)
      .padding(.top, SettingsFormMetrics.rowTop)
      .padding(.bottom, SettingsFormMetrics.rowBottom)
      .padding(.top, first ? 0 : SettingsFormMetrics.separator)
      .overlay(alignment: .top) {
        if !first {
          Rectangle()
            .fill(SettingsFormColors.separator(scheme))
            .frame(height: SettingsFormMetrics.separator)
            .padding(.horizontal, SettingsFormMetrics.separatorLeading)
        }
      }
      .background(
        UnevenRoundedRectangle(
          topLeadingRadius: first ? radius : 0,
          bottomLeadingRadius: last ? radius : 0,
          bottomTrailingRadius: last ? radius : 0,
          topTrailingRadius: first ? radius : 0,
          style: .continuous
        )
        .fill(SettingsFormColors.box(scheme))
      )
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
    SettingsRowLayout {
      SettingsRowLabelText(label: configuration.label)
        .labelStyle(SettingsRowLabelStyle())
        .alignmentGuide(.settingsRowTitle) { $0[.firstTextBaseline] - SettingsFormMetrics.titleBaselineAboveCenter }
        .accessibilityElement(children: .combine)
        .accessibilityLabeledPair(role: .label, id: "row", in: pair)
      configuration.content
        .environment(\.settingsFormRowControl, true)
        .alignmentGuide(.settingsRowTitle) { $0[VerticalAlignment.center] }
        .offset(y: SettingsFormMetrics.controlDrop)
        .accessibilityLabeledPair(role: .content, id: "row", in: pair)
    }
  }
}

struct SettingsRowLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let arrangement = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
    for (index, frame) in arrangement.frames.enumerated() where subviews.indices.contains(index) {
      subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
    guard subviews.count == 2 else {
      let size = subviews.first?.sizeThatFits(proposal) ?? .zero
      return (size, [CGRect(origin: .zero, size: size)])
    }
    let label = subviews[0], content = subviews[1]
    let width = proposal.width ?? label.sizeThatFits(.unspecified).width + SettingsFormMetrics.controlSpacing + content.sizeThatFits(.unspecified).width
    let contentSize = content.sizeThatFits(.unspecified)
    let labelNeeds = min(label.sizeThatFits(.unspecified).width, SettingsFormMetrics.labelMinWidth)
    if contentSize.width + SettingsFormMetrics.controlSpacing + labelNeeds > width {
      let labelSize = label.sizeThatFits(ProposedViewSize(width: width, height: nil))
      let contentTop = labelSize.height + SettingsFormMetrics.stackedSpacing
      return (
        CGSize(width: width, height: contentTop + contentSize.height),
        [CGRect(x: 0, y: 0, width: width, height: labelSize.height), CGRect(x: max(0, width - contentSize.width), y: contentTop, width: min(contentSize.width, width), height: contentSize.height)]
      )
    }
    let labelWidth = max(0, width - contentSize.width - SettingsFormMetrics.controlSpacing)
    let labelSize = label.sizeThatFits(ProposedViewSize(width: labelWidth, height: nil))
    let labelLine = label.dimensions(in: ProposedViewSize(width: labelWidth, height: nil))[.settingsRowTitle]
    let contentLine = content.dimensions(in: .unspecified)[.settingsRowTitle]
    let above = max(labelLine, contentLine - SettingsFormMetrics.rowTop)
    let below = max(labelSize.height - labelLine, contentSize.height - contentLine - SettingsFormMetrics.rowBottom + SettingsFormMetrics.controlBottom)
    return (
      CGSize(width: width, height: above + below),
      [CGRect(x: 0, y: above - labelLine, width: labelWidth, height: labelSize.height), CGRect(x: width - contentSize.width, y: above - contentLine, width: contentSize.width, height: contentSize.height)]
    )
  }
}

struct SettingsRowLabelText<Label: View>: View {
  let label: Label

  var body: some View {
    Group(subviews: label) { parts in
      VStack(alignment: .leading, spacing: SettingsFormMetrics.descriptionSpacing) {
        ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
          if index == 0 {
            part.font(.body).foregroundStyle(.primary)
          } else {
            part.font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}

struct SettingsRowLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .settingsRowTitle, spacing: SettingsFormMetrics.labelIconSpacing) {
      configuration.icon
        .alignmentGuide(.settingsRowTitle) { $0[VerticalAlignment.center] }
      SettingsRowLabelText(label: configuration.title)
        .alignmentGuide(.settingsRowTitle) { $0[.firstTextBaseline] - SettingsFormMetrics.titleBaselineAboveCenter }
    }
  }
}

extension VerticalAlignment {
  private enum SettingsRowTitle: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
  }

  static let settingsRowTitle = VerticalAlignment(SettingsRowTitle.self)
}

public struct SettingsSwitchStyle: ToggleStyle {
  public func makeBody(configuration: Configuration) -> some View {
    SettingsSwitch(configuration: configuration)
  }
}

struct SettingsSwitch: View {
  @Environment(\.settingsFormRowControl) private var inRow
  let configuration: ToggleStyleConfiguration

  var body: some View {
    Toggle(configuration)
      .toggleStyle(.switch)
      .controlSize(.mini)
      .padding(.vertical, inRow ? SettingsFormMetrics.switchRowGrowth : 0)
      .modifier(SettingsProbeSwitch(on: configuration.isOn))
  }
}

public extension ToggleStyle where Self == SettingsSwitchStyle {
  static var settingsSwitch: SettingsSwitchStyle { SettingsSwitchStyle() }
}

enum SettingsFormColors {
  static func box(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.03)
  }

  static func popUpCircle(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.081) : Color.black.opacity(0.075)
  }

  static func separator(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.048)
  }
}

extension EnvironmentValues {
  @Entry var settingsFormHeader = false
  @Entry var settingsFormRowControl = false
}
