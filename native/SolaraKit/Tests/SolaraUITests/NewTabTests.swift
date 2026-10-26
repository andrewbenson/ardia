import AppKit
import Foundation
import SolaraModel
import SolaraOmnibox
import Testing
@testable import SolaraUI

struct NewTabSpringTests {
  func run(_ params: SpringParams, from: Double) -> [Double] {
    var spring = RNSpring(params, from: from)
    var out: [Double] = []
    for frame in 0..<200 {
      out.append(spring.step(at: Double(frame) / 60))
      if spring.finished { break }
    }
    return out
  }

  @Test func layersMatchReactNativeFrameByFrame() {
    let expected: [(MarkLayer.Name, Int, [Double])] = [
      (.sun, 76, [55.124572, 49.690077, 37.797695, 22.773031, 10.236090, 3.870401, 0.200112]),
      (.back, 72, [39.576350, 34.064338, 22.923709, 10.717320, 2.779946, 0.158876, -0.218480]),
      (.front, 59, [33.069633, 27.547189, 16.682420, 5.715699, 0.010376, -0.853689, -0.116423]),
    ]
    for (name, frames, values) in expected {
      let layer = MarkIntro.layers.first { $0.name == name }!
      let out = run(layer.spring, from: layer.hidden)
      #expect(out.count == frames, "\(name) settles after \(out.count) frames")
      #expect(out.first == layer.hidden)
      #expect(out.last == 0)
      for (i, frame) in [1, 3, 6, 10, 15, 20, 30].enumerated() {
        #expect(abs(out[frame] - values[i]) < 1e-4, "\(name) frame \(frame): \(out[frame]) vs \(values[i])")
      }
    }
    let drift = run(MarkIntro.sunDriftSpring, from: MarkIntro.sunDrift)
    #expect(drift.count == 80)
    #expect(abs(drift[10] - 2.875801) < 1e-4)
  }

  @Test func aDroppedFrameAdvancesAtMost64Milliseconds() {
    var a = RNSpring(MarkIntro.layers[0].spring, from: 56)
    _ = a.step(at: 0)
    let late = a.step(at: 0.5)
    var b = RNSpring(MarkIntro.layers[0].spring, from: 56)
    _ = b.step(at: 0)
    #expect(late == b.step(at: 0.064))
  }

  @Test func eachLayerWaitsForItsDelay() {
    var player = MarkIntroPlayer()
    player.start(at: 10)
    var offsets = player.step(at: 10)
    #expect(offsets.y[.sun] == 56 && offsets.y[.back] == 40.5 && offsets.y[.front] == 34 && offsets.sunX == 6)
    offsets = player.step(at: 10.1)
    #expect(offsets.y[.front] == 34)
    offsets = player.step(at: 10.12)
    #expect(offsets.y[.front]! < 34)
    #expect(offsets.y[.back] == 40.5)
    var t = 10.12
    while !player.finished && t < 13 {
      t += 1.0 / 60
      offsets = player.step(at: t)
    }
    #expect(player.finished)
    #expect(offsets == .rest)
  }
}

struct NewTabLayoutTests {
  @Test func barMatchesTheReactLayout() {
    #expect(NewTabLayout.barWidth(600) == 572)
    #expect(NewTabLayout.barWidth(700) == 616)
    #expect(NewTabLayout.barWidth(1200) == 652)
    #expect(NewTabLayout.barWidth(1800) == 774)
    #expect(NewTabLayout.barTop(height: 900, under: 0) == 331, "\(NewTabLayout.barTop(height: 900, under: 0))")
    #expect(NewTabLayout.barTop(height: 900, under: 0, headingHeight: 80) == NewTabLayout.barTop(height: 900, under: 0))
    let small = NewTabLayout.barTop(height: 400, under: 0, headingHeight: 80)
    #expect(NewTabLayout.headingTop(barTop: small, headingHeight: 80) >= 16)
  }

  @Test func theMarkSitsOnWholePixelsAboveTheBar() {
    let f = NewTabLayout.frames(size: CGSize(width: 1201, height: 800), under: 0, headingHeight: 0, barHeight: 111, scale: 2)
    #expect(f.bar.minY == 281)
    #expect(f.mark.minY == 197)
    #expect(f.mark.height == 84)
    #expect(f.mark.minX == 551.5)
    #expect(f.bar.minX == 275.5)
  }
}

struct NewTabInlineTests {
  func sup(_ typed: String, _ shown: String, _ next: String) -> Bool {
    InlineRules.preventsInline(typed: typed, shown: shown, next: next, edit: nil)
  }

  func sel(_ start: Int, _ end: Int? = nil) -> TextSelection { TextSelection(start: start, end: end ?? start) }

  func edit(_ typed: String, _ shown: String, _ next: String, _ before: TextSelection, _ after: TextSelection) -> Bool {
    InlineRules.preventsInline(typed: typed, shown: shown, next: next, edit: EditContext(before: before, after: after))
  }

  @Test func deletionDropsTheCompletionTypingBringsItBack() {
    #expect(sup("gi", "thub.com", "gi"))
    #expect(sup("gi", "", "g"))
    #expect(sup("github", "", ""))
    #expect(sup("github", "", "gihub"))
    #expect(sup("github", "", "hub"))
    #expect(sup("gi", "thub.com", "thub.com"))
    #expect(!sup("gi", "thub.com", "git"))
    #expect(!sup("gi", "thub.com", "gix"))
    #expect(!sup("gi", "", "git"))
    #expect(!sup("", "", "g"))
    #expect(!sup("github", "", "gx"))
    #expect(!sup("github", "", "xthub"))
  }

  @Test func aReplacedSelectionIsTypingARemovalIsADeletion() {
    #expect(!edit("gi", "", "g", sel(0, 2), sel(1)))
    #expect(!edit("gi", "thub.com", "g", sel(0, 10), sel(1)))
    #expect(edit("gi", "", "g", sel(2), sel(1)))
    #expect(edit("gi", "thub.com", "gi", sel(2, 10), sel(2)))
    #expect(edit("github", "", "gihub", sel(2), sel(2)))
    #expect(edit("github", "", "gihub", sel(3), sel(2)))
    #expect(edit("github", "", "ghub", sel(1, 3), sel(1)))
    #expect(edit("gi", "", "g", sel(1), sel(1)))
    #expect(!edit("gi", "thub.com", "git", sel(2, 10), sel(3)))
    #expect(!edit("gi", "", "git", sel(2), sel(3)))
    #expect(!edit("", "", "g", sel(0), sel(1)))
    #expect(edit("", "", "git", sel(0), sel(3)))
    #expect(edit("gi", "thub.com", "gitlab", sel(2, 10), sel(6)))
    #expect(edit("github", "", "gixyzthub", sel(2), sel(5)))
    #expect(!edit("gi", "", "g😀", sel(1, 2), sel(3)))
    #expect(!edit("gi", "", "git", sel(0), sel(3)))
    #expect(edit("", "", "github", sel(9), sel(6)))
    #expect(edit("github.com", "", "github.co", sel(10), sel(9)))
  }

  @Test func pastingMoreThanACharacterBlocksTheCompletion() {
    #expect(sup("", "", "github"))
    #expect(sup("gi", "", "gitlab"))
    #expect(!sup("gi", "thub.com", "git"))
    #expect(!sup("", "", "g"))
  }

  @Test func theCaretReachingTheEndAcceptsTheCompletion() {
    #expect(InlineRules.acceptsCompletion(typed: "git", shown: "hub.com", selection: sel(10)))
    #expect(!InlineRules.acceptsCompletion(typed: "git", shown: "hub.com", selection: sel(3, 10)))
    #expect(!InlineRules.acceptsCompletion(typed: "git", shown: "hub.com", selection: sel(3)))
    #expect(!InlineRules.acceptsCompletion(typed: "git", shown: "", selection: sel(3)))
  }
}

@MainActor
final class FakeHeroField: HeroFieldControl {
  var value = ""
  var selection = TextSelection.caret(0)
  var focused = 0
  func show(value: String, selection: TextSelection) {
    self.value = value
    self.selection = selection
  }
  func focusField() { focused += 1 }
  var fieldSelection: TextSelection { selection }
}

@MainActor
struct HeroBarModelTests {
  final class Log {
    var opened: [(String, Disposition)] = []
    var switched: [(String, String, Disposition)] = []
    var actions: [String] = []
    var removed: [String] = []
    var copied: [String] = []
    var journeys: [HeroJourney] = []
  }

  func make(_ tabId: String = UUID().uuidString) -> (HeroBarModel, FakeHeroField, Log) {
    let sources = NewTabSources()
    sources.setHistory([HistoryRow(url: "https://github.com/", title: "GitHub", favicon: nil, visits: 20, lastVisit: Date().timeIntervalSince1970 * 1000)], profileId: "p")
    sources.setTabs([TabRow(id: "t2", url: "https://news.ycombinator.com/", title: "Hacker News", favicon: nil)], profileId: "p")
    let model = HeroBarModel(windowId: "w", tabId: tabId, profileId: "p", incognito: false, settings: { Settings(values: [:]) }, sources: sources)
    let field = FakeHeroField()
    model.field = field
    let log = Log()
    var e = HeroBarEvents()
    e.open = { log.opened.append(($0, $1)) }
    e.switchTo = { log.switched.append(($0, $1, $2)) }
    e.runAction = { log.actions.append($0) }
    e.removeHistory = { log.removed.append($0) }
    e.copy = { log.copied.append($0) }
    e.journey = { log.journeys.append($0) }
    model.events = e
    return (model, field, log)
  }

  func type(_ model: HeroBarModel, _ field: FakeHeroField, _ text: String) {
    for i in 1...text.count {
      let next = String(text.prefix(i))
      let before = field.selection
      field.value = next
      field.selection = .caret(next.utf16.count)
      model.textChanged(next, edit: EditContext(before: before, after: field.selection))
    }
  }

  @Test func typingCompletesInlineAndSelectsTheCompletion() {
    let (model, field, log) = make()
    type(model, field, "git")
    #expect(model.typed == "git")
    #expect(model.shown == "hub.com")
    #expect(field.value == "github.com")
    #expect(field.selection == TextSelection(start: 3, end: 10))
    #expect(log.journeys.contains(.keystroke) && log.journeys.contains(.suggestions))
    #expect(model.goEnabled)
  }

  @Test func escapeDropsTheCompletionThenClears() {
    let (model, field, _) = make()
    type(model, field, "git")
    model.key(HeroKey(.escape))
    #expect(model.shown.isEmpty)
    #expect(field.value == "git")
    model.key(HeroKey(.escape))
    #expect(model.typed.isEmpty)
    #expect(field.value.isEmpty)
    #expect(!model.goEnabled)
  }

  @Test func enterOpensTheTopRowInTheCurrentTab() {
    let (model, field, log) = make()
    type(model, field, "git")
    model.key(HeroKey(.enter))
    #expect(log.opened.first?.0 == "https://github.com/")
    #expect(log.opened.first?.1 == .current)
    #expect(log.journeys.last == .navigate)
    #expect(model.typed == "git")
  }

  @Test func commandEnterOpensANewTabAndResets() {
    let (model, field, log) = make()
    type(model, field, "git")
    model.key(HeroKey(.enter, meta: true))
    #expect(log.opened.first?.1 == .newTab)
    #expect(model.typed.isEmpty)
  }

  @Test func controlEnterWrapsAWordInWwwDotCom() {
    let (model, field, log) = make()
    type(model, field, "apple")
    model.key(HeroKey(.enter, ctrl: true))
    #expect(log.opened.first?.0 == "https://www.apple.com")
  }

  @Test func plainTextSearchesWithTheDefaultEngine() {
    let (model, field, log) = make()
    type(model, field, "how tall is everest")
    model.submit()
    let url = log.opened.first?.0 ?? ""
    #expect(url.contains("everest"))
  }

  @Test func anOpenTabSwitchesInsteadOfNavigating() {
    let (model, field, log) = make()
    type(model, field, "hacker")
    guard let index = model.items.firstIndex(where: { if case .page(_, _, _, let tabId, _, _) = $0 { return tabId == "t2" } else { return false } }) else {
      Issue.record("no switch-to-tab row in \(model.items)")
      return
    }
    for _ in 0..<index { model.key(HeroKey(.arrowDown)) }
    model.submit()
    #expect(log.switched.first?.0 == "t2")
    #expect(model.typed.isEmpty)
  }

  @Test func arrowsWrapAround() {
    let (model, field, _) = make()
    type(model, field, "git")
    let n = model.items.count
    #expect(n > 1)
    model.key(HeroKey(.arrowUp))
    #expect(model.selectedIndex == n - 1)
    model.key(HeroKey(.arrowDown))
    #expect(model.selectedIndex == 0)
  }

  @Test func calcCopiesTheResultInPlace() {
    let (model, field, log) = make()
    type(model, field, "12*12")
    guard let row = model.items.firstIndex(where: { if case .calc = $0 { true } else { false } }) else {
      Issue.record("no calculation row: \(model.items)")
      return
    }
    for _ in 0..<row { model.key(HeroKey(.arrowDown)) }
    model.submit()
    #expect(log.copied == ["144"])
    #expect(model.typed == "144")
    #expect(field.selection == TextSelection(start: 0, end: 3))
  }

  @Test func theQueryOutlivesTheView() {
    let tab = UUID().uuidString
    let (model, field, _) = make(tab)
    type(model, field, "hello")
    model.save()
    let (again, _, _) = make(tab)
    #expect(again.typed == "hello")
    again.reset()
    again.save()
    let (third, _, _) = make(tab)
    #expect(third.typed.isEmpty)
  }

  @Test func theGoPillNamesTheEngine() {
    let (model, field, _) = make()
    type(model, field, "weather tomorrow")
    #expect(model.goLabel != "Go")
    #expect(model.placeholder == "Search or enter address")
    model.incognito = true
    #expect(model.placeholder == "Search privately or enter address")
  }
}

struct NewTabThemeTests {
  @Test func everyGeneratedTokenParses() {
    for table in [NewTabThemeTokens.dark, NewTabThemeTokens.light] {
      for key in NewTabThemeTokens.keys {
        #expect(table[key].flatMap { CSSColor($0) } != nil, "\(key): \(table[key] ?? "missing")")
      }
    }
  }

  @Test func tokensFromJSWinOverTheDefaults() {
    let fallback = NewTabTheme(dark: true, tokens: [:])
    #expect(fallback.ntpBarSolid == CSSColor(NewTabThemeTokens.dark["ntpBarSolid"]!))
    let themed = NewTabTheme(dark: true, tokens: ["ntpBarSolid": "#112233", "goButton": "not a color"])
    #expect(themed.ntpBarSolid == CSSColor("#112233"))
    #expect(themed.goButton == fallback.goButton)
  }
}

@MainActor
struct NewTabHistoryPatchTests {
  func row(_ url: String, _ at: Double) -> HistoryRow { HistoryRow(url: url, title: url, favicon: nil, visits: 1, lastVisit: at) }

  @Test func aPatchOnTheRightBaseApplies() {
    let sources = NewTabSources()
    sources.setHistory([row("a", 3), row("b", 2), row("c", 1)], profileId: "p", rev: 1)
    let patch = NewTabSources.HistoryPatch(removed: ["b"], inserts: [(0, row("b", 4)), (3, row("d", 0))])
    #expect(sources.patchHistory(patch, profileId: "p", base: 1, rev: 2))
    #expect(sources.history("p").map(\.url) == ["b", "a", "c", "d"])
  }

  @Test func aPatchOnAnotherBaseIsRefused() {
    let sources = NewTabSources()
    sources.setHistory([row("a", 1)], profileId: "p", rev: 5)
    let patch = NewTabSources.HistoryPatch(removed: [], inserts: [(0, row("z", 2))])
    #expect(!sources.patchHistory(patch, profileId: "p", base: 4, rev: 6))
    #expect(!sources.patchHistory(patch, profileId: "q", base: 5, rev: 6))
    #expect(!sources.patchHistory(NewTabSources.HistoryPatch(removed: [], inserts: [(9, row("z", 2))]), profileId: "p", base: 5, rev: 6))
    #expect(sources.history("p").map(\.url) == ["a"])
  }
}
