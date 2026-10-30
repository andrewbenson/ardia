import AppKit
import ArdiaCore
import Darwin
import Foundation
internal import SolaraModel
internal import SolaraStore

@MainActor
final class NativeCacheFeeds {
  private let store: Store
  private let launchTab: EarlyLaunchTabProvider
  private let lastTab: LastTabPolicyProvider
  private var directoryWatch: DispatchSourceFileSystemObject?
  private var launchObserver: NSObjectProtocol?
  private var appearance: NSKeyValueObservation?

  init(store: Store, folder: URL) {
    self.store = store
    let cache = folder.appending(path: "switches-cache.json")
    launchTab = EarlyLaunchTabProvider(store: store, environment: ProcessInfo.processInfo.environment["ARDIA_SWITCHES"], readCache: { try? Data(contentsOf: cache) })
    lastTab = LastTabPolicyProvider(store: store)
    let fd = open(folder.path, O_EVTONLY)
    if fd >= 0 {
      let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
      source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refreshSwitches() } }
      source.setCancelHandler { close(fd) }
      directoryWatch = source
      source.resume()
    } else {
      NSLog("[store] couldn't watch switches-cache.json: %d", errno)
    }
    refreshSwitches()
    launchObserver = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.appFinishedLaunching() }
    }
  }

  isolated deinit {
    directoryWatch?.cancel()
    if let launchObserver { NotificationCenter.default.removeObserver(launchObserver) }
  }

  private func refreshSwitches() {
    apply { try self.launchTab.refresh() }
  }

  private func appFinishedLaunching() {
    if let launchObserver { NotificationCenter.default.removeObserver(launchObserver) }
    launchObserver = nil
    appearance = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.refreshAppearance() }
    }
    queryLastTabPolicy(attempt: 0)
  }

  private func queryLastTabPolicy(attempt: Int) {
    ArdiaCoreEngineBridge.call("ac_tabs_last_tab_policy", profile: "", args: nil) { [weak self] text in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let reply = (try? JSONValue.parse(text)) ?? .null
        if reply["closesWindow"]?.bool != nil {
          self.apply { try self.lastTab.receive(reply) }
        } else if attempt < 600 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.queryLastTabPolicy(attempt: attempt + 1) }
          }
        } else {
          NSLog("[store] last-tab policy unavailable: %@", text)
        }
      }
    }
  }

  private func refreshAppearance() {
    apply {
      let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      try self.store.updateAppAppearance(dark)
    }
  }

  private func apply(_ update: @escaping @MainActor () throws -> Void) {
    do {
      try update()
    } catch is StoreBusy {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        MainActor.assumeIsolated { self?.apply(update) }
      }
    } catch {
      NSLog("[store] native cache: %@", String(describing: error))
    }
  }
}
