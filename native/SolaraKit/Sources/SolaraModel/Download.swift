public struct Download: Sendable, Hashable {
  public var json: JSONObject

  public init(json: JSONObject) {
    self.json = json
  }

  public var id: String {
    get { json["id"]?.string ?? "" }
    set { json["id"] = .string(newValue) }
  }

  public var profile: String? { json["profile"]?.string }
  public var offTheRecord: Bool { json["offTheRecord"]?.truthy ?? false }
  public var state: String? { json["state"]?.string }
  public var isDownloading: Bool { state == "downloading" }
  public var isPrivate: Bool { offTheRecord || (profile.map(Ids.isIncognitoProfile) ?? false) }

  public static let maxKept = 100
  static let stagingKeys = ["staging", "stagingId", "destination"]

  public var leftStaging: (path: String, uuid: String, folder: String)? {
    let stagingId = json["stagingId"]?.string
    let uuid = stagingId ?? (id.hasPrefix("wk-download-") ? String(id.dropFirst("wk-download-".count)) : "")
    let destination = json["destination"]?.string ?? ""
    let folder = destination.lastIndex(of: "/").map { String(destination[..<$0]) } ?? String(destination.dropLast())
    guard let staging = json["staging"]?.string, !staging.isEmpty, !uuid.isEmpty, !folder.isEmpty, !isDownloading else { return nil }
    return (staging, uuid, folder)
  }

  public func withoutStaging() -> Download {
    var next = json
    for key in Self.stagingKeys { next.removeValue(forKey: key) }
    return Download(json: next)
  }

  public func persisted() -> Download {
    guard isDownloading else { return self }
    var next = json
    next["state"] = "failed"
    return Download(json: next)
  }

  public func loaded(at index: Int) -> Download {
    let id = "saved-\(index)"
    guard let left = leftStaging else {
      var kept = withoutStaging()
      kept.id = id
      return kept
    }
    var next = self
    next.id = id
    next.json["stagingId"] = .string(left.uuid)
    return next
  }
}
