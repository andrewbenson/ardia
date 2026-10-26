public enum Ids {
  public static func isIncognitoProfile(_ profileId: String) -> Bool {
    profileId.hasPrefix("incognito:")
  }

  public static func incognitoProfileId(windowId: String, originalProfileId: String) -> String {
    "incognito:\(windowId)@\(originalProfileId)"
  }

  public static func incognitoOriginal(_ profileId: String) -> String {
    guard let at = profileId.firstIndex(of: "@") else { return Settings.defaultProfileID }
    return String(profileId[profileId.index(after: at)...])
  }

  public static func restoreId(_ tabId: String) -> String { "restore:\(tabId)" }
}

public struct IdSource: Sendable, Hashable {
  public var launch: String
  public var counter: Int

  public init(launch: String, counter: Int = 0) {
    self.launch = launch
    self.counter = counter
  }

  public static func random(now: Double) -> IdSource {
    let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    let suffix = String((0..<4).map { _ in alphabet[Int.random(in: 0..<36)] })
    return IdSource(launch: String(Int64(now), radix: 36) + suffix)
  }

  public mutating func next(_ prefix: String) -> String {
    counter += 1
    return "\(prefix)-\(launch)-\(String(counter, radix: 36))"
  }
}
