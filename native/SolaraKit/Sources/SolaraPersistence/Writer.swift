import Foundation
import SolaraModel
import SolaraStore
import Synchronization

public final class PersistenceWriter: Sendable {
  public static let rowDelay: TimeInterval = 0.25
  public static let shadowDelay: TimeInterval = 2

  struct Pending {
    var settings = false
    var downloads = false
    var rowsScheduled = false
    var shadowDownloads = false
    var shadowScheduled = false
    var flushes = 0
  }

  let store: Store
  let database: SolaraDatabase
  let folder: DataFolder
  let queue = DispatchQueue(label: "solara.persistence", qos: .utility)
  let pending = Mutex(Pending())
  let failures = Mutex<[String]>([])
  let subscription: Mutex<Int?> = Mutex(nil)
  let clock: @Sendable () -> Double

  public init(store: Store, database: SolaraDatabase, folder: DataFolder, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
    self.store = store
    self.database = database
    self.folder = folder
    self.clock = clock
    let id = store.subscribe { [weak self] commit in self?.note(commit) }
    subscription.withLock { $0 = id }
  }

  deinit {
    if let id = subscription.withLock({ $0 }) { store.unsubscribe(id) }
  }

  public var errors: [String] { failures.withLock { $0 } }
  public var flushCount: Int { pending.withLock { $0.flushes } }

  func note(_ commit: Commit) {
    let changes = commit.changes
    guard !changes.isEmpty else { return }
    let (scheduleRows, scheduleShadow) = pending.withLock { p -> (Bool, Bool) in
      if !changes.settingsChanged.isEmpty || !changes.settingsRemoved.isEmpty { p.settings = true }
      if changes.downloads {
        p.downloads = true
        p.shadowDownloads = true
      }
      let rows = !p.rowsScheduled && (p.settings || p.downloads)
      if rows { p.rowsScheduled = true }
      let shadow = !p.shadowScheduled && p.shadowDownloads
      if shadow { p.shadowScheduled = true }
      return (rows, shadow)
    }
    if commit.durable {
      queue.async { self.flushRows() }
    } else if scheduleRows {
      queue.asyncAfter(deadline: .now() + Self.rowDelay) { self.flushRows() }
    }
    if scheduleShadow {
      queue.asyncAfter(deadline: .now() + Self.shadowDelay) { self.writeShadow() }
    }
  }

  func flushRows() {
    let (settings, downloads) = pending.withLock { p -> (Bool, Bool) in
      defer {
        p.settings = false
        p.downloads = false
        p.rowsScheduled = false
      }
      return (p.settings, p.downloads)
    }
    guard settings || downloads else { return }
    let (rev, state) = store.snapshot
    do {
      try database.pool.write { db in
        if settings { try Rows.writeSettings(db, state.settings.values) }
        if downloads { try Rows.writeDownloads(db, state.downloads.filter { !$0.isPrivate }) }
        try Rows.setMeta(db, "rev", String(rev))
      }
      pending.withLock { $0.flushes += 1 }
    } catch {
      pending.withLock {
        $0.settings = $0.settings || settings
        $0.downloads = $0.downloads || downloads
      }
      failures.withLock { $0.append("rows: \(error)") }
    }
  }

  func writeShadow() {
    let dirty = pending.withLock { p -> Bool in
      defer {
        p.shadowDownloads = false
        p.shadowScheduled = false
      }
      return p.shadowDownloads
    }
    guard dirty else { return }
    let (rev, state) = store.snapshot
    do {
      try ShadowExport.downloadsJSON(state, marker: marker(rev)).write(to: folder.downloads, options: .atomic)
    } catch {
      pending.withLock { $0.shadowDownloads = true }
      failures.withLock { $0.append("downloads.json: \(error)") }
    }
  }

  func marker(_ rev: Int) -> JSONValue {
    ["rev": JSONValue(rev), "at": JSONValue(clock().rounded())]
  }

  @discardableResult
  public func flush(timeout: TimeInterval = 0.5) -> Bool {
    let done = DispatchSemaphore(value: 0)
    queue.async {
      self.flushRows()
      self.writeShadow()
      done.signal()
    }
    return done.wait(timeout: .now() + timeout) == .success
  }
}

public enum ShadowExport {
  public static func downloadsJSON(_ state: BrowserState, marker: JSONValue) -> Data {
    let downloads = state.downloads.filter { !$0.isPrivate }.map { JSONValue.object($0.persisted().json) }
    let document: JSONValue = ["version": 2, "downloads": .array(downloads), "nativeExport": marker]
    return Data(document.text().utf8)
  }
}
