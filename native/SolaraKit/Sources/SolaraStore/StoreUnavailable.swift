import Foundation

public struct StoreUnavailable: Equatable, Sendable {
  public enum Cause: Equatable, Sendable {
    case refused
    case openFailed
  }

  public let cause: Cause
  public let detail: String
  public let dataFolder: URL?

  public init(cause: Cause, detail: String, dataFolder: URL?) {
    self.cause = cause
    self.detail = detail
    self.dataFolder = dataFolder
  }
}
