import Foundation

public struct OutsideURLCandidate: Equatable {
  public let path: String
  public let bundleId: String?
  public let testInstance: Bool

  public init(path: String, bundleId: String?, testInstance: Bool = false) {
    self.path = path
    self.bundleId = bundleId
    self.testInstance = testInstance
  }
}

public enum OutsideURLRoute: Equatable {
  case open
  case forward(path: String, newInstance: Bool)

  public static func forwards(_ environment: [String: String]) -> Bool {
    environment["SOLARA_BACKGROUND"] == "1" && environment["SOLARA_ACCEPT_EXTERNAL_URLS"] != "1"
  }

  public static func choose(
    environment: [String: String], ownPath: String, ownBundleId: String?, running: [OutsideURLCandidate],
    defaultHandler: OutsideURLCandidate?, installed: [String]
  ) -> OutsideURLRoute {
    guard forwards(environment) else { return .open }
    if let copy = running.first(where: { $0.path != ownPath && $0.bundleId == ownBundleId && !$0.testInstance }) {
      return .forward(path: copy.path, newInstance: false)
    }
    if let handler = defaultHandler, handler.path != ownPath {
      return .forward(path: handler.path, newInstance: ownBundleId != nil && handler.bundleId == ownBundleId)
    }
    if let copy = installed.first(where: { $0 != ownPath }) {
      return .forward(path: copy, newInstance: true)
    }
    return .open
  }
}
