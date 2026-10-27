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
  private static var storeListener: Int?
  private static let lifetimes: ShellLifetimes<ShellHost> = {
    let lifetimes = ShellLifetimes<ShellHost> { $0.stop() }
    lifetimes.onIds = { ids in activeIds.withLock { $0 = ids } }
    return lifetimes
  }()
  private static let commits = ShellStoreCommits()
  nonisolated private static let activeIds = Mutex<Set<String>>([])

  nonisolated static var enabled: Bool {
    ProcessInfo.processInfo.environment["ARDIA_NATIVE_SHELL"] == "1"
  }

  static func install() {
    guard enabled, !installed, let make = WindowHost.makeContentView else { return }
    installed = true
    NativeSplitChrome.start()
    if let store = NativeStoreHandle.store {
      let sink = commits
      storeListener = store.subscribe { commit in sink.receive(Set(commit.state.windows.keys)) }
    }
    WindowHost.makeContentView = { windowId in
      guard isBrowserWindow(windowId) else { return make(windowId) }
      activeIds.withLock { _ = $0.insert(windowId) }
      let host = ShellHost(windowId: windowId, root: make(windowId))
      lifetimes.adopt(windowId, host)
      host.onClose = { [weak host] in lifetimes.end(windowId, ifHost: host) }
      return host.shell
    }
  }

  static func windowsChanged(_ live: Set<String>) {
    lifetimes.prune(keeping: live)
  }

  static func isBrowserWindow(_ windowId: String) -> Bool {
    guard let window = NativeStoreHandle.store?.state.windows[windowId] else { return false }
    return window.kind == nil || window.kind == "browser"
  }

  static func host(_ windowId: String) -> ShellHost? { lifetimes.host(windowId) }

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
  private var closing: NSObjectProtocol?
  var onClose: (() -> Void)?

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
    shell.onWindow = { [weak self] window in self?.watchClose(of: window) }
  }

  private func watchClose(of window: NSWindow?) {
    if let closing { NotificationCenter.default.removeObserver(closing) }
    closing = nil
    guard let window else { return }
    closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.onClose?() }
    }
  }

  func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let closing { NotificationCenter.default.removeObserver(closing) }
    closing = nil
    onClose = nil
    shell.onWindow = nil
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
      "fill": shell.backgroundColor.map { String(describing: $0) } ?? NSNull(),
      "windowFill": shell.window?.backgroundColor.map { String(describing: $0) } ?? NSNull(),
      "appearance": shell.window?.effectiveAppearance.name.rawValue ?? NSNull(),
      "split": NativeSplitChrome.sample(shell.windowId) ?? NSNull(),
    ]
  }
}

final class ShellStoreCommits: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: Set<String>?
  private var scheduled = false

  func receive(_ ids: Set<String>) {
    if Thread.isMainThread {
      lock.withLock { latest = nil }
      MainActor.assumeIsolated { NativeWindowShell.windowsChanged(ids) }
      return
    }
    let schedule = lock.withLock { () -> Bool in
      latest = ids
      if scheduled { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      let ids = lock.withLock { () -> Set<String>? in
        scheduled = false
        defer { latest = nil }
        return latest
      }
      guard let ids else { return }
      MainActor.assumeIsolated { NativeWindowShell.windowsChanged(ids) }
    }
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
