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
  case about

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
    case .about: "About"
    }
  }

  public static let sidebarGroups: [[SettingsPane]] = [
    [.general, .profiles, .sync],
    [.tabs, .appearance, .search, .engines, .shortcuts],
    [.privacy, .passwords, .autofill, .extensions],
    [.liveFolders, .calendar],
    [.advanced, .about],
  ]

  public static let sidebarOrder: [SettingsPane] = sidebarGroups.flatMap { $0 }

  public var tileSymbol: String {
    switch self {
    case .general: "gearshape.fill"
    case .profiles: "person.2.fill"
    case .sync: "arrow.triangle.2.circlepath"
    case .tabs: "square.on.square.fill"
    case .appearance: "circle.lefthalf.filled"
    case .privacy: "hand.raised.fill"
    case .passwords: "key.fill"
    case .autofill: "creditcard.fill"
    case .extensions: "puzzlepiece.extension.fill"
    case .search: "magnifyingglass"
    case .engines: "safari.fill"
    case .shortcuts: "keyboard.fill"
    case .liveFolders: "dot.radiowaves.left.and.right"
    case .calendar: "calendar"
    case .advanced: "gearshape.2.fill"
    case .about: "info"
    }
  }

  public var tileColor: SettingsTileColor {
    switch self {
    case .general, .passwords, .search, .shortcuts, .extensions, .advanced, .about: .gray
    case .profiles, .privacy, .engines: .blue
    case .sync: .cyan
    case .tabs: .indigo
    case .appearance: .black
    case .autofill: .green
    case .liveFolders: .orange
    case .calendar: .red
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
    case .about: "info.circle"
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

public enum SettingsTileColor: Sendable {
  case gray, blue, cyan, indigo, black, green, orange, red
}
