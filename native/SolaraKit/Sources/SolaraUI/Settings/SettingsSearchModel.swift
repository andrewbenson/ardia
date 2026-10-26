import Foundation
import Observation

public struct SettingsFlash: Equatable, Sendable {
  public let id: String
  public let serial: Int
}

@MainActor
@Observable
public final class SettingsSearchModel {
  public let index: SettingsIndex
  @ObservationIgnored private let prepared: [SettingsSearch.Prepared]
  @ObservationIgnored private var cached: (query: String, results: [SettingEntry]) = ("", [])

  public var query = "" {
    didSet { if query != oldValue { selected = 0 } }
  }
  public var selected = 0
  public private(set) var focusRequest = 0
  public private(set) var reveal: String?
  public private(set) var flash: SettingsFlash?
  @ObservationIgnored private var serial = 0

  public init(index: SettingsIndex, liquidGlass: Bool) {
    self.index = index
    prepared = SettingsSearch.prepare(liquidGlass ? index.entries : index.entries.filter { !$0.liquidGlassOnly })
  }

  public var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

  public var results: [SettingEntry] {
    if cached.query != query {
      cached = (query, SettingsSearch.groupByPane(SettingsSearch.search(prepared, query)).flatMap { $0.hits.map(\.entry) })
    }
    return cached.results
  }

  public func moveSelection(_ step: Int) {
    let count = results.count
    guard count > 0 else { return }
    selected = max(0, min(count - 1, selected + step))
  }

  public func requestFocus() {
    focusRequest += 1
  }

  public func submit(navigation: SettingsNavigation, profileFor: (SettingsPane, SettingsPlace) -> String?) {
    let list = results
    guard list.indices.contains(selected) else { return }
    revealSetting(list[selected].id, navigation: navigation, profileFor: profileFor)
  }

  public func revealSetting(_ id: String, navigation: SettingsNavigation, profileFor: (SettingsPane, SettingsPlace) -> String?) {
    let pane = index[id].pane
    navigation.go(pane, profileId: profileFor(pane, navigation.place))
    reveal = id
  }

  public func clearReveal() {
    reveal = nil
  }

  public func flashSetting(_ id: String) {
    reveal = nil
    serial += 1
    flash = SettingsFlash(id: id, serial: serial)
  }
}
