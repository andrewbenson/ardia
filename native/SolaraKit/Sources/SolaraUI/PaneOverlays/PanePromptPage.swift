import Foundation

public struct PanePromptPage: Equatable, Sendable {
  public var crashed = false
  public var unresponsive = false
  public var pageKey: String?

  public init() {}

  public var sadMode: SadTabMode? { crashed ? .crashed : unresponsive ? .unresponsive : nil }

  public mutating func take(_ name: String, _ payload: [String: Any]) -> Bool {
    let before = self
    switch name {
    case "onPageCreated": self = PanePromptPage()
    case "onCrashed":
      crashed = true
      unresponsive = false
    case "onUnresponsive": unresponsive = true
    case "onResponsive": unresponsive = false
    case "onNavigationChange":
      guard let reported = payload["url"] as? String else { break }
      let blankInitial = payload["initialDocumentAccessed"] as? Bool == true && payload["committedInitial"] as? Bool == true
      let key = Self.pageKey(blankInitial ? "about:blank" : reported)
      if let pageKey, pageKey != key { crashed = false }
      pageKey = key
    default: break
    }
    return self != before
  }

  public static func pageKey(_ url: String) -> String {
    url.firstIndex(of: "#").map { String(url[..<$0]) } ?? url
  }
}
