import AppKit
import Foundation
internal import SolaraBridgeCore
internal import SolaraModel
internal import SolaraOmnibox
internal import SolaraPersistence
internal import SolaraStore

public final class NativeStore: Sendable {
  nonisolated(unsafe) public private(set) static var ownsWorkspace = false

  static var scope: PersistenceScope {
    ProcessInfo.processInfo.environment["ARDIA_NATIVE_SCOPE"] == "everything" ? .everything : .settingsAndDownloads
  }

  static func config(_ folder: URL) -> StoreConfig {
    var config = StoreConfig()
    config.handOffPinsImmediately = false
    config.earlyLaunchTab = earlyLaunchTabSwitch(folder)
    return config
  }

  static func earlyLaunchTabSwitch(_ folder: URL) -> Bool {
    guard let data = try? Data(contentsOf: folder.appending(path: "switches-cache.json")),
      let switches = (try? JSONValue.parse(data))?["switches"]?.object
    else { return true }
    return switches["launchTab"] != .bool(false)
  }

  nonisolated(unsafe) public private(set) static var shared: NativeStore?
  nonisolated(unsafe) public private(set) static var unavailableReason: String?
  nonisolated(unsafe) public private(set) static var handedOff = false
  nonisolated(unsafe) static var folderLock: FolderLock?

  let bridge: StoreBridge
  let writer: PersistenceWriter
  let launch: Launch

  init(bridge: StoreBridge, writer: PersistenceWriter, launch: Launch) {
    self.bridge = bridge
    self.writer = writer
    self.launch = launch
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
    let holder = FolderLock.holder(data)
    let deadline = Date().addingTimeInterval(handOffWait)
    while Date() < deadline {
      if let lock = try FolderLock.acquire(data) { return lock }
      if let holder, chromeSingletonPid(folder) == holder {
        handedOff = true
        unavailableReason = "another instance (pid \(holder)) is using this data folder"
        NSLog("[store] %@; handing this launch to it", unavailableReason ?? "")
        return nil
      }
      usleep(100_000)
    }
    NSLog("[store] the instance holding this data folder never became the browser; quitting")
    if let holder { NSRunningApplication(processIdentifier: holder)?.activate() }
    exit(0)
  }

  @discardableResult
  public static func launchAtStartup() -> Bool {
    _ = setAppScheme(productName())
    guard let folder = dataFolder() else {
      unavailableReason = "no data folder"
      return false
    }
    do {
      guard let lock = try FolderLock.acquire(DataFolder(url: folder)) ?? waitForHolder(folder) else { return false }
      folderLock = lock
    } catch {
      unavailableReason = "couldn't lock the data folder: \(error)"
      NSLog("[store] %@; running on the JS store", unavailableReason ?? "")
      return false
    }
    if ProcessInfo.processInfo.environment["ARDIA_NATIVE_STORE"] == "0" {
      unavailableReason = "ARDIA_NATIVE_STORE=0"
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
      let store = Store(state: launch.state, memory: launch.memory, env: addressing, config: storeConfig, clock: clock)
      ownsWorkspace = activeScope == .everything
      let writer = PersistenceWriter(
        store: store, database: launch.database, folder: DataFolder(url: folder), persisted: launch.persisted, scope: activeScope,
        trouble: { message in NSLog("[store] %@", message) })
      shared = NativeStore(bridge: StoreBridge(store: store), writer: writer, launch: launch)
      NativeSettingsHandle.active = true
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeSettingsHandle.resolve = { NativeStore.settingsModel } } }
      NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        _ = NativeStore.shared?.writer.flush(timeout: 0.5)
      }
      return true
    } catch {
      unavailableReason = "\(error)"
      NSLog("[store] running on the JS store: %@", "\(error)")
      return false
    }
  }

  public func flush(timeout: TimeInterval) -> Bool { writer.flush(timeout: timeout) }
}
