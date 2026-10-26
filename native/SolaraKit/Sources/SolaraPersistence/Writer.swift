import Foundation
import SolaraModel
import SolaraStore
import Synchronization

public final class PersistenceWriter: Sendable {
  public static let rowDelay: TimeInterval = 0.25
  public static let shadowDelay: TimeInterval = 2

  struct Pending {
    var rows = false
    var rowsScheduled = false
    var shadow = false
    var shadowScheduled = false
    var flushes = 0
    var written: WorkspaceRows
    var settings: JSONObject?
    var downloads: [Download]
    var exportedSession: String?
    var exportedDownloads: String?
  }

  let store: Store
  let database: SolaraDatabase
  let folder: DataFolder
  let queue = DispatchQueue(label: "solara.persistence", qos: .utility)
  let pending: Mutex<Pending>
  let failures = Mutex<[String]>([])
  let subscription: Mutex<Int?> = Mutex(nil)
  let clock: @Sendable () -> Double

  public init(
    store: Store, database: SolaraDatabase, folder: DataFolder, rows: WorkspaceRows, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }
  ) {
    self.store = store
    self.database = database
    self.folder = folder
    self.clock = clock
    let state = store.state
    pending = Mutex(
      Pending(written: rows, settings: state.settings.values, downloads: state.downloads.filter { !$0.isPrivate }.map { $0.persisted() }))
    let id = store.subscribe { [weak self] commit in self?.note(commit) }
    subscription.withLock { $0 = id }
  }

  deinit {
    if let id = subscription.withLock({ $0 }) { store.unsubscribe(id) }
  }

  public var errors: [String] { failures.withLock { $0 } }
  public var flushCount: Int { pending.withLock { $0.flushes } }

  func note(_ commit: Commit) {
    guard !commit.changes.isEmpty else { return }
    let (scheduleRows, scheduleShadow) = pending.withLock { p -> (Bool, Bool) in
      p.rows = true
      p.shadow = true
      let rows = !p.rowsScheduled
      if rows { p.rowsScheduled = true }
      let shadow = !p.shadowScheduled
      if shadow { p.shadowScheduled = true }
      return (rows, shadow)
    }
    if commit.durable {
      queue.async { self.flushRows() }
    } else if scheduleRows {
      queue.asyncAfter(deadline: .now() + Self.rowDelay) { self.flushRows() }
    }
    if scheduleShadow { queue.asyncAfter(deadline: .now() + Self.shadowDelay) { self.writeShadow() } }
  }

  func flushRows() {
    let dirty = pending.withLock { p -> Bool in
      defer {
        p.rows = false
        p.rowsScheduled = false
      }
      return p.rows
    }
    guard dirty else { return }
    let (rev, state) = store.snapshot
    let rows = WorkspaceRows(store.sessionDocument(of: state))
    let settings = state.settings.values
    let downloads = state.downloads.filter { !$0.isPrivate }.map { $0.persisted() }
    let (previous, previousSettings, previousDownloads) = pending.withLock { ($0.written, $0.settings, $0.downloads) }
    do {
      try database.pool.write { db in
        try Rows.writeWorkspace(db, rows, previous: previous)
        if settings != previousSettings { try Rows.writeSettings(db, settings) }
        if downloads != previousDownloads { try Rows.writeDownloads(db, downloads) }
        try Rows.setMeta(db, "rev", String(rev))
      }
      pending.withLock {
        $0.written = rows
        $0.settings = settings
        $0.downloads = downloads
        $0.flushes += 1
      }
    } catch {
      pending.withLock { $0.rows = true }
      failures.withLock { $0.append("rows: \(error)") }
    }
  }

  func writeShadow() {
    let dirty = pending.withLock { p -> Bool in
      defer {
        p.shadow = false
        p.shadowScheduled = false
      }
      return p.shadow
    }
    guard dirty else { return }
    let (rev, state) = store.snapshot
    let marker: JSONValue = ["rev": JSONValue(rev), "at": JSONValue(clock().rounded())]
    let session = store.sessionDocument(of: state).json(marker: marker).text()
    let downloads = String(decoding: ShadowExport.downloadsJSON(state, marker: marker), as: UTF8.self)
    let (lastSession, lastDownloads) = pending.withLock { ($0.exportedSession, $0.exportedDownloads) }
    do {
      if Self.withoutMarker(session) != lastSession.map(Self.withoutMarker) {
        try Data(session.utf8).write(to: folder.session, options: .atomic)
        pending.withLock { $0.exportedSession = session }
      }
      if Self.withoutMarker(downloads) != lastDownloads.map(Self.withoutMarker) {
        try Data(downloads.utf8).write(to: folder.downloads, options: .atomic)
        pending.withLock { $0.exportedDownloads = downloads }
      }
    } catch {
      pending.withLock { $0.shadow = true }
      failures.withLock { $0.append("shadow export: \(error)") }
    }
  }

  static func withoutMarker(_ text: String) -> String {
    guard var object = try? JSONValue.parse(text).object else { return text }
    object.removeValue(forKey: Launcher.markerKey)
    return JSONValue.object(object).text()
  }

  public func markShadowDirty() {
    pending.withLock { $0.shadow = true }
  }

  @discardableResult
  public func flush(timeout: TimeInterval = 0.5) -> Bool {
    let done = DispatchSemaphore(value: 0)
    queue.async {
      self.pending.withLock {
        $0.rows = true
        $0.shadow = $0.shadow || $0.exportedSession == nil
      }
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
