import Foundation

public enum DocumentListing {
  public struct Pending {
    public let staged: Set<String>
    public let removing: Set<String>
    public init(staged: Set<String>, removing: Set<String>) {
      self.staged = staged
      self.removing = removing
    }
  }

  static let landing = #"\.sb-[0-9a-f]+-\w+$"#

  public static func names(prefix: String, pending snapshot: () -> Pending, onDisk: () -> [String]) -> [String] {
    let pending = snapshot()
    let disk = onDisk().filter { $0.range(of: landing, options: .regularExpression) == nil }
    let going = pending.removing.subtracting(pending.staged)
    return Set(disk).union(pending.staged).subtracting(going).filter { $0.hasPrefix(prefix) }.sorted()
  }
}
