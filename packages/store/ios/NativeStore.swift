import AppKit
import Foundation
internal import SolaraBridgeCore
internal import SolaraModel
internal import SolaraOmnibox
public import SolaraPersistence
internal import SolaraStore

public final class NativeStore: Sendable {
  nonisolated(unsafe) public private(set) static var ownsWorkspace = false

  static var scope: PersistenceScope {
    LaunchSwitches.shared.scope == "settingsAndDownloads" ? .settingsAndDownloads : .everything
  }

  static func config(_ folder: URL) -> StoreConfig {
    var config = StoreConfig()
    config.handOffPinsImmediately = false
    config.earlyLaunchTab = earlyLaunchTabSwitch(folder)
    return config
  }

  static func earlyLaunchTabSwitch(_ folder: URL) -> Bool {
    EarlyLaunchTabProvider.resolve(
      environment: ProcessInfo.processInfo.environment["ARDIA_SWITCHES"],
      cache: try? Data(contentsOf: folder.appending(path: "switches-cache.json")))
  }

  nonisolated(unsafe) public private(set) static var shared: NativeStore?
  nonisolated(unsafe) public private(set) static var unavailableReason: String?
  nonisolated(unsafe) public private(set) static var refusedSession: String?
  nonisolated(unsafe) public private(set) static var handedOff = false
  nonisolated(unsafe) static var folderLock: FolderLock?

  let bridge: StoreBridge
  let writer: PersistenceWriter
  let launch: Launch
  let caches: NativeCacheFeeds

  @MainActor
  init(bridge: StoreBridge, writer: PersistenceWriter, launch: Launch, folder: URL) {
    self.bridge = bridge
    self.writer = writer
    self.launch = launch
    caches = NativeCacheFeeds(store: bridge.store, folder: folder)
  }

  public static func productName() -> String {
    let info = Bundle.main.infoDictionary ?? [:]
    let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ""
    return name.trimmingCharacters(in: .whitespaces).isEmpty ? "Ardia" : name
  }

  static func dataFolder() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    if let scratch = environment["ARDIA_DATA_DIR"], !scratch.isEmpty {
      let path = scratch.hasPrefix("/") ? scratch : FileManager.default.currentDirectoryPath + "/" + scratch
      return URL(fileURLWithPath: (path as NSString).standardizingPath, isDirectory: true)
    }
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    return support.appending(path: Bundle.main.bundleIdentifier ?? "Ardia", directoryHint: .isDirectory)
  }

  static let handOffWait: TimeInterval = 15

  static func chromeSingletonPid(_ folder: URL) -> pid_t? {
    let link = folder.appending(path: "Chromium/SingletonLock").path
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link), let dash = target.lastIndex(of: "-") else { return nil }
    return pid_t(target[target.index(after: dash)...])
  }

  static func waitForHolder(_ folder: URL) throws -> FolderLock? {
    let data = DataFolder(url: folder)
    let deadline = Date().addingTimeInterval(handOffWait)
    while Date() < deadline {
      if let lock = try FolderLock.acquire(data) { return lock }
      if let holder = FolderLock.holder(data), chromeSingletonPid(folder) == holder {
        handedOff = true
        unavailableReason = "another instance (pid \(holder)) is using this data folder"
        NSLog("[store] %@; handing this launch to it", unavailableReason ?? "")
        return nil
      }
      usleep(100_000)
    }
    NSLog("[store] the instance holding this data folder never became the browser; quitting")
    if let holder = FolderLock.holder(data) { NSRunningApplication(processIdentifier: holder)?.activate() }
    exit(0)
  }

  @MainActor
  @discardableResult
  public static func launchAtStartup() -> Bool {
    _ = setAppScheme(productName())
    guard let folder = dataFolder() else {
      unavailableReason = "no data folder"
      NativeSettingsHandle.unavailable = StoreUnavailable(cause: .openFailed, detail: "no data folder", dataFolder: nil)
      return false
    }
    do {
      guard let lock = try FolderLock.acquire(DataFolder(url: folder)) ?? waitForHolder(folder) else { return false }
      folderLock = lock
      if LaunchSwitches.countLaunch().countedLaunch { MainActor.assumeIsolated { LaunchSuccessWatch.start() } }
    } catch {
      unavailableReason = "couldn't lock the data folder: \(error)"
      NativeSettingsHandle.unavailable = StoreUnavailable(cause: .openFailed, detail: unavailableReason ?? "", dataFolder: folder)
      NSLog("[store] %@; store unavailable", unavailableReason ?? "")
      return false
    }
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    let now = Date()
    let clock: @Sendable () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }
    let memory = StoreMemory(ids: IdSource.random(now: clock()))
    let addressing = OmniboxAddressing()
    let storeConfig = Self.config(folder)
    let activeScope = Self.scope
    let context = LoadContext(env: addressing, config: storeConfig, memory: memory, now: clock())
    do {
      let launch = try Launcher.open(DataFolder(url: folder), appVersion: version, now: now, context: context, scope: activeScope)
      for note in launch.report.notes { NSLog("[store] %@", note) }
      var state = launch.state
      state.caches.systemDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
      let store = Store(state: state, memory: launch.memory, env: addressing, config: storeConfig, clock: clock)
      ownsWorkspace = activeScope == .everything
      let writer = PersistenceWriter(
        store: store, database: launch.database, folder: DataFolder(url: folder), persisted: launch.persisted, scope: activeScope,
        trouble: { message in NSLog("[store] %@", message) })
      shared = NativeStore(bridge: StoreBridge(store: store), writer: writer, launch: launch, folder: folder)
      NativeSettingsHandle.active = true
      NativeStoreHandle.ownsWorkspace = ownsWorkspace
      NativeStoreHandle.ownedWorkspaceAtLaunch = ownsWorkspace
      NativeStoreHandle.opened = true
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          StoreAppearanceWatch.start()
          NativeSettingsHandle.resolve = { NativeStore.settingsModel }
          NativeStoreHandle.resolve = { NativeStore.shared?.bridge.store }
        }
      }
      NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        guard let store = NativeStore.shared else { return }
        let result = store.writer.flush(timeout: 0.5)
        if result != .saved { NSLog("[store] quit flush: %@", result.description) }
      }
      return true
    } catch {
      unavailableReason = "\(error)"
      if error is ImportRefused { refusedSession = DataFolder(url: folder).session.path }
      NativeSettingsHandle.unavailable = StoreUnavailable(cause: error is ImportRefused ? .refused : .openFailed, detail: "\(error)", dataFolder: folder)
      NSLog("[store] unavailable: %@", "\(error)")
      return false
    }
  }

  func flush(timeout: TimeInterval) -> FlushResult { writer.flush(timeout: timeout) }

  public func freeze() { writer.freeze() }
}

@MainActor
enum LaunchSuccessWatch {
  static var tokens: [NSObjectProtocol] = []

  static func start() {
    let success = LaunchSuccess(
      after: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } } },
      report: {
        LaunchSwitches.launchSucceeded()
        MainActor.assumeIsolated {
          tokens.forEach(NotificationCenter.default.removeObserver)
          tokens = []
        }
      })
    success.start()
    tokens.append(
      NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { success.quitting() }
      })
    for name in [NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification] {
      tokens.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
          let window = note.object as? NSWindow
          MainActor.assumeIsolated {
            guard let window, window.isVisible, window.occlusionState.contains(.visible) || window.isMainWindow else { return }
            success.windowShown()
          }
        })
    }
  }
}
