import AppKit
import Foundation
internal import SolaraBridgeCore
internal import SolaraModel
internal import SolaraOmnibox
internal import SolaraPersistence
internal import SolaraStore

struct OmniboxAddressing: WebAddressing {
  func resolveInput(_ input: String, searchUrlPrefix: String) -> String {
    SolaraOmnibox.resolveInput(input, search: searchUrlPrefix)
  }

  func searchUrlPrefix(_ settings: Settings) -> String {
    SolaraOmnibox.searchUrlPrefix(settings)
  }

  func parseURL(_ url: String) -> ParsedURL? {
    guard let parsed = WhatwgURL(url) else { return nil }
    return ParsedURL(protocol: parsed.protocol, host: parsed.host, hostname: parsed.hostname)
  }
}

public final class NativeStore: Sendable {
  static let scope = PersistenceScope.settingsAndDownloads

  nonisolated(unsafe) public private(set) static var shared: NativeStore?
  nonisolated(unsafe) public private(set) static var unavailableReason: String?

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

  @discardableResult
  public static func launchAtStartup() -> Bool {
    _ = setAppScheme(productName())
    if ProcessInfo.processInfo.environment["ARDIA_NATIVE_STORE"] == "0" {
      unavailableReason = "ARDIA_NATIVE_STORE=0"
      return false
    }
    guard let folder = dataFolder() else {
      unavailableReason = "no data folder"
      return false
    }
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    let now = Date()
    let clock: @Sendable () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }
    let memory = StoreMemory(ids: IdSource.random(now: clock()))
    let addressing = OmniboxAddressing()
    let context = LoadContext(env: addressing, memory: memory, now: clock())
    do {
      let launch = try Launcher.open(DataFolder(url: folder), appVersion: version, now: now, context: context, scope: scope)
      for note in launch.report.notes { NSLog("[store] %@", note) }
      let store = Store(state: launch.state, memory: launch.memory, env: addressing, clock: clock)
      let writer = PersistenceWriter(
        store: store, database: launch.database, folder: DataFolder(url: folder), persisted: launch.persisted, scope: scope,
        trouble: { message in NSLog("[store] %@", message) })
      shared = NativeStore(bridge: StoreBridge(store: store), writer: writer, launch: launch)
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
