import AppKit
import SolaraModel
import SolaraOmnibox
import SwiftUI

struct OnboardingStepView: View {
  let model: OnboardingModel

  var body: some View {
    Group {
      switch model.step {
      case .source: SourceStepView(model: model)
      case .pins: PinsStepView(model: model)
      case .outro: OutroStepView(model: model)
      case .home:
        if model.sub == 0 { DefaultBrowserStepView(model: model) } else { QuestionStepView(model: model) }
      default: QuestionStepView(model: model)
      }
    }
    .task(id: model.step) { await model.enter(model.step) }
  }
}

struct QuestionStepView: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel
  @State private var mock = MockFocusModel()

  var body: some View {
    let question = model.question ?? .tabs
    OnboardingStepLayout(
      model: model,
      text: model.pageText(question),
      tag: model.step == .layout ? model.styleTag : nil,
      pageKey: question.rawValue
    ) {
      content(question)
    } actions: {
      OnboardingStepActions(model: model) { model.confirmCurrent() }
    } preview: {
      if question == .crash {
        OnboardingMockPanel(settings: model.mockSettings, accent: model.accent, focus: nil, overlay: Receipt(product: model.copy.product, on: model.share))
      } else {
        OnboardingMockPanel(settings: model.mockSettings, accent: model.accent, focus: mock.focus, overlay: nil as Receipt?)
      }
    }
    .onChange(of: question) { _, _ in mock.reset() }
    .onDisappear { mock.clear() }
  }

  @ViewBuilder
  func content(_ question: OnboardingQuestion) -> some View {
    switch question {
    case .tidy:
      OnboardingChoiceList(model: model, question: question, mock: mock)
      if let hours = model.value("cleanUpInactiveTabsAfterHours").number {
        OnboardingOptionRow(title: "Tidy after", value: hours, options: model.tidyOptions(hours).map { OnboardingOption(value: $0.hours, title: $0.title) }) {
          model.change(["cleanUpInactiveTabsAfterHours": .number($0)])
        }
      }
    case .tabsMore:
      VStack(spacing: 8) {
        OnboardingCheckRow(title: "Top Apps grow with the sidebar", subtitle: "Up to four across, as in Arc", value: model.bool("balancedTopApps")) { model.change(["balancedTopApps": .bool($0)]) }
        OnboardingOptionRow(title: "Peek a link with", value: model.string("peekModifier"), options: OnboardingModel.peekWith.map { OnboardingOption(value: $0.value, title: $0.title) }) {
          model.change(["peekModifier": .string($0)])
        }
        OnboardingCheckRow(title: "⌘Z reopens closed tabs", subtitle: "Outside text fields, as in Arc", value: model.bool("undoReopensClosedTab")) { model.change(["undoReopensClosedTab": .bool($0)]) }
        OnboardingCheckRow(title: "⌘-click on a link makes a tab group", subtitle: "Keeps related tabs together", value: model.bool("cmdClickCreatesTabGroup")) {
          model.change(["cmdClickCreatesTabGroup": .bool($0)])
        }
      }
    case .color:
      if model.colorPickerShown {
        ThemeColorPicker(current: model.currentColor, size: 32) { model.previewColor($0) }
      }
    case .lookMore:
      VStack(spacing: 8) {
        if model.icons.count > 1, let icon = model.appIconValue {
          OnboardingOptionRow(title: "App icon", value: icon, options: model.icons.map { OnboardingOption(value: $0.id, title: $0.name, image: $0.preview) }) { id in
            model.setExtras { $0.appIcon = id }
          }
        }
        OnboardingCheckRow(title: "Hide toolbar while scrolling", subtitle: "Scroll up to bring it back", value: model.bool("hideToolbarWhileScrolling")) {
          model.change(["hideToolbarWhileScrolling": .bool($0)])
        }
        OnboardingOptionRow(title: "Bookmarks bar", value: model.string("bookmarksBar"), options: OnboardingModel.bookmarksBarOptions.map { OnboardingOption(value: $0.value, title: $0.title) }) {
          model.change(["bookmarksBar": .string($0)])
        }
      }
    case .engine:
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(OnboardingMetrics.tile), spacing: 8), count: 4), alignment: .leading, spacing: 8) {
        ForEach(model.shownEngines, id: \.id) { engine in
          EngineTile(model: model, engine: engine, selected: engine.id == model.string("searchEngine")) { model.setDraft(["searchEngine": .string(engine.id)]) }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Search engine")
    case .crash:
      OnboardingCheckRow(title: model.copy.sharingToggle, subtitle: model.copy.sharingRow, value: model.share, icon: "stethoscope") { on in model.setExtras { $0.share = on } }
    default:
      OnboardingChoiceList(model: model, question: question, mock: mock)
    }
  }
}

struct EngineTile: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel
  let engine: SearchEngine
  let selected: Bool
  let action: () -> Void

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    OnboardingPressable(action: action) { hovered, pressed in
      OnboardingTileFrame(width: OnboardingMetrics.tile, height: 64, selected: selected, hovered: hovered, pressed: pressed, checkSize: 12) {
        OnboardingFavicon(model: model, url: "https://\(engineHost(engine))", size: 18)
        OnboardingText(engine.name, size: 11, weight: 500, color: selected ? colors.title : colors.subtitle, lines: 1)
      }
    }
    .accessibilityLabel(engine.name)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct Receipt: View {
  @Environment(\.colorScheme) private var scheme
  let product: String
  let on: Bool

  static let sent = ["Crash reports", "Error types", "Feature counts", "Speed and memory"]
  static let always = ["Daily open count"]
  static let never = ["Sites you visit", "What you type", "Your tabs", "Your name"]

  func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Menlo", size: size).weight(weight) }

  func line(_ label: String, _ mark: String, dim: Bool, _ colors: OnboardingColors) -> some View {
    HStack(spacing: 6) {
      Text(label).font(mono(11)).foregroundStyle(colors.title).fixedSize()
      Color.clear.frame(maxWidth: .infinity, maxHeight: 13).overlay(alignment: .leading) { Text(String(repeating: ".", count: 40)).font(mono(11)).foregroundStyle(colors.steps).fixedSize() }.clipped()
      Text(mark).font(mono(11)).foregroundStyle(colors.title).fixedSize()
    }
    .opacity(dim ? 0.35 : 1)
  }

  func rule(_ colors: OnboardingColors) -> some View {
    Line().stroke(colors.rowBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(height: 1).padding(.vertical, 10)
  }

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    let green = PreviewColor.color("#2F9E5B")
    VStack(spacing: 0) {
      Text(product.uppercased()).font(mono(11, .bold)).kerning(1).foregroundStyle(colors.title)
      Text("ITEMIZED. UNLIKE SOME EXPENSES.").font(mono(9.5)).kerning(0.6).foregroundStyle(colors.subtitle).padding(.top, 3)
      rule(colors)
      VStack(spacing: 6) {
        ForEach(Self.sent, id: \.self) { line($0, on ? "SENT" : "—", dim: !on, colors) }
        ForEach(Self.always, id: \.self) { line($0, "SENT", dim: false, colors) }
      }
      rule(colors)
      VStack(spacing: 6) { ForEach(Self.never, id: \.self) { line($0, "NEVER", dim: false, colors) } }
      rule(colors)
      HStack {
        Text("PERSONAL DATA").font(mono(11, .bold))
        Spacer()
        Text("0.00").font(mono(11, .bold))
      }
      .foregroundStyle(colors.title)
      Text(on ? "THANK YOU" : "NOT SHARED")
        .font(mono(10, .bold)).kerning(1)
        .foregroundStyle(on ? green : colors.steps)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? green : colors.steps, lineWidth: 1.5))
        .rotationEffect(.degrees(-6))
        .padding(.top, 14)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .frame(width: 250)
    .background(RoundedRectangle(cornerRadius: 4).fill(colors.card))
    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(colors.rowBorder, lineWidth: 1))
    .rotationEffect(.degrees(2))
  }
}

struct Line: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    return path
  }
}

struct SourceStepView: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel

  var body: some View {
    let tiles = model.sourceTiles
    let found = tiles.filter { $0.app != nil }
    let others = tiles.filter { $0.app == nil }
    OnboardingStepLayout(model: model, text: model.pageText(.source)) {
      VStack(alignment: .leading, spacing: 8) {
        OnboardingSectionLabel(title: "Browsers")
        grid(found + others, fresh: true)
      }
    } actions: {
      OnboardingStepActions(model: model, disabled: model.source == nil) { model.confirmCurrent() }
    } preview: {
      SourcePreview(model: model, tile: model.chosenTile, fresh: model.source == .fresh, found: found)
    }
  }

  func grid(_ tiles: [BrowserSourceTile], fresh: Bool) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(OnboardingMetrics.tile), spacing: 8), count: 4), alignment: .leading, spacing: 8) {
      ForEach(tiles) { tile in
        SourceTile(title: tile.name, icon: tile.icon, symbol: "globe", selected: model.source == tile.id) { model.chooseSource(tile.id) }
      }
      if fresh {
        SourceTile(title: "Starting fresh", icon: nil, symbol: "sparkles", selected: model.source == .fresh) { model.chooseSource(.fresh) }
      }
    }
  }
}

struct SourceTile: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  let icon: NSImage?
  let symbol: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    OnboardingPressable(action: action) { hovered, pressed in
      OnboardingTileFrame(width: OnboardingMetrics.tile, height: 84, selected: selected, hovered: hovered, pressed: pressed) {
        if let icon {
          Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
        } else {
          Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(colors.subtitle)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(colors.iconContainer))
            .padding(3)
        }
        OnboardingText(title, size: 11, weight: 500, color: selected ? colors.title : colors.subtitle, lines: 1).padding(.horizontal, 4)
      }
    }
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct SourcePreview: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel
  let tile: BrowserSourceTile?
  let fresh: Bool
  let found: [BrowserSourceTile]

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    let preset = OnboardingPreset.forSource(tile?.id ?? (fresh ? .fresh : nil))
    let from = tile.map { [$0] } ?? (fresh ? [] : Array(found.filter { $0.icon != nil }.prefix(6)))
    let big = tile != nil
    VStack(spacing: 22) {
      if !from.isEmpty {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: big ? 96 : 72, maximum: big ? 96 : 72), spacing: 14)], spacing: 14) {
          ForEach(from) { t in
            VStack(spacing: 6) {
              if let icon = t.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: big ? 88 : 56, height: big ? 88 : 56)
              } else {
                Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(colors.subtitle)
                  .frame(width: 72, height: 72)
                  .background(RoundedRectangle(cornerRadius: 18).fill(colors.iconContainer))
              }
              OnboardingText(t.name, size: 11, color: colors.subtitle)
            }
          }
        }
        .frame(maxWidth: from.count == 1 ? 96 : 300)
        Image(systemName: "arrow.down").font(.system(size: 18, weight: .medium)).foregroundStyle(colors.steps).frame(width: 24, height: 24)
      }
      OnboardingAppIconImage(model: model, size: tile != nil || fresh ? 96 : 72)
      if tile != nil || fresh { OnboardingTag(title: preset == .arc ? "Starts out Arc-style" : "Starts out Dia-style") }
      if model.canImport, let chosen = model.chosenTile {
        SourceImportOffer(model: model, chosen: chosen)
      }
    }
  }
}

struct SourceImportOffer: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel
  let chosen: BrowserSourceTile

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    let importing = model.importing == chosen.id
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        OnboardingText(importing ? "Importing from \(chosen.name)" : "Bring your stuff from \(chosen.name)", size: 13, weight: 500, color: colors.title)
        OnboardingText(importing ? "It runs in its own window. Carry on here." : "Bookmarks, history, passwords and tabs.", size: 12, color: colors.rowSubtitle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if importing {
        OnboardingCheckMark(on: true, size: 18)
      } else {
        OnboardingSecondaryButton(title: "Import…", filled: true) { model.startImport() }
      }
    }
    .padding(12)
    .frame(width: 300)
    .background(RoundedRectangle(cornerRadius: 12).fill(colors.row))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.rowBorder, lineWidth: 1))
  }
}

struct PinsStepView: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel

  var body: some View {
    let selected = model.selectedPins
    OnboardingStepLayout(model: model, text: model.pageText(.pins)) {
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(80), spacing: 8), count: 4), alignment: .leading, spacing: 8) {
        ForEach(PinnableSite.all) { site in
          SiteTile(model: model, site: site, selected: selected.contains(site.id)) { model.togglePin(site.id) }
        }
      }
    } actions: {
      OnboardingStepActions(model: model, continueTitle: model.pinsContinueTitle) { model.confirmCurrent() }
    } preview: {
      PinnedPreview(model: model, selected: selected)
    }
  }
}

struct SiteTile: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel
  let site: PinnableSite
  let selected: Bool
  let action: () -> Void

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    OnboardingPressable(action: action) { hovered, pressed in
      OnboardingTileFrame(width: 80, height: 70, gap: 7, selected: selected, hovered: hovered, pressed: pressed) {
        OnboardingFavicon(model: model, url: site.url, size: 22).opacity(selected || hovered ? 1 : 0.7)
        OnboardingText(site.title, size: 11, weight: 500, color: selected ? colors.title : colors.subtitle)
      }
    }
    .onboardingCheckbox(site.title, on: selected, disabled: false, toggle: action)
  }
}

struct PinnedPreview: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel
  let selected: [String]

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    let sites = PinnableSite.all.filter { selected.contains($0.id) }
    let slots = max(6, Int((Double(sites.count) / 3).rounded(.up)) * 3)
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        ForEach(Kit.lightColors, id: \.self) { Circle().fill(PreviewColor.color($0)).frame(width: 9, height: 9) }
      }
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 6), count: 3), alignment: .leading, spacing: 6) {
        ForEach(0..<slots, id: \.self) { i in
          let site = i < sites.count ? sites[i] : nil
          ZStack {
            if let site {
              RoundedRectangle(cornerRadius: 9).fill(colors.button)
              OnboardingFavicon(model: model, url: site.url, size: 18)
            } else {
              RoundedRectangle(cornerRadius: 9).strokeBorder(colors.rowBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
          }
          .frame(width: 64, height: 40)
        }
      }
      Rectangle().fill(colors.separator).frame(height: 1)
      ForEach(Array([0.7, 0.5, 0.6].enumerated()), id: \.offset) { _, w in
        HStack(spacing: 8) {
          RoundedRectangle(cornerRadius: 3).fill(colors.progressTrack).frame(width: 12, height: 12)
          RoundedRectangle(cornerRadius: 3).fill(colors.progressTrack).frame(width: (236 - 28) * w, height: 6)
        }
        .frame(height: 22)
      }
    }
    .padding(14)
    .frame(width: 236, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14).fill(colors.row))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(colors.rowBorder, lineWidth: 1))
  }
}

struct DefaultBrowserStepView: View {
  let model: OnboardingModel

  var body: some View {
    let system = model.system
    let copy = model.copy
    let defaultOn = (system?.isDefault ?? false) || model.setDefaultChoice
    let trying = !defaultOn && model.trialChoice
    OnboardingStepLayout(model: model, text: model.pageText(.defaultBrowser), pageKey: "default") {
      VStack(spacing: 8) {
        OnboardingCheckRow(
          title: copy.setDefault, subtitle: system?.isDefault == true ? copy.alreadyDefault : copy.openByDefault, value: defaultOn,
          disabled: system == nil || system?.isDefault == true, icon: "globe"
        ) { on in model.setExtras { $0.setDefault = on } }
        if let system, !defaultOn {
          OnboardingCheckRow(title: "Try it for seven days", subtitle: "We'll check in to make sure you love it.", value: model.trialChoice, icon: "calendar") { on in model.setExtras { $0.trial = on } }
          if !system.inDock { dockRow }
        } else if let system, !system.inDock {
          dockRow
        }
        OnboardingCheckRow(title: copy.login, subtitle: "Ready when you sign in", value: model.loginChoice, icon: "power") { on in model.setExtras { $0.login = on } }
      }
    } actions: {
      OnboardingStepActions(model: model, continueTitle: model.busy ? "Setting Up…" : "Continue", disabled: system == nil || model.busy) { model.confirmCurrent() }
    } preview: {
      SystemPreview(model: model, isDefault: defaultOn || trying, dock: (system?.inDock ?? false) || model.dockChoice, login: model.loginChoice)
    }
    .task { await model.loadSystem() }
  }

  var dockRow: some View {
    OnboardingCheckRow(title: model.copy.dock, subtitle: "Quick access whenever you need it", value: model.dockChoice, icon: "dock.rectangle") { on in model.setExtras { $0.dock = on } }
  }
}

struct SystemPreview: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel
  let isDefault: Bool
  let dock: Bool
  let login: Bool

  func chip(_ on: Bool, _ icon: String, _ label: String, _ colors: OnboardingColors) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon).font(.system(size: 13)).foregroundStyle(colors.title).frame(width: 16, height: 16)
      OnboardingText(label, size: 12, weight: 500, color: colors.title)
      OnboardingCheckMark(on: on, size: 16)
    }
    .padding(.leading, 12)
    .padding(.trailing, 10)
    .frame(height: 34)
    .background(Capsule().fill(colors.row))
    .overlay(CapsuleRing().fill(colors.rowBorder, style: FillStyle(eoFill: true)))
    .opacity(on ? 1 : 0.45)
  }

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    VStack(spacing: 28) {
      OnboardingAppIconImage(model: model, size: 132)
      VStack(spacing: 8) {
        chip(isDefault, "globe", "Default browser", colors)
        chip(dock, "dock.rectangle", "In your Dock", colors)
        chip(login, "power", "Opens at login", colors)
      }
    }
  }
}

struct OutroStepView: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    OnboardingStepLayout(model: model, text: model.pageText(.outro)) {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(OnboardingModel.shortcuts, id: \.keys) { shortcut in
          HStack(spacing: 12) {
            OnboardingText(shortcut.keys, size: 12, weight: 500, color: colors.title)
              .padding(.horizontal, 7)
              .frame(minWidth: 38, minHeight: 24, maxHeight: 24)
              .background(RoundedRectangle(cornerRadius: 6).fill(colors.button))
            OnboardingText(shortcut.label, size: 13, color: colors.subtitle)
          }
        }
      }
    } actions: {
      OnboardingStepActions(model: model, continueTitle: "Get Started", icon: "arrow.right", skip: false) { model.finish() }
      OnboardingSecondaryButton(title: "Take the Tour") { model.finish(tour: true) }
    } preview: {
      Postcard(model: model, lines: model.pickedLines)
    }
  }
}

struct Postcard: View {
  @Environment(\.colorScheme) private var scheme
  let model: OnboardingModel
  let lines: [String]

  var body: some View {
    let colors = OnboardingColors.of(scheme)
    let shown = Array(lines.prefix(8))
    HStack(alignment: .top, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        OnboardingText("Hello!", size: 20, weight: 300, color: colors.title, italic: true)
        if shown.isEmpty {
          OnboardingText("Glad you're here. Make yourself at home. Your tabs, bookmarks and pins are ready.", size: 12, color: colors.subtitle, lineHeight: 17)
        } else {
          VStack(alignment: .leading, spacing: 4) {
            OnboardingText("You picked:", size: 11, color: colors.subtitle, lineHeight: 15)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
              HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(colors.title).frame(width: 10, height: 15)
                OnboardingText(line, size: 11, color: colors.title, lineHeight: 15).frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
      }
      .padding(.trailing, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      Rectangle().fill(colors.separator).frame(width: 1)
      VStack(alignment: .trailing) {
        OnboardingAppIconImage(model: model, size: 46)
          .padding(4)
          .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(colors.rowBorder, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        Spacer(minLength: 0)
        VStack(spacing: 12) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(colors.separator).frame(height: 1) } }
      }
      .padding(.leading, 14)
      .frame(width: 96)
    }
    .padding(18)
    .frame(width: 340)
    .frame(minHeight: 210)
    .fixedSize(horizontal: false, vertical: true)
    .overlay(alignment: .topTrailing) {
      Text("WELCOME").font(OnboardingFont.system(6, 700)).kerning(0.4).foregroundStyle(colors.steps).lineLimit(1)
        .frame(width: 44, height: 44)
        .overlay(Circle().strokeBorder(colors.steps, lineWidth: 1))
        .rotationEffect(.degrees(-12))
        .padding(.top, 52)
        .padding(.trailing, 50)
    }
    .background(RoundedRectangle(cornerRadius: 6).fill(colors.card))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(colors.rowBorder, lineWidth: 1))
    .rotationEffect(.degrees(-3))
  }
}
