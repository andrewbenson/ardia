import AppKit
import SwiftUI

private struct OnboardingSettledKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var onboardingSettled: Bool {
    get { self[OnboardingSettledKey.self] }
    set { self[OnboardingSettledKey.self] = newValue }
  }
}

enum OnboardingFont {
  static func weight(_ css: Int) -> Font.Weight {
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

  static func system(_ size: CGFloat, _ css: Int = 400) -> Font { .system(size: size, weight: weight(css)) }
}

struct OnboardingReveal: ViewModifier {
  @Environment(\.onboardingSettled) private var settled
  let delay: Double
  @State private var shown = false

  func body(content: Content) -> some View {
    let t = shown || settled ? 1.0 : 0.0
    content
      .opacity(t)
      .offset(y: 8 * (1 - t))
      .onAppear {
        guard !settled else { return }
        withAnimation(.rn(420, .outCubic, delay: delay)) { shown = true }
      }
  }
}

extension View {
  func reveal(_ delay: Double = 0) -> some View { modifier(OnboardingReveal(delay: delay)) }
}

struct OnboardingPressStyle: ButtonStyle {
  let content: (Bool) -> AnyView

  func makeBody(configuration: Configuration) -> some View {
    content(configuration.isPressed)
  }
}

struct OnboardingPressable<Label: View>: View {
  var disabled = false
  let action: () -> Void
  @ViewBuilder let label: (_ hovered: Bool, _ pressed: Bool) -> Label
  @State private var hovered = false

  var body: some View {
    Button(action: action) { EmptyView() }
      .buttonStyle(OnboardingPressStyle { pressed in AnyView(label(hovered, pressed)) })
      .disabled(disabled)
      .onKeyPress(.return) {
        guard !disabled else { return .ignored }
        action()
        return .handled
      }
      .onHover { hovered = $0 }
  }
}

struct OnboardingStepProgress: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    let steps = OnboardingStep.cards
    let index = steps.firstIndex(of: model.step) ?? 0
    let count = model.questions(for: model.step).count
    let sub = model.sub
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 4) {
        ForEach(Array(steps.enumerated()), id: \.offset) { i, _ in
          RoundedRectangle(cornerRadius: 1.5).fill(i <= index ? colors.progressFill : colors.progressTrack).frame(width: 22, height: 3)
        }
      }
      HStack(spacing: 10) {
        Text("STEP \(index + 1) OF \(steps.count)")
          .font(OnboardingFont.system(11, 500))
          .kerning(0.2)
          .foregroundStyle(colors.steps)
        if count > 1 {
          HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
              Circle()
                .fill(i <= sub ? colors.title : colors.progressTrack)
                .frame(width: 5, height: 5)
                .opacity(i == sub ? 1 : i < sub ? 0.45 : 1)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Question \(sub + 1) of \(count)")
        }
      }
      .frame(height: 14)
    }
  }
}

struct OnboardingStepTitle: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  let subtitle: String?

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(OnboardingFont.system(26, 300))
        .kerning(-0.4)
        .lineSpacing(31 - 26 * 1.19)
        .foregroundStyle(colors.title)
        .fixedSize(horizontal: false, vertical: true)
      if let subtitle {
        Text(subtitle)
          .font(OnboardingFont.system(13.5))
          .lineSpacing(19 - 13.5 * 1.19)
          .foregroundStyle(colors.subtitle)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct OnboardingPrimaryButton: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  var icon: String?
  var disabled = false
  let action: () -> Void

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    OnboardingPressable(disabled: disabled, action: action) { hovered, pressed in
      HStack(spacing: 6) {
        Text(title).font(OnboardingFont.system(13, 600)).foregroundStyle(colors.primaryText)
        if let icon {
          Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.primaryText).frame(width: 12, height: 12)
        }
      }
      .padding(.horizontal, 20)
      .frame(height: 36)
      .background(Capsule().fill(hovered && !disabled ? colors.primaryHover : colors.primary))
      .scaleEffect(pressed ? 0.98 : 1)
      .contentShape(Capsule())
    }
    .opacity(disabled ? 0.4 : 1)
    .accessibilityLabel(title)
  }
}

struct OnboardingSecondaryButton: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  var filled = false
  let action: () -> Void

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    OnboardingPressable(action: action) { hovered, pressed in
      Text(title)
        .font(OnboardingFont.system(13, 500))
        .foregroundStyle(filled ? colors.buttonText : colors.noThanksText)
        .padding(.horizontal, 18)
        .frame(height: 36)
        .background(Capsule().fill(filled ? (hovered ? colors.buttonHover : colors.button) : hovered ? colors.outlinedHover : .clear))
        .overlay { if !filled { CapsuleRing().fill(colors.noThanksBorder, style: FillStyle(eoFill: true)) } }
        .scaleEffect(pressed ? 0.98 : 1)
        .contentShape(Capsule())
    }
    .accessibilityLabel(title)
  }
}

struct OnboardingCircleButton: View {
  @Environment(\.colorScheme) private var scheme
  let symbol: String
  let size: CGFloat
  let box: CGFloat
  var weight: Font.Weight = .semibold
  let label: String
  let action: () -> Void

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    OnboardingPressable(action: action) { hovered, pressed in
      Image(systemName: symbol)
        .font(.system(size: size, weight: weight))
        .foregroundStyle(colors.noThanksText)
        .frame(width: box, height: box)
        .frame(width: 36, height: 36)
        .background(Circle().fill(hovered ? colors.outlinedHover : .clear))
        .overlay(Circle().strokeBorder(colors.noThanksBorder, lineWidth: 1))
        .scaleEffect(pressed ? 0.96 : 1)
        .contentShape(Circle())
    }
    .accessibilityLabel(label)
  }
}

struct OnboardingBackButton: View {
  let action: () -> Void

  var body: some View {
    OnboardingCircleButton(symbol: "chevron.left", size: 12, box: 14, label: "Back", action: action)
  }
}

struct OnboardingCheckMark: View {
  @Environment(\.colorScheme) private var scheme
  let on: Bool
  let size: CGFloat
  @State private var shown: Double

  init(on: Bool, size: CGFloat = 18) {
    self.on = on
    self.size = size
    _shown = State(initialValue: on ? 1 : 0)
  }

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    ZStack {
      Circle().fill(colors.checkbox)
      Circle().strokeBorder(colors.checkboxBorder, lineWidth: 1.5)
      ZStack {
        Circle().fill(colors.checkboxOn)
        Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(colors.checkmark)
      }
      .frame(width: size, height: size)
      .opacity(shown)
      .scaleEffect(0.6 + 0.4 * shown)
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .onChange(of: on) { _, value in
      withAnimation(.rn(140, .outQuad)) { shown = value ? 1 : 0 }
    }
  }
}

struct OnboardingRadio: View {
  @Environment(\.colorScheme) private var scheme
  let on: Bool

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    Circle()
      .fill(colors.checkbox)
      .overlay(Circle().strokeBorder(on ? colors.checkboxOn : colors.checkboxBorder, lineWidth: on ? 5 : 1.5))
      .frame(width: 16, height: 16)
  }
}

struct OnboardingTag: View {
  @Environment(\.colorScheme) private var scheme
  let title: String

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    Text(title)
      .font(OnboardingFont.system(11, 600))
      .foregroundStyle(colors.title)
      .padding(.horizontal, 8)
      .frame(height: 20)
      .background(Capsule().fill(colors.button))
  }
}

struct OnboardingSectionLabel: View {
  @Environment(\.colorScheme) private var scheme
  let title: String

  var body: some View {
    Text(title)
      .font(OnboardingFont.system(12, 500))
      .foregroundStyle(OnboardingColors.of(scheme).subtitle)
      .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
  }
}

struct OnboardingRowFrame<Content: View>: View {
  @Environment(\.colorScheme) private var scheme
  var hovered = false
  var disabled = false
  var compact = false
  @ViewBuilder let content: () -> Content

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    let radius: CGFloat = compact ? 10 : 12
    HStack(spacing: compact ? 10 : 12) { content() }
      .padding(.vertical, compact ? 6 : 9)
      .padding(.horizontal, 12)
      .frame(minHeight: compact ? 36 : nil)
      .background(RoundedRectangle(cornerRadius: radius).fill(hovered && !disabled ? colors.button : colors.row))
      .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(colors.rowBorder, lineWidth: 1))
  }
}

struct OnboardingCheckRow: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  var subtitle: String?
  let value: Bool
  var disabled = false
  var icon: String?
  var compact = false
  let onChange: (Bool) -> Void

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    OnboardingPressable(disabled: disabled, action: { onChange(!value) }) { hovered, _ in
      OnboardingRowFrame(hovered: hovered, disabled: disabled, compact: compact) {
        if let icon {
          Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundStyle(colors.title)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(colors.iconContainer))
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(OnboardingFont.system(compact ? 12.5 : 13, 500)).foregroundStyle(colors.title)
          if let subtitle {
            Text(subtitle).font(OnboardingFont.system(compact ? 11 : 12)).foregroundStyle(colors.rowSubtitle).lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        OnboardingCheckMark(on: value, size: compact ? 16 : 18)
      }
      .contentShape(Rectangle())
    }
    .opacity(disabled ? 0.5 : 1)
    .accessibilityLabel(title)
    .accessibilityAddTraits(value ? .isSelected : [])
  }
}

struct OnboardingChoiceRow: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  let subtitle: String
  let selected: Bool
  let onPress: () -> Void
  var onHover: ((Bool) -> Void)?

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    OnboardingPressable(action: onPress) { hovered, pressed in
      HStack(spacing: 12) {
        OnboardingRadio(on: selected)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(OnboardingFont.system(13, 500)).foregroundStyle(colors.title)
          Text(subtitle).font(OnboardingFont.system(12)).foregroundStyle(colors.rowSubtitle).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
      .frame(minHeight: 56)
      .background(RoundedRectangle(cornerRadius: 12).fill(selected || hovered ? colors.button : colors.row))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? colors.checkboxBorder : colors.rowBorder, lineWidth: 1))
      .scaleEffect(pressed ? 0.99 : 1)
      .contentShape(Rectangle())
    }
    .onHover { onHover?($0) }
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct OnboardingOption<T: Hashable>: Identifiable {
  let value: T
  let title: String
  var image: NSImage?
  var id: T { value }
}

struct OnboardingOptionRow<T: Hashable>: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  let value: T
  let options: [OnboardingOption<T>]
  let onChange: (T) -> Void

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    OnboardingRowFrame(compact: true) {
      Text(title).font(OnboardingFont.system(12.5, 500)).foregroundStyle(colors.title).frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 2) {
        ForEach(options) { option in
          OnboardingSegment(title: option.title, image: option.image, imageSlot: options.contains { $0.image != nil }, selected: option.value == value) { onChange(option.value) }
        }
      }
      .padding(2)
      .background(RoundedRectangle(cornerRadius: 8).fill(colors.button))
      .accessibilityLabel(title)
    }
  }
}

struct OnboardingSegment: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  let image: NSImage?
  let imageSlot: Bool
  let selected: Bool
  let action: () -> Void

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    let isImage = image != nil || imageSlot
    OnboardingPressable(action: action) { hovered, pressed in
      Group {
        if isImage {
          if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: 26, height: 26)
          } else {
            Color.clear.frame(width: 26, height: 26)
          }
        } else {
          Text(title).font(OnboardingFont.system(11.5, selected ? 600 : 500)).foregroundStyle(selected ? colors.title : colors.subtitle)
        }
      }
      .padding(.horizontal, isImage ? 2 : 8)
      .frame(minWidth: isImage ? 30 : 34, minHeight: isImage ? 30 : 22, maxHeight: isImage ? 30 : 22)
      .background(RoundedRectangle(cornerRadius: 6).fill(selected ? colors.card : hovered ? colors.outlinedHover : .clear))
      .overlay { if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(colors.rowBorder, lineWidth: 1) } }
      .scaleEffect(pressed ? 0.96 : 1)
      .contentShape(Rectangle())
    }
    .help(isImage ? title : "")
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct OnboardingTileFrame<Content: View>: View {
  @Environment(\.colorScheme) private var scheme
  let width: CGFloat
  let height: CGFloat
  var gap: CGFloat = 6
  let selected: Bool
  let hovered: Bool
  let pressed: Bool
  var checkSize: CGFloat = 14
  @ViewBuilder let content: () -> Content

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    VStack(spacing: gap) { content() }
      .frame(width: width, height: height)
      .background(RoundedRectangle(cornerRadius: 12).fill(selected || hovered ? colors.button : colors.row))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? colors.title : colors.rowBorder, lineWidth: selected ? 1.5 : 1))
      .overlay(alignment: .topTrailing) {
        if selected { OnboardingCheckMark(on: true, size: checkSize).padding(5) }
      }
      .scaleEffect(pressed ? 0.96 : 1)
      .contentShape(Rectangle())
  }
}

struct CapsuleRing: Shape {
  var width: CGFloat = 1

  func path(in rect: CGRect) -> Path {
    var path = Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)
    let inner = rect.insetBy(dx: width, dy: width)
    path.addPath(Path(roundedRect: inner, cornerRadius: min(inner.width, inner.height) / 2))
    return path
  }
}
