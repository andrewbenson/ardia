import AppKit
import SwiftUI

public struct SettingsWindowView: View {
  static let sidebarWidth: CGFloat = 214
  static let toolbarHeight: CGFloat = 52
  static let revealMargin: CGFloat = 16

  @Environment(\.colorScheme) private var scheme
  let context: SettingsContext

  public init(context: SettingsContext) {
    self.context = context
  }

  public var body: some View {
    let theme = SettingsTheme(scheme)
    HStack(spacing: 0) {
      SettingsSidebar(context: context)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsVisualEffect())
      Rectangle().fill(theme.sidebarDivider).frame(width: 1)
      SettingsDetail(context: context)
    }
    .background(theme.window)
    .ignoresSafeArea()
    .environment(\.settingsContext, context)
    .onAppear { context.syncShown() }
    .onChange(of: context.navigation.place) { _, place in
      context.syncShown()
    }
    .onChange(of: context.navigation.pane, initial: true) { _, pane in
      context.onPaneChange(pane)
    }
  }
}

struct SettingsSidebar: View {
  @Bindable var search: SettingsSearchModel
  let context: SettingsContext

  init(context: SettingsContext) {
    self.context = context
    search = context.search
  }

  var body: some View {
    VStack(spacing: 0) {
      WindowDragArea(draggable: true).frame(height: SettingsWindowView.toolbarHeight)
      SettingsSearchBox(
        text: $search.query,
        focusRequest: search.focusRequest,
        onSubmit: { context.submitSearch() },
        onArrow: { search.moveSelection($0) }
      )
      .padding(.horizontal, 10)
      .padding(.bottom, 10)
      if search.isSearching {
        SettingsSearchResults(context: context)
      } else {
        SettingsPaneList(context: context)
      }
    }
  }
}

struct SettingsSearchBox: View {
  @Environment(\.colorScheme) private var scheme
  @Binding var text: String
  let focusRequest: Int
  let onSubmit: () -> Void
  let onArrow: (Int) -> Void
  var placeholder = "Search"

  var body: some View {
    let theme = SettingsTheme(scheme)
    HStack(spacing: 5) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundStyle(theme.textSecondary)
        .frame(width: 14, height: 14)
      SettingsSearchField(text: $text, focusRequest: focusRequest, onSubmit: onSubmit, onArrow: onArrow, placeholder: placeholder)
      if !text.isEmpty {
        Button { text = "" } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(theme.textTertiary)
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help("Clear")
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 28)
    .contentShape(Rectangle())
    .background(RoundedRectangle(cornerRadius: 8).fill(theme.field))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.fieldBorder, lineWidth: 1))
  }
}

struct SettingsPaneList: View {
  static let rowHeight: CGFloat = 30
  static let rowGap: CGFloat = 1

  @Environment(\.colorScheme) private var scheme
  @FocusState private var focused: Bool
  let context: SettingsContext

  var body: some View {
    let selected = context.navigation.pane
    ScrollView(.vertical) {
      LazyVStack(spacing: Self.rowGap) {
        ForEach(SettingsPane.allCases) { pane in
          SettingsPaneRow(pane: pane, selected: pane == selected, scheme: scheme)
            .onTapGesture { context.goToPane(pane) }
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 12)
    }
    .scrollIndicators(.automatic)
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(.downArrow) { step(1) }
    .onKeyPress(.upArrow) { step(-1) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Settings")
  }

  private func step(_ offset: Int) -> SwiftUI.KeyPress.Result {
    let panes = SettingsPane.allCases
    guard let index = panes.firstIndex(of: context.navigation.pane) else { return .ignored }
    let next = min(max(index + offset, 0), panes.count - 1)
    if next != index { context.goToPane(panes[next]) }
    return .handled
  }
}

struct SettingsPaneRow: View {
  let pane: SettingsPane
  let selected: Bool
  let scheme: ColorScheme
  @State private var hovered = false

  var body: some View {
    let theme = SettingsTheme(scheme)
    HStack(spacing: 9) {
      Image(systemName: pane.symbol)
        .font(.system(size: 13))
        .foregroundStyle(selected ? Color.white : theme.icon)
        .frame(width: 20, height: 20)
      OnboardingText(pane.title, size: 13, color: selected ? .white : theme.textPrimary, lines: 1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(height: SettingsPaneList.rowHeight)
    .background {
      if selected || hovered {
        RoundedRectangle(cornerRadius: 7).fill(selected ? theme.accent : theme.selected)
      }
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(pane.title)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }
}

struct SettingsSearchResults: View {
  @Environment(\.colorScheme) private var scheme
  let context: SettingsContext

  var body: some View {
    let theme = SettingsTheme(scheme)
    let search = context.search
    let results = search.results
    if results.isEmpty {
      VStack(spacing: 4) {
        OnboardingText("No Results", size: 13, weight: 600, color: theme.textSecondary)
        OnboardingText("Nothing matches “\(search.query.trimmingCharacters(in: .whitespaces))”.", size: 12, color: theme.textTertiary, alignment: .center)
      }
      .padding(.top, 40)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    } else {
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groups(results), id: \.pane) { group in
              HStack(spacing: 6) {
                Image(systemName: group.pane.symbol).font(.system(size: 11)).foregroundStyle(theme.textTertiary).frame(width: 16, height: 16)
                OnboardingText(group.pane.title, size: 11, weight: 600, color: theme.textTertiary, lines: 1)
              }
              .padding(.horizontal, 8)
              .frame(height: 26)
              .padding(.top, 4)
              ForEach(group.rows, id: \.offset) { row in
                ResultRow(entry: row.entry, selected: row.offset == search.selected, theme: theme)
                  .id(row.offset)
                  .contentShape(Rectangle())
                  .onTapGesture { context.reveal(row.entry.id) }
                  .onHover { if $0 { search.selected = row.offset } }
              }
            }
          }
          .padding(.horizontal, 10)
          .padding(.bottom, 12)
        }
        .onChange(of: search.selected) { _, selected in
          proxy.scrollTo(selected)
        }
      }
    }
  }

  private func groups(_ results: [SettingEntry]) -> [(pane: SettingsPane, rows: [(offset: Int, entry: SettingEntry)])] {
    var out: [(pane: SettingsPane, rows: [(offset: Int, entry: SettingEntry)])] = []
    for (offset, entry) in results.enumerated() {
      if out.last?.pane == entry.pane {
        out[out.count - 1].rows.append((offset, entry))
      } else {
        out.append((entry.pane, [(offset, entry)]))
      }
    }
    return out
  }
}

struct ResultRow: View {
  let entry: SettingEntry
  let selected: Bool
  let theme: SettingsTheme

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      OnboardingText(entry.title, size: 13, color: selected ? .white : theme.textPrimary, lines: 1)
      OnboardingText(entry.section != entry.title ? entry.section : entry.paneTitle, size: 11, color: selected ? Color.white.opacity(0.8) : theme.textSecondary, lines: 1)
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
    .background(selected ? RoundedRectangle(cornerRadius: 7).fill(theme.accent) : nil)
    .accessibilityElement(children: .combine)
  }
}

struct SettingsDetail: View {
  let context: SettingsContext
  @State private var lastKey: SettingsPlace?

  var body: some View {
    VStack(spacing: 0) {
      SettingsDetailHeader(context: context)
      content
    }
  }

  private var content: some View {
    ScrollViewReader { proxy in
      Group {
        if let shown = context.shown {
          paneView(shown)
            .onAppear { context.onPaneAppear(shown) }
            .id(shown)
        } else {
          Color.clear
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { context.viewport = $0 }
      .onChange(of: RevealKey(reveal: context.search.reveal, shown: context.shown), initial: true) { _, key in
        reveal(key, proxy: proxy)
      }
      .onChange(of: context.shown) { _, shown in
        DispatchQueue.main.async { lastKey = shown }
      }
    }
  }

  @ViewBuilder
  private func paneView(_ place: SettingsPlace) -> some View {
    if let provider = context.panes[place.pane] {
      provider.view(place)
    } else {
      Text(place.pane.title)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private struct RevealKey: Equatable {
    let reveal: String?
    let shown: SettingsPlace?
  }

  private func reveal(_ key: RevealKey, proxy: ScrollViewProxy) {
    guard let id = key.reveal, let entry = context.index.entry(id) else { return }
    if context.navigation.pane != entry.pane {
      context.search.clearReveal()
      return
    }
    guard key.shown?.pane == entry.pane else { return }
    let animated = lastKey == key.shown
    DispatchQueue.main.async {
      let frame = context.anchorFrames[id] ?? .null
      let viewport = context.viewport
      let margin = SettingsWindowView.revealMargin
      let inView = animated && !frame.isNull && frame.minY >= viewport.minY + margin && frame.maxY <= viewport.maxY - margin
      if !inView {
        let target = UnitPoint(x: 0.5, y: 1.0 / 3.0)
        if animated {
          withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: target) }
        } else {
          proxy.scrollTo(id, anchor: target)
        }
      }
      context.search.flashSetting(id)
    }
  }
}

struct SettingsDetailHeader: View {
  @Environment(\.colorScheme) private var scheme
  let context: SettingsContext

  var body: some View {
    let theme = SettingsTheme(scheme)
    let navigation = context.navigation
    ZStack(alignment: .leading) {
      WindowDragArea(draggable: true)
      HStack(spacing: 2) {
        SettingsIconButton(symbol: "chevron.left", help: "Back", disabled: !navigation.canGoBack) { navigation.goBack() }
        SettingsIconButton(symbol: "chevron.right", help: "Forward", disabled: !navigation.canGoForward) { navigation.goForward() }
        OnboardingText(context.shown.map(context.title(for:)) ?? "", size: 15, weight: 600, color: theme.textPrimary, lines: 1)
          .padding(.leading, 8)
          .allowsHitTesting(false)
      }
      .padding(.horizontal, 12)
    }
    .frame(height: SettingsWindowView.toolbarHeight)
  }
}

struct SettingsIconButton: View {
  @Environment(\.colorScheme) private var scheme
  let symbol: String
  let help: String
  var disabled = false
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    let theme = SettingsTheme(scheme)
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13))
        .foregroundStyle(disabled ? theme.iconDisabled : theme.icon)
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(!disabled && hovered ? theme.toolbarHover : .clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(SettingsIconPressStyle(disabled: disabled, theme: theme))
    .disabled(disabled)
    .onHover { hovered = $0 }
    .help(help)
    .accessibilityLabel(help)
  }
}

struct SettingsIconPressStyle: ButtonStyle {
  let disabled: Bool
  let theme: SettingsTheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed && !disabled ? theme.toolbarPressed : .clear))
  }
}

