import Foundation

@MainActor
public final class LaunchSuccess {
  public static let settleSeconds: TimeInterval = 15
  public static let uptimeSeconds: TimeInterval = 60

  public private(set) var succeeded = false
  public private(set) var windowSeen = false
  let after: (TimeInterval, @escaping @MainActor () -> Void) -> Void
  let report: () -> Void

  public init(after: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void, report: @escaping () -> Void) {
    self.after = after
    self.report = report
  }

  public func start() {
    after(Self.uptimeSeconds) { [weak self] in self?.succeed() }
  }

  public func windowShown() {
    guard !windowSeen else { return }
    windowSeen = true
    after(Self.settleSeconds) { [weak self] in self?.succeed() }
  }

  public func quitting() {
    succeed()
  }

  func succeed() {
    guard !succeeded else { return }
    succeeded = true
    report()
  }
}
