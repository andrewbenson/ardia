import Foundation
import GRDB
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Synchronization
import Testing

@Suite struct WriterFlushTests {
  @Test func aRowFailureIsReportedEvenWhenTheShadowSucceeds() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try launch.database.pool.write { db in
      try db.execute(sql: "CREATE TRIGGER fail_settings BEFORE INSERT ON setting BEGIN SELECT RAISE(FAIL, 'injected row failure'); END")
    }
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    let result = String(describing: writer.flush(timeout: 5))
    #expect(result.hasPrefix("failed: rows:"))
    #expect(result.contains("injected row failure"))
    #expect(contents(folder.session) != nil)
    try launch.database.pool.write { db in try db.execute(sql: "DROP TRIGGER fail_settings") }
    #expect(String(describing: writer.flush(timeout: 5)) == "saved")
    #expect(try launch.database.load().settings?["appearance"] == "dark")
  }

  @Test func aShadowFailureIsReportedAndCanRecover() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let blocked = folder.url.appending(path: ".session.json.writing")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(String(describing: writer.flush(timeout: 5)).hasPrefix("failed: shadow export:"))
    #expect(try launch.database.load().settings?["appearance"] == "dark")
    try FileManager.default.removeItem(at: blocked)
    #expect(String(describing: writer.flush(timeout: 5)) == "saved")
    let shadow = try JSONValue.parse(Data(contentsOf: folder.session))
    #expect(shadow["settings"]?["appearance"] == "dark")
  }

  @Test func aBlockedQueueReportsTheDeadlineAndRecoversAfterRelease() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let release = DispatchSemaphore(value: 0)
    writer.queue.async { _ = release.wait(timeout: .now() + 5) }
    let result = String(describing: writer.flush(timeout: 0.01))
    release.signal()
    #expect(result == "timedOut")
    #expect(String(describing: writer.flush(timeout: 5)) == "saved")
  }

  @Test func anUnchangedDurableFlushStillCheckpointsTheWAL() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    _ = writer.flush(timeout: 5)
    try store.dispatch(Command("createWindow", [[:]]))
    writer.queue.sync { writer.flushRows() }
    let statements = Mutex<[String]>([])
    try launch.database.pool.writeWithoutTransaction { db in
      db.trace { event in statements.withLock { $0.append(event.description) } }
    }
    let count = writer.flushCount
    #expect(String(describing: writer.flush(timeout: 5)) == "saved")
    #expect(statements.withLock { $0.contains { $0.contains("wal_checkpoint(FULL)") } })
    #expect(writer.flushCount == count)
    try launch.database.pool.writeWithoutTransaction { db in db.trace(nil) }
  }

  @Test func aDurableCommitWritesItsShadowWithItsImmediateRows() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    writer.queue.sync {}
    #expect(try launch.database.load().settings?["appearance"] == "dark")
    let shadow = contents(folder.session).flatMap { try? JSONValue.parse($0) }
    #expect(shadow?["settings"]?["appearance"] == "dark")
  }
}
