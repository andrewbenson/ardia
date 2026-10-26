import Foundation
import SolaraModel
import SolaraStore
import Synchronization

public final class PersistenceWriter: Sendable {
  public static let rowDelay: TimeInterval = 0.25
  public static let shadowDelay: TimeInterval = 2
  public static let retryDelays: [TimeInterval] = [1, 5, 30]
  public static let keptErrors = 20
  public static let troubleAfter = 3

  struct Pending {
    var rows = false
    var rowsScheduled = false
    var shadow = false
    var shadowScheduled = false
    var flushes = 0
    var written: WorkspaceRows
    var settings: JSONObject?
    var downloads: [Download]
    var exportedSession: JSONValue?
    var exportedDownloads: JSONValue?
    var failedInARow = 0
  }

  let store: Store
  let database: SolaraDatabase
  let folder: DataFolder
  let queue = DispatchQueue(label: "solara.persistence", qos: .utility)
  let pending: Mutex<Pending>
  let failures = Mutex<[String]>([])
  let subscription: Mutex<Int?> = Mutex(nil)
  let clock: @Sendable () -> Double
  let trouble: @Sendable (String) -> Void

  public init(
    store: Store, database: SolaraDatabase, folder: DataFolder, persisted: PersistedState,
    clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
    trouble: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.store = store
    self.database = database
    self.folder = folder
    self.clock = clock
    self.trouble = trouble
    pending = Mutex(
      Pending(rows: true, rowsScheduled: true, written: persisted.workspace ?? WorkspaceRows(), settings: persisted.settings, downloads: persisted.downloads))
    let id = store.subscribe { [weak self] commit in self?.note(commit) }
    subscription.withLock { $0 = id }
    queue.asyncAfter(deadline: .now() + Self.rowDelay) { self.flushRows() }
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
    if rows == previous && settings == previousSettings && downloads == previousDownloads { return }
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
      succeeded()
    } catch {
      pending.withLock {
        $0.rows = true
        $0.rowsScheduled = true
      }
      failed("rows: \(error)") { self.flushRows() }
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
    let document = store.sessionDocument(of: state)
    let session = document.json()
    let downloads = ShadowExport.downloadsDocument(state)
    let (lastSession, lastDownloads) = pending.withLock { ($0.exportedSession, $0.exportedDownloads) }
    do {
      if session != lastSession {
        try Importer.writeDurably(Data(document.json(marker: marker).text().utf8), to: folder.session)
        pending.withLock { $0.exportedSession = session }
      }
      if downloads != lastDownloads {
        try Importer.writeDurably(ShadowExport.downloadsJSON(state, marker: marker), to: folder.downloads)
        pending.withLock { $0.exportedDownloads = downloads }
      }
      succeeded()
    } catch {
      pending.withLock {
        $0.shadow = true
        $0.shadowScheduled = true
      }
      failed("shadow export: \(error)") { self.writeShadow() }
    }
  }

  func succeeded() {
    pending.withLock { $0.failedInARow = 0 }
  }

  func failed(_ message: String, retry: @escaping @Sendable () -> Void) {
    failures.withLock {
      $0.append(message)
      if $0.count > Self.keptErrors { $0.removeFirst($0.count - Self.keptErrors) }
    }
    let attempt = pending.withLock { p -> Int in
      p.failedInARow += 1
      return p.failedInARow
    }
    if attempt >= Self.troubleAfter { trouble("persistence has failed \(attempt) times in a row; last: \(message)") }
    let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
    queue.asyncAfter(deadline: .now() + delay, execute: retry)
  }

  public func markShadowDirty() {
    pending.withLock { $0.shadow = true }
  }

  @discardableResult
  public func flush(timeout: TimeInterval = 0.5) -> Bool {
    let done = DispatchSemaphore(value: 0)
    queue.async {
      self.pending.withLock { $0.rows = true }
      self.flushRows()
      self.writeShadow()
      done.signal()
    }
    return done.wait(timeout: .now() + timeout) == .success
  }
}

public enum ShadowExport {
  public static func downloadsDocument(_ state: BrowserState) -> JSONValue {
    let downloads = state.downloads.filter { !$0.isPrivate }.map { JSONValue.object($0.persisted().json) }
    return ["version": 2, "downloads": .array(downloads)]
  }

  public static func downloadsJSON(_ state: BrowserState, marker: JSONValue) -> Data {
    var document = downloadsDocument(state).object ?? [:]
    document[Launcher.markerKey] = marker
    return Data(JSONValue.object(document).text().utf8)
  }
}
