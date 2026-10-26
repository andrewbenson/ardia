public struct Profile: JSONConvertible {
  public var id: String
  public var name: String
  public var color: String
  public var icon: String? { didSet { absent.remove("icon") } }
  public var createdAt: Double
  public var dataId: String?
  public var theme: JSONValue?
  public var extra: JSONObject = [:]
  public internal(set) var absent: Set<String> = []

  public init(id: String, name: String, color: String, icon: String?, createdAt: Double, dataId: String? = nil, theme: JSONValue? = nil) {
    self.id = id
    self.name = name
    self.color = color
    self.icon = icon
    self.createdAt = createdAt
    self.dataId = dataId
    self.theme = theme
  }

  static let keys: Set<String> = ["id", "name", "color", "icon", "createdAt", "dataId", "theme"]

  public init(json: JSONObject) throws {
    let f = Fields(json, known: Self.keys)
    id = f.string("id")
    name = f.string("name")
    color = f.string("color")
    icon = f.optionalString("icon")
    createdAt = f.number("createdAt")
    dataId = f.optionalString("dataId")
    theme = f.value("theme")
    extra = f.extra
    absent = f.absent(["icon"])
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra)
    e.set("id", id)
    e.set("name", name)
    e.set("color", color)
    e.nullable("icon", icon, absent: absent)
    e.set("createdAt", createdAt)
    e.optional("dataId", dataId)
    e.optional("theme", theme)
    return e.object
  }
}

public struct BrowserWindow: JSONConvertible {
  public var id: String
  public var profileId: String
  public var incognito: Bool
  public var tabIds: [String]
  public var activeTabIds: JSMap<String>
  public var sidebarOpen: Bool
  public var tabLayout: String?
  public var frame: [Double]? { didSet { absent.remove("frame") } }
  public var fullScreen: Double?
  public var createdAt: Double
  public var kind: String?
  public var linkPointer: [Double]?
  public var originalProfileId: String?
  public var chromeWindow: String?
  public var extra: JSONObject = [:]
  public internal(set) var absent: Set<String> = []

  public init(id: String, profileId: String, incognito: Bool, frame: [Double]?, createdAt: Double) {
    self.id = id
    self.profileId = profileId
    self.incognito = incognito
    tabIds = []
    activeTabIds = JSMap()
    sidebarOpen = true
    self.frame = frame
    self.createdAt = createdAt
  }

  public var isSmall: Bool { kind == "small" }

  static let keys: Set<String> = [
    "id", "profileId", "incognito", "tabIds", "activeTabIds", "sidebarOpen", "tabLayout", "frame", "fullScreen", "createdAt", "kind",
    "linkPointer", "originalProfileId", "chromeWindow",
  ]

  public init(json: JSONObject) throws {
    let f = Fields(json, known: Self.keys)
    id = f.string("id")
    profileId = f.string("profileId")
    incognito = f.bool("incognito")
    tabIds = f.strings("tabIds")
    activeTabIds = f.stringMap("activeTabIds")
    sidebarOpen = f.bool("sidebarOpen")
    tabLayout = f.optionalString("tabLayout")
    frame = f.optionalNumbers("frame")
    fullScreen = f.optionalNumber("fullScreen")
    createdAt = f.number("createdAt")
    kind = f.optionalString("kind")
    linkPointer = f.optionalNumbers("linkPointer")
    originalProfileId = f.optionalString("originalProfileId")
    chromeWindow = f.optionalString("chromeWindow")
    extra = f.extra
    absent = f.absent(["frame"])
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra)
    e.set("id", id)
    e.set("profileId", profileId)
    e.set("incognito", incognito)
    e.set("tabIds", tabIds)
    e.set("activeTabIds", activeTabIds)
    e.set("sidebarOpen", sidebarOpen)
    e.optional("tabLayout", tabLayout)
    e.nullable("frame", frame, absent: absent)
    e.optional("fullScreen", fullScreen)
    e.set("createdAt", createdAt)
    e.optional("kind", kind)
    e.optional("linkPointer", linkPointer)
    e.optional("originalProfileId", originalProfileId)
    e.optional("chromeWindow", chromeWindow)
    return e.object
  }

  public var persistedJSON: JSONObject {
    var out = json
    out.removeValue(forKey: "chromeWindow")
    return out
  }
}

public struct Navigation: JSONConvertible {
  public var url: String
  public var seq: Double
  public var userInitiated: Bool?

  public init(url: String, seq: Double, userInitiated: Bool? = nil) {
    self.url = url
    self.seq = seq
    self.userInitiated = userInitiated
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: [])
    url = f.string("url")
    seq = f.number("seq")
    userInitiated = f.optionalBool("userInitiated")
  }

  public var json: JSONObject {
    var e = Encoder()
    e.set("url", url)
    e.set("seq", seq)
    e.optional("userInitiated", userInitiated)
    return e.object
  }
}

public struct TileFolder: JSONConvertible {
  public var id: String
  public var name: String
  public var renamedAt: Double?
  public var extra: JSONObject = [:]

  public init(id: String, name: String, renamedAt: Double? = nil) {
    self.id = id
    self.name = name
    self.renamedAt = renamedAt
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: ["id", "name", "renamedAt"])
    id = f.string("id")
    name = f.string("name")
    renamedAt = f.optionalNumber("renamedAt")
    extra = f.extra
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra)
    e.set("id", id)
    e.set("name", name)
    e.optional("renamedAt", renamedAt)
    return e.object
  }
}

public struct Tab: JSONConvertible {
  public var id: String
  public var windowId: String
  public var profileId: String
  public var url: String
  public var title: String
  public var favicon: String? { didSet { absent.remove("favicon") } }
  public var pinned: Bool
  public var muted: Bool
  public var zoom: Double
  public var customTitle: String? { didSet { absent.remove("customTitle") } }
  public var customIcon: String? { didSet { absent.remove("customIcon") } }
  public var pinnedUrl: String? { didSet { absent.remove("pinnedUrl") } }
  public var pinnedAsRow: Bool?
  public var tileFolder: TileFolder?
  public var navigation: Navigation? { didSet { absent.remove("navigation") } }
  public var adoptId: String?
  public var openerId: String? { didSet { absent.remove("openerId") } }
  public var wakeAdoptId: String?
  public var liveItem: JSONValue?
  public var unloaded: Bool?
  public var pinKey: String?
  public var pageIn: String?
  public var engine: String?
  public var createdAt: Double
  public var lastActiveAt: Double
  public var extra: JSONObject = [:]
  public internal(set) var absent: Set<String> = []

  public init(id: String, windowId: String, profileId: String, url: String, now: Double) {
    self.id = id
    self.windowId = windowId
    self.profileId = profileId
    self.url = url
    title = ""
    favicon = nil
    pinned = false
    muted = false
    zoom = 1
    customTitle = nil
    customIcon = nil
    pinnedUrl = nil
    openerId = nil
    createdAt = now
    lastActiveAt = now
  }

  public var isPinnedRow: Bool { pinned && pinnedAsRow == true }
  public var pinSection: PinSection { !pinned ? .none : pinnedAsRow == true ? .row : .tile }
  public var pinKeyOrId: String { pinKey ?? id }

  static let keys: Set<String> = [
    "id", "windowId", "profileId", "url", "title", "favicon", "pinned", "muted", "zoom", "customTitle", "customIcon", "pinnedUrl",
    "pinnedAsRow", "tileFolder", "navigation", "adoptId", "openerId", "wakeAdoptId", "liveItem", "unloaded", "pinKey", "pageIn", "engine",
    "createdAt", "lastActiveAt",
  ]

  public init(json: JSONObject) throws {
    let f = Fields(json, known: Self.keys)
    id = f.string("id")
    windowId = f.string("windowId")
    profileId = f.string("profileId")
    url = f.string("url")
    title = f.string("title")
    favicon = f.optionalString("favicon")
    pinned = f.bool("pinned")
    muted = f.bool("muted")
    zoom = f.optionalNumber("zoom") ?? 1
    customTitle = f.optionalString("customTitle")
    customIcon = f.optionalString("customIcon")
    pinnedUrl = f.optionalString("pinnedUrl")
    pinnedAsRow = f.optionalBool("pinnedAsRow")
    tileFolder = try f.model("tileFolder")
    navigation = try f.model("navigation")
    adoptId = f.optionalString("adoptId")
    openerId = f.optionalString("openerId")
    wakeAdoptId = f.optionalString("wakeAdoptId")
    liveItem = f.value("liveItem")
    unloaded = f.optionalBool("unloaded")
    pinKey = f.optionalString("pinKey")
    pageIn = f.optionalString("pageIn")
    engine = f.optionalString("engine")
    createdAt = f.number("createdAt")
    lastActiveAt = f.number("lastActiveAt")
    extra = f.extra
    absent = f.absent(["favicon", "customTitle", "customIcon", "pinnedUrl", "openerId", "navigation"])
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra)
    e.set("id", id)
    e.set("windowId", windowId)
    e.set("profileId", profileId)
    e.set("url", url)
    e.set("title", title)
    e.nullable("favicon", favicon, absent: absent)
    e.set("pinned", pinned)
    e.set("muted", muted)
    e.set("zoom", zoom)
    e.nullable("customTitle", customTitle, absent: absent)
    e.nullable("customIcon", customIcon, absent: absent)
    e.nullable("pinnedUrl", pinnedUrl, absent: absent)
    e.optional("pinnedAsRow", pinnedAsRow)
    e.optional("tileFolder", tileFolder)
    e.nullable("navigation", navigation, absent: absent)
    e.optional("adoptId", adoptId)
    e.nullable("openerId", openerId, absent: absent)
    e.optional("wakeAdoptId", wakeAdoptId)
    e.optional("liveItem", liveItem)
    e.optional("unloaded", unloaded)
    e.optional("pinKey", pinKey)
    e.optional("pageIn", pageIn)
    e.optional("engine", engine)
    e.set("createdAt", createdAt)
    e.set("lastActiveAt", lastActiveAt)
    return e.object
  }
}

public enum PinSection: Sendable, Equatable {
  case tile, row, none
}

public struct TabGroup: JSONConvertible {
  public var id: String
  public var windowId: String
  public var profileId: String
  public var name: String
  public var icon: String? { didSet { absent.remove("icon") } }
  public var color: String? { didSet { absent.remove("color") } }
  public var collapsed: Bool
  public var pinned: Bool
  public var tabIds: [String]
  public var createdAt: Double
  public var autoUngroup: Bool?
  public var pinnedOpenerId: String?
  public var pinKey: String?
  public var parentId: String?
  public var extra: JSONObject = [:]
  public internal(set) var absent: Set<String> = []

  public init(id: String, windowId: String, profileId: String, name: String, icon: String?, color: String?, collapsed: Bool, pinned: Bool,
    tabIds: [String], createdAt: Double)
  {
    self.id = id
    self.windowId = windowId
    self.profileId = profileId
    self.name = name
    self.icon = icon
    self.color = color
    self.collapsed = collapsed
    self.pinned = pinned
    self.tabIds = tabIds
    self.createdAt = createdAt
  }

  public var pinKeyOrId: String { pinKey ?? id }

  static let keys: Set<String> = [
    "id", "windowId", "profileId", "name", "icon", "color", "collapsed", "pinned", "tabIds", "createdAt", "autoUngroup", "pinnedOpenerId",
    "pinKey", "parentId",
  ]

  public init(json: JSONObject) throws {
    let f = Fields(json, known: Self.keys)
    id = f.string("id")
    windowId = f.string("windowId")
    profileId = f.string("profileId")
    name = f.string("name")
    icon = f.optionalString("icon")
    color = f.optionalString("color")
    collapsed = f.bool("collapsed")
    pinned = f.bool("pinned")
    tabIds = f.strings("tabIds")
    createdAt = f.number("createdAt")
    autoUngroup = f.optionalBool("autoUngroup")
    pinnedOpenerId = f.optionalString("pinnedOpenerId")
    pinKey = f.optionalString("pinKey")
    parentId = f.optionalString("parentId")
    extra = f.extra
    absent = f.absent(["icon", "color"])
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra)
    e.set("id", id)
    e.set("windowId", windowId)
    e.set("profileId", profileId)
    e.set("name", name)
    e.nullable("icon", icon, absent: absent)
    e.nullable("color", color, absent: absent)
    e.set("collapsed", collapsed)
    e.set("pinned", pinned)
    e.set("tabIds", tabIds)
    e.set("createdAt", createdAt)
    e.optional("autoUngroup", autoUngroup)
    e.optional("pinnedOpenerId", pinnedOpenerId)
    e.optional("pinKey", pinKey)
    e.optional("parentId", parentId)
    return e.object
  }
}

public struct SplitStack: JSONConvertible {
  public var index: Int
  public var sizes: [Double]

  public init(index: Int, sizes: [Double]) {
    self.index = index
    self.sizes = sizes
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: [])
    index = Int(f.number("index"))
    sizes = f.numbers("sizes")
  }

  public var json: JSONObject {
    var e = Encoder()
    e.set("index", Double(index))
    e.set("sizes", sizes)
    return e.object
  }
}

public struct SplitView: JSONConvertible {
  public var id: String
  public var windowId: String
  public var tabIds: [String]
  public var orientation: String
  public var sizes: [Double]
  public var stack: SplitStack?
  public var extra: JSONObject = [:]

  public init(id: String, windowId: String, tabIds: [String], orientation: String, sizes: [Double], stack: SplitStack? = nil) {
    self.id = id
    self.windowId = windowId
    self.tabIds = tabIds
    self.orientation = orientation
    self.sizes = sizes
    self.stack = stack
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: ["id", "windowId", "tabIds", "orientation", "sizes", "stack"])
    id = f.string("id")
    windowId = f.string("windowId")
    tabIds = f.strings("tabIds")
    orientation = f.string("orientation")
    sizes = f.numbers("sizes")
    stack = try f.model("stack")
    extra = f.extra
  }

  public var json: JSONObject {
    var e = Encoder(extra: extra)
    e.set("id", id)
    e.set("windowId", windowId)
    e.set("tabIds", tabIds)
    e.set("orientation", orientation)
    e.set("sizes", sizes)
    e.optional("stack", stack)
    return e.object
  }
}

public struct PeekPoint: JSONConvertible {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  public init(json: JSONObject) throws {
    x = json["x"]?.number ?? 0
    y = json["y"]?.number ?? 0
  }

  public var json: JSONObject { ["x": .number(x), "y": .number(y)] }
}

public struct Peek: JSONConvertible {
  public var tabId: String
  public var sourceId: String
  public var sourcePage: String
  public var from: PeekPoint?

  public init(tabId: String, sourceId: String, sourcePage: String, from: PeekPoint?) {
    self.tabId = tabId
    self.sourceId = sourceId
    self.sourcePage = sourcePage
    self.from = from
  }

  public init(json: JSONObject) throws {
    let f = Fields(json, known: [])
    tabId = f.string("tabId")
    sourceId = f.string("sourceId")
    sourcePage = f.string("sourcePage")
    from = try f.model("from")
  }

  public var json: JSONObject {
    var e = Encoder()
    e.set("tabId", tabId)
    e.set("sourceId", sourceId)
    e.set("sourcePage", sourcePage)
    e.nullable("from", from)
    return e.object
  }
}
extension Navigation: Hashable {}
