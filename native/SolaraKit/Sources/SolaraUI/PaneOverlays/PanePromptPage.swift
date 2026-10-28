import Foundation

public struct PanePasswordPrompt: Equatable, Sendable {
  public var origin: String
  public var username: String
  public var usernames: [String]
  public var update: Bool
  public var passwordLength: Int
  public var federation: String

  public init?(_ payload: [String: Any]) {
    guard let state = payload["state"] as? String, state == "save" || state == "update", let origin = payload["origin"] as? String else { return nil }
    self.origin = origin
    username = payload["username"] as? String ?? ""
    usernames = payload["usernames"] as? [String] ?? []
    update = state == "update"
    passwordLength = (payload["passwordLength"] as? NSNumber)?.intValue ?? 0
    federation = payload["federation"] as? String ?? ""
  }

  public var key: String { "\(origin)|\(username)|\(update ? "update" : "save")" }
}

public struct PanePromptPage: Equatable, Sendable {
  public var crashed = false
  public var unresponsive = false
  public var pageKey: String?
  public var password: PanePasswordPrompt?
  public var chosenUsername: String?

  public init() {}

  public var sadMode: SadTabMode? { crashed ? .crashed : unresponsive ? .unresponsive : nil }

  public var shown: PanePromptPage {
    var page = self
    page.pageKey = nil
    return page
  }

  public mutating func take(_ name: String, _ payload: [String: Any]) -> Bool {
    let before = self
    switch name {
    case "onPageCreated": self = PanePromptPage()
    case "onCrashed":
      crashed = true
      unresponsive = false
    case "onUnresponsive": unresponsive = true
    case "onResponsive": unresponsive = false
    case "onPasswordPrompt":
      password = PanePasswordPrompt(payload)
      chosenUsername = nil
    case "onNavigationChange":
      guard let reported = payload["url"] as? String else { break }
      let blankInitial = payload["initialDocumentAccessed"] as? Bool == true && payload["committedInitial"] as? Bool == true
      let key = Self.pageKey(blankInitial ? "about:blank" : reported)
      if let pageKey, pageKey != key {
        crashed = false
        password = nil
        chosenUsername = nil
      }
      pageKey = key
    default: break
    }
    return self != before
  }

  public static func pageKey(_ url: String) -> String {
    url.firstIndex(of: "#").map { String(url[..<$0]) } ?? url
  }
}
