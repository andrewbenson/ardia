import AppKit

@MainActor
final class TabPoolHost {
  static let shared = TabPoolHost()

  nonisolated static var available: Bool { false }

  var emit: ((String, [String: Any]) -> Void)?
  private var props: [String: [String: Any]] = [:]
  private var views: [String: NSView] = [:]

  func pageView(_ tabId: String) -> NSView? { views[tabId] }

  func setPageProps(_ tabId: String, _ changed: [String: Any]) {
    props[tabId, default: [:]].merge(changed) { _, new in new }
  }
}
