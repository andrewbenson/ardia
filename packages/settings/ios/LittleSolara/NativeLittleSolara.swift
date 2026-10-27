import AppKit
import ArdiaShaders
import ArdiaShell
import Foundation
import SolaraStore
import SolaraUI
import Synchronization

@MainActor
enum NativeLittleSolara {
  private static var installed = false
  private static var hosts: [String: LittleSolaraHost] = [:]
  nonisolated private static let activeIds = Mutex<Set<String>>([])

  static func install() {
    guard NativeMedia.enabled, !installed, let make = WindowHost.makeContentView else { return }
    installed = true
    WindowHost.makeContentView = { windowId in
      guard isSmallWindow(windowId) else { return make(windowId) }
      activeIds.withLock { _ = $0.insert(windowId) }
      let host = LittleSolaraHost(windowId: windowId, root: make(windowId))
      hosts[windowId] = host
      host.shell.onDetach = { [weak host] in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let host, host.shell.superview == nil, hosts[windowId] === host else { return }
            hosts[windowId] = nil
            host.stop()
            activeIds.withLock { _ = $0.remove(windowId) }
          }
        }
      }
      return host.shell
    }
  }

  static func isSmallWindow(_ windowId: String) -> Bool {
    NativeStoreHandle.store?.state.windows[windowId]?.kind == "small"
  }

  static func host(_ windowId: String) -> LittleSolaraHost? { hosts[windowId] }

  nonisolated static func active(_ windowId: String) -> Bool { activeIds.withLock { $0.contains(windowId) } }

  static func describe(_ windowId: String) -> [String: Any]? { host(windowId)?.describe() }
}

@MainActor
final class LittleSolaraHost {
  let shell: LittleSolaraShellView
  private weak var root: NSView?
  private var backdropJSON: String?
  private var tabId = ""
  private var observers: [NSObjectProtocol] = []
  private var contentSizer: NSObjectProtocol?
  private var untrack: (() -> Void)?

  init(windowId: String, root: NSView) {
    shell = LittleSolaraShellView(windowId: windowId)
    self.root = root
    shell.mount(.react, root)
    shell.bar.isHidden = true
    shell.bar.onAction = { [weak self] in NativeMedia.smallBarAction(windowId, self?.tabId ?? "", $0) }
    untrack = NativeMedia.track(NativeMedia.smallBar, windowId, shell.bar)
    let center = NotificationCenter.default
    let appeared = Notification.Name("RCTContentDidAppearNotification")
    observers.append(
      center.addObserver(forName: appeared, object: root, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.keepContentSized()
          center.post(name: appeared, object: self.shell)
        }
      })
    keepContentSized()
  }

  func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let contentSizer { NotificationCenter.default.removeObserver(contentSizer) }
    contentSizer = nil
    untrack?()
    untrack = nil
  }

  private func keepContentSized() {
    if let contentSizer { NotificationCenter.default.removeObserver(contentSizer) }
    contentSizer = nil
    guard let root, let content = root.subviews.first(where: { NSStringFromClass(type(of: $0)).hasSuffix("RootContentView") }) else { return }
    content.postsFrameChangedNotifications = true
    contentSizer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) {
      [weak root, weak content] _ in
      MainActor.assumeIsolated {
        guard let root, let content, content.superview === root, root.window != nil, !root.bounds.isEmpty, content.frame.size != root.bounds.size
        else { return }
        root.needsLayout = true
        content.needsLayout = true
      }
    }
  }

  func setBar(_ json: String) {
    guard let state = SmallBarState.decode(json) else { return }
    tabId = state.tabId ?? ""
    shell.bar.isHidden = false
    shell.bar.update(state)
  }

  func setBackdrop(_ json: String) {
    guard json != backdropJSON else { return }
    backdropJSON = json
    guard let data = json.data(using: .utf8), let props = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary,
      let view = EarlyBackdrop.make(props)
    else { return shell.mount(.backdrop, nil) }
    shell.mount(.backdrop, view)
  }

  func describe() -> [String: Any] {
    func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    return [
      "bounds": rect(shell.bounds),
      "bar": rect(shell.barFrame),
      "card": rect(shell.cardFrame),
      "barShown": !shell.bar.isHidden,
      "reactFill": (root?.value(forKey: "backgroundColor") as? NSColor).map { $0.description } ?? NSNull(),
      "slots": LittleSolaraShellView.Slot.allCases.compactMap { slot in shell.view(in: slot).map { [slot.rawValue, NSStringFromClass(type(of: $0))] } },
      "order": shell.subviews.map { NSStringFromClass(type(of: $0)) },
      "backdrop": backdropJSON ?? NSNull(),
    ]
  }
}
