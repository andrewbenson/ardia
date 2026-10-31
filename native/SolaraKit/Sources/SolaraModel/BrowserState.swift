public struct FocusState: Sendable, Equatable {
  public var appDark: Bool
  public var focusedWindowId: String?
  public var focusOrder: [String]
  public var lastProfileId: String?

  public init(focusedWindowId: String? = nil, focusOrder: [String] = [], lastProfileId: String? = nil, appDark: Bool = true) {
    self.appDark = appDark
    self.focusedWindowId = focusedWindowId
    self.focusOrder = focusOrder
    self.lastProfileId = lastProfileId
  }
}

public struct HistoryHint: Sendable, Equatable {
  public var url: String
  public var title: String
  public var favicon: String?

  public init(url: String, title: String, favicon: String?) {
    self.url = url
    self.title = title
    self.favicon = favicon
  }
}

public struct JSCaches: Sendable, Equatable {
  public var historyHints: JSMap<[HistoryHint]> = JSMap()
  public var playingAudio: Set<String> = []
  public var launchBackdrop: JSONValue = .null
  public var earlyLaunchTab: Bool? = nil
  public var systemDark = false

  public init() {}
}

public struct BrowserState: Sendable, Equatable {
  public var profiles: Table<Profile>
  public var profileOrder: [String]
  public var orphanedProfileData: [String]
  public var windows: Table<BrowserWindow>
  public var windowOrder: [String]
  public var tabs: Table<Tab>
  public var live: [String: PageLiveFacts]
  public var groups: Table<TabGroup>
  public var splits: Table<SplitView>
  public var peeks: Table<Peek>
  public var closedTabs: [ClosedTab]
  public var closedWindows: [ClosedWindow]
  public var closedGroups: [ClosedGroup]
  public var deletedGroups: [ClosedGroup]
  public var cleanedTabs: [ClosedTab]
  public var privateCleanedTabs: JSMap<[ClosedTab]>
  public var privateSiteMutes: JSMap<JSMap<Bool>>
  public var parkedPins: Table<ParkedPins>
  public var pinChoices: Table<JSMap<Double>>
  public var pinSync: Table<JSMap<JSONValue>>
  public var downloads: [Download]
  public var settings: Settings
  public var find: JSMap<FindState>
  public var selection: JSMap<TabSelection>
  public var selectionAnchors: JSMap<SelectionAnchor>
  public var windowUi: JSMap<WindowUi>
  public var ui: FocusState
  public var caches: JSCaches

  public static let defaultProfile = Profile(id: Settings.defaultProfileID, name: "Personal", color: "plum", icon: nil, createdAt: 0)

  public init(settings: Settings = .defaults, downloads: [Download] = []) {
    var profiles = Table<Profile>()
    profiles[Self.defaultProfile.id] = Self.defaultProfile
    self.profiles = profiles
    profileOrder = [Self.defaultProfile.id]
    orphanedProfileData = []
    windows = Table()
    windowOrder = []
    tabs = Table()
    live = [:]
    groups = Table()
    splits = Table()
    peeks = Table()
    closedTabs = []
    closedWindows = []
    closedGroups = []
    deletedGroups = []
    cleanedTabs = []
    privateCleanedTabs = JSMap()
    privateSiteMutes = JSMap()
    parkedPins = Table()
    pinChoices = Table()
    pinSync = Table()
    self.downloads = downloads
    self.settings = settings
    find = JSMap()
    selection = JSMap()
    selectionAnchors = JSMap()
    windowUi = JSMap()
    ui = FocusState()
    caches = JSCaches()
  }
}
