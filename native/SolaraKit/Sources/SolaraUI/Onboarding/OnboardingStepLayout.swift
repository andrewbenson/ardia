import AppKit
import Observation
import SolaraModel
import SwiftUI

enum OnboardingMetrics {
  static let contentWidth: CGFloat = 368
  static let columnWidth: CGFloat = contentWidth + 56
  static let columnPadding: CGFloat = 28
  static let tile: CGFloat = (contentWidth - 8 * 3) / 4
  static let mockSize = CGSize(width: 420, height: 300)
  static let replayGap = 280
  static let replayLength = 1700
}

@MainActor
@Observable
final class MockFocusModel {
  var hovered: PreviewId?
  var replaying: (id: PreviewId, playing: Bool)?
  @ObservationIgnored private var timers: [Task<Void, Never>] = []

  var focus: PreviewId? {
    if let replaying { return replaying.playing ? replaying.id : nil }
    return hovered
  }

  func reset() {
    clear()
    hovered = nil
    replaying = nil
  }

  func clear() {
    timers.forEach { $0.cancel() }
    timers = []
  }

  func hover(_ id: PreviewId, _ on: Bool) {
    if on {
      hovered = id
    } else if hovered == id {
      hovered = nil
    }
  }

  func replay(_ id: PreviewId) {
    clear()
    replaying = (id, false)
    timers = [
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(OnboardingMetrics.replayGap))
        guard !Task.isCancelled else { return }
        self?.replaying = (id, true)
      },
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(OnboardingMetrics.replayGap + OnboardingMetrics.replayLength))
        guard !Task.isCancelled else { return }
        self?.replaying = nil
      },
    ]
  }
}

struct OnboardingChoiceList: View {
  let model: OnboardingModel
  let question: OnboardingQuestion
  let mock: MockFocusModel

  var body: some View {
    let value = model.choiceValue(question)
    VStack(spacing: 8) {
      ForEach(model.choices(question)) { choice in
        OnboardingChoiceRow(
          title: choice.title, subtitle: choice.subtitle, selected: choice.value == value,
          onPress: {
            if choice.value != value { model.choose(question, choice.value) }
            mock.replay(choice.preview)
          },
          onHover: { mock.hover(choice.preview, $0) }
        )
      }
    }
    .accessibilityElement(children: .contain)
  }
}

struct OnboardingMockPanel<Overlay: View>: View {
  @Environment(\.onboardingSettled) private var settled
  let settings: MockSettings
  let accent: String
  let focus: PreviewId?
  let overlay: Overlay?
  @State private var shown: Double

  init(settings: MockSettings, accent: String, focus: PreviewId?, overlay: Overlay?) {
    self.settings = settings
    self.accent = accent
    self.focus = focus
    self.overlay = overlay
    _shown = State(initialValue: overlay == nil ? 0 : 1)
  }

  var body: some View {
    let hasOverlay = overlay != nil
    ZStack {
      MockWindow(settings: settings, accent: accent, focus: focus)
        .frame(width: OnboardingMetrics.mockSize.width, height: OnboardingMetrics.mockSize.height)
        .opacity(1 - shown)
      if let overlay {
        overlay
          .opacity(shown)
          .scaleEffect(0.97 + 0.03 * shown)
          .allowsHitTesting(false)
      }
    }
    .onChange(of: hasOverlay) { _, on in
      withAnimation(settled ? nil : .rn(220, .outCubic)) { shown = on ? 1 : 0 }
    }
  }
}

extension OnboardingMockPanel where Overlay == EmptyView {
  init(settings: MockSettings, accent: String, focus: PreviewId?) {
    self.init(settings: settings, accent: accent, focus: focus, overlay: nil)
  }
}

struct OnboardingStepLayout<Content: View, Actions: View, Preview: View>: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel
  let text: OnboardingPageText
  var tag: String?
  var pageKey: String = ""
  @ViewBuilder let content: () -> Content
  @ViewBuilder let actions: () -> Actions
  @ViewBuilder let preview: () -> Preview

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        OnboardingStepProgress(model: model).reveal()
        Color.clear
          .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
              VStack(alignment: .leading, spacing: 10) {
                OnboardingStepTitle(title: text.title, subtitle: text.subtitle)
                if let tag { OnboardingTag(title: tag) }
              }
              .reveal(60)
              VStack(alignment: .leading, spacing: 16) { content() }
                .padding(.top, 22)
                .reveal(140)
            }
            .frame(width: OnboardingMetrics.contentWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .id(pageKey)
          }
          .clipped()
          .padding(.top, 20)
        HStack(spacing: 10) { actions() }
          .padding(.top, 14)
          .reveal(240)
      }
      .padding(.top, 34)
      .padding(.bottom, 28)
      .padding(.horizontal, OnboardingMetrics.columnPadding)
      .frame(width: OnboardingMetrics.columnWidth)
      .frame(maxHeight: .infinity)
      ZStack {
        RoundedRectangle(cornerRadius: 14).fill(colors.preview)
        RoundedRectangle(cornerRadius: 14).strokeBorder(colors.previewBorder, lineWidth: 1)
        preview().reveal(120)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .accessibilityHidden(true)
      .padding(.vertical, 12)
      .padding(.trailing, 12)
    }
  }
}

struct OnboardingStepActions: View {
  let model: OnboardingModel
  var continueTitle = "Continue"
  var disabled = false
  var icon: String?
  var skip = true
  let onContinue: () -> Void

  var body: some View {
    if !model.isFirstPage { OnboardingBackButton { model.back() } }
    OnboardingPrimaryButton(title: continueTitle, icon: icon, disabled: disabled, action: onContinue)
    if skip { OnboardingSecondaryButton(title: "Skip") { model.skip() } }
  }
}

struct OnboardingFavicon: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel
  let url: String
  var size: CGFloat = 16
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().interpolation(.high).clipShape(RoundedRectangle(cornerRadius: size > 18 ? 4 : 3))
      } else if let initial = SettingsFavicon.hostInitial(url) {
        let tile = (size * 14 / 16).rounded()
        RoundedRectangle(cornerRadius: tile * 0.32, style: .continuous)
          .fill(scheme == .dark ? Color(red: 247 / 255, green: 245 / 255, blue: 1).opacity(0.2) : Color.black.opacity(0.13))
          .frame(width: tile, height: tile)
          .overlay {
            Text(initial)
              .font(.system(size: (tile * 0.64).rounded(), weight: .semibold))
              .foregroundStyle(PreviewColor.color(scheme == .dark ? PreviewTheme.darkBase.textSecondary : PreviewTheme.lightBase.textSecondary))
          }
      } else {
        Image(systemName: "globe").font(.system(size: size - 3)).foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .task(id: url) { image = await model.services.favicon(url) }
  }
}

struct OnboardingAppIconImage: View {
  let model: OnboardingModel
  let size: CGFloat

  var body: some View {
    Group {
      if let icon = model.appIcon {
        Image(nsImage: icon).resizable().interpolation(.high)
      } else {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
          .fill(LinearGradient(colors: [PreviewColor.color("#FDD023"), PreviewColor.color("#FA3D1D")], startPoint: .top, endPoint: .bottom))
          .padding(size * 0.1)
      }
    }
    .frame(width: size, height: size)
  }
}
