import SolaraModel

public struct CommandError: Error, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}

public struct PrivateDownloadSession: Sendable, Hashable {
  public var open: Bool
  public init(open: Bool) { self.open = open }
}

public enum Command: Sendable, Hashable {
  case updateSettings(patch: JSONObject, fromSync: Bool)
  case upsertDownload(Download, privateSession: PrivateDownloadSession?, focusedWindowShowing: String?)
  case removeDownload(id: String)
  case clearDownloads(visibleIds: [String]?)
  case forgetDownloads(ids: [String], privateSession: Bool)

  public var name: String {
    switch self {
    case .updateSettings: "updateSettings"
    case .upsertDownload: "upsertDownload"
    case .removeDownload: "removeDownload"
    case .clearDownloads: "clearDownloads"
    case .forgetDownloads: "forgetDownloads"
    }
  }

  public var isDurable: Bool {
    switch self {
    case .updateSettings: true
    default: false
    }
  }

  public init(json: JSONValue) throws {
    guard let name = json["name"]?.string else { throw CommandError("command has no name") }
    let args = json["args"]?.array ?? []
    func arg(_ i: Int) -> JSONValue? { i < args.count ? args[i] : nil }
    func object(_ i: Int) throws -> JSONObject {
      guard let value = arg(i)?.object else { throw CommandError("\(name): argument \(i) is not an object") }
      return value
    }
    func string(_ i: Int) throws -> String {
      guard let value = arg(i)?.string else { throw CommandError("\(name): argument \(i) is not a string") }
      return value
    }
    func strings(_ value: JSONValue?) -> [String]? { value?.array?.compactMap(\.string) }
    switch name {
    case "updateSettings":
      self = .updateSettings(patch: try object(0), fromSync: arg(1)?["fromSync"]?.truthy ?? false)
    case "upsertDownload":
      let context = arg(1)?.object
      let session = context?["privateSession"]?.object.map { PrivateDownloadSession(open: $0["open"]?.truthy ?? false) }
      self = .upsertDownload(Download(json: try object(0)), privateSession: session, focusedWindowShowing: context?["focusedWindowShowing"]?.string)
    case "removeDownload":
      self = .removeDownload(id: try string(0))
    case "clearDownloads":
      self = .clearDownloads(visibleIds: strings(arg(0)?["visibleIds"]))
    case "forgetDownloads":
      self = .forgetDownloads(ids: strings(arg(0)?["ids"]) ?? [], privateSession: arg(0)?["privateSession"]?.truthy ?? false)
    default:
      throw CommandError("unknown command \(name)")
    }
  }
}

public enum Effect: Sendable, Hashable {
  case openDownloads(windowId: String)

  public var json: JSONValue {
    switch self {
    case .openDownloads(let windowId): ["type": "openDownloads", "windowId": .string(windowId)]
    }
  }
}
