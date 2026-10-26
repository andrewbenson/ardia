import Foundation
import Observation

@MainActor
@Observable
public final class SettingsNavigation {
  public static let historyLimit = 30

  public private(set) var place: SettingsPlace
  public private(set) var back: [SettingsPlace] = []
  public private(set) var forward: [SettingsPlace] = []

  public init(place: SettingsPlace = SettingsPlace(pane: .general)) {
    self.place = place
  }

  public var pane: SettingsPane { place.pane }
  public var profileId: String? { place.profileId }
  public var detail: String? { place.detail }
  public var canGoBack: Bool { !back.isEmpty }
  public var canGoForward: Bool { !forward.isEmpty }

  public func go(_ pane: SettingsPane, profileId: String? = nil, detail: String? = nil) {
    let next = SettingsPlace(pane: pane, profileId: profileId, detail: detail)
    if next == place { return }
    back = Array((back + [place]).suffix(Self.historyLimit))
    forward = []
    place = next
  }

  public func replace(profileId: String?, detail: String? = nil) {
    let next = SettingsPlace(pane: place.pane, profileId: profileId, detail: detail)
    if back.last == next { back.removeLast() }
    forward = []
    place = next
  }

  public func goBack() {
    guard let previous = back.popLast() else { return }
    forward.insert(place, at: 0)
    place = previous
  }

  public func goForward() {
    guard !forward.isEmpty else { return }
    let next = forward.removeFirst()
    back.append(place)
    place = next
  }
}
