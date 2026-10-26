import Foundation

public enum SettingsPane: String, CaseIterable, Identifiable, Sendable, Codable {
  case general
  case profiles
  case sync
  case tabs
  case appearance
  case privacy
  case passwords
  case autofill
  case extensions
  case search
  case engines
  case shortcuts
  case liveFolders
  case calendar
  case advanced

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .general: "General"
    case .profiles: "Profiles"
    case .sync: "Sync"
    case .tabs: "Tabs"
    case .appearance: "Appearance"
    case .privacy: "Privacy & Security"
    case .passwords: "Passwords"
    case .autofill: "Autofill"
    case .extensions: "Extensions"
    case .search: "Search Engine"
    case .engines: "Engines"
    case .shortcuts: "Keyboard Shortcuts"
    case .liveFolders: "Live Folders"
    case .calendar: "Calendar"
    case .advanced: "Advanced"
    }
  }

  public var symbol: String {
    switch self {
    case .general: "gearshape"
    case .profiles: "person.2"
    case .sync: "arrow.triangle.2.circlepath"
    case .tabs: "square.on.square"
    case .appearance: "circle.lefthalf.filled"
    case .privacy: "hand.raised"
    case .passwords: "key"
    case .autofill: "creditcard"
    case .extensions: "puzzlepiece.extension"
    case .search: "magnifyingglass"
    case .engines: "safari"
    case .shortcuts: "keyboard"
    case .liveFolders: "dot.radiowaves.left.and.right"
    case .calendar: "calendar"
    case .advanced: "slider.horizontal.3"
    }
  }
}

public struct SettingsPlace: Hashable, Sendable {
  public var pane: SettingsPane
  public var profileId: String?
  public var detail: String?

  public init(pane: SettingsPane, profileId: String? = nil, detail: String? = nil) {
    self.pane = pane
    self.profileId = profileId
    self.detail = detail
  }
}
