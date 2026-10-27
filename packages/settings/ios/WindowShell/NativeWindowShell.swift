import AppKit
import ArdiaShaders
import ArdiaShell
import ExpoModulesCore
import Foundation
import SolaraStore
import Synchronization
import SolaraUI

@MainActor
enum NativeWindowShell {
  private static var installed = false
  private static var shells: [String: ShellHost] = [:]
  nonisolated private static let activeIds = Mutex<Set<String>>([])

  nonisolated static var enabled: Bool {
    ProcessInfo.processInfo.environment["ARDIA_NATIVE_SHELL"] == "1"
  }

  static func install() {
    guard enabled, !installed, let make = WindowHost.makeContentView else { return }
    installed = true
    NativeSplitChrome.start()
    WindowHost.makeContentView = { windowId in
      guard isBrowserWindow(windowId) else { return make(windowId) }
      activeIds.withLock { _ = $0.insert(windowId) }
      let host = ShellHost(windowId: windowId, root: make(windowId))
      shells[windowId] = host
      host.shell.onDetach = { [weak host] in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let host, host.shell.superview == nil, shells[windowId] === host else { return }
            shells[windowId] = nil
            host.stop()
            activeIds.withLock { _ = $0.remove(windowId) }
          }
        }
      }
      return host.shell
    }
  }

  static func isBrowserWindow(_ windowId: String) -> Bool {
    guard let window = NativeStoreHandle.store?.state.windows[windowId] else { return false }
    return window.kind == nil || window.kind == "browser"
  }

  static func host(_ windowId: String) -> ShellHost? { shells[windowId] }

  nonisolated static func active(_ windowId: String) -> Bool { activeIds.withLock { $0.contains(windowId) } }

  static func setBackdrop(_ windowId: String, _ json: String) {
    host(windowId)?.setBackdrop(json)
  }

  static func describe(_ windowId: String) -> [String: Any]? {
    host(windowId)?.describe()
  }
}

@MainActor
final class ShellHost {
  let shell: WindowShellView
  private weak var root: NSView?
  private var backdropJSON: String?
  private var observers: [NSObjectProtocol] = []
  private var contentSizer: NSObjectProtocol?

  init(windowId: String, root: NSView) {
    shell = WindowShellView(windowId: windowId)
    self.root = root
    shell.mount(.react, root)
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

  func setBackdrop(_ json: String) {
    guard json != backdropJSON else { return }
    backdropJSON = json
    guard let data = json.data(using: .utf8), let props = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary,
      let view = EarlyBackdrop.make(props)
    else { return shell.mount(.backdrop, nil) }
    shell.mount(.backdrop, view)
  }

  func describe() -> [String: Any] {
    func rect(_ r: CGRect?) -> Any { r.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull() }
    let f = shell.frames
    return [
      "bounds": rect(shell.bounds),
      "card": rect(f.card),
      "sidebar": rect(f.sidebar),
      "sidebarShift": f.sidebarShift,
      "topStrip": rect(f.topStrip),
      "slots": WindowShellView.Slot.allCases.compactMap { slot in shell.view(in: slot).map { [slot.rawValue, NSStringFromClass(type(of: $0))] } },
      "order": shell.subviews.map { NSStringFromClass(type(of: $0)) },
      "backdrop": backdropJSON ?? NSNull(),
      "split": NativeSplitChrome.sample(shell.windowId) ?? NSNull(),
    ]
  }
}

public class WindowShellModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraWindowShell")

    OnCreate { DispatchQueue.main.async { MainActor.assumeIsolated { NativeWindowShell.install() } } }

    Function("active") { (windowId: String) -> Bool in
      NativeWindowShell.enabled && NativeWindowShell.active(windowId)
    }

    AsyncFunction("setBackdrop") { (windowId: String, json: String) in
      MainActor.assumeIsolated { NativeWindowShell.setBackdrop(windowId, json) }
    }.runOnQueue(.main)

    AsyncFunction("describe") { (windowId: String) -> String in
      MainActor.assumeIsolated {
        guard let info = NativeWindowShell.describe(windowId), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
    }.runOnQueue(.main)
  }
}
