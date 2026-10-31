import Foundation
import SQLite3
import XCTest
@testable import SolaraLegacyImportCore

final class SnapshotTornTests: XCTestCase {
  func exec(_ db: OpaquePointer?, _ sql: String) {
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
  }

  func snapshotsWhileCommitting(assumeCoarseTimes: Bool) throws -> (snapshots: Int, torn: [String], unreadable: Int) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("torn-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("Login Data")
    var writer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &writer), SQLITE_OK)
    exec(writer, "PRAGMA page_size=1024; PRAGMA journal_mode=TRUNCATE; PRAGMA locking_mode=EXCLUSIVE; CREATE TABLE t(g INTEGER, payload BLOB);")
    let rows = 48
    func generation(_ g: Int) {
      exec(writer, "BEGIN IMMEDIATE; DELETE FROM t;")
      for _ in 0..<rows { exec(writer, "INSERT INTO t VALUES(\(g), randomblob(900));") }
      exec(writer, "COMMIT;")
    }
    generation(0)
    let stop = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let committing = Thread {
      var g = 1
      while stop.wait(timeout: .now()) == .timedOut {
        generation(g)
        g += 1
        usleep(15_000)
      }
      done.signal()
    }
    committing.start()
    var torn: [String] = []
    var unreadable = 0
    var snapshots = 0
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      let copy: SQLiteSnapshot
      do {
        copy = try SQLiteSnapshot(copying: file, assumeCoarseTimes: assumeCoarseTimes)
      } catch {
        unreadable += 1
        continue
      }
      snapshots += 1
      do {
        var count: Int64 = -1
        var generations: Int64 = -1
        try copy.query("SELECT count(*), count(DISTINCT g) FROM t") { row in
          count = row.int(0)
          generations = row.int(1)
          return false
        }
        if count != Int64(rows) || generations != 1 { torn.append("\(count) rows over \(generations) generations") }
      } catch {
        torn.append("\(error)")
      }
    }
    stop.signal()
    done.wait()
    sqlite3_close(writer)
    return (snapshots, torn, unreadable)
  }

  func testASnapshotTakenWhileChromeCommitsIsNeverHalfApplied() throws {
    let r = try snapshotsWhileCommitting(assumeCoarseTimes: false)
    XCTAssertGreaterThan(r.snapshots, 20, "control: enough snapshots were taken (\(r.unreadable) gave up)")
    XCTAssertEqual(r.torn, [], "\(r.torn.count) of \(r.snapshots) snapshots were half-applied")
  }

  func testOnAVolumeWithWholeSecondTimesTwoCopiesMustMatch() throws {
    let r = try snapshotsWhileCommitting(assumeCoarseTimes: true)
    XCTAssertGreaterThan(r.snapshots, 20, "control: enough snapshots were taken (\(r.unreadable) gave up)")
    XCTAssertEqual(r.torn, [], "\(r.torn.count) of \(r.snapshots) snapshots were half-applied")
  }

  func testACopyFailureNamesItsCause() {
    let changing = SQLiteSnapshot.copyFailure("Login Data", ImportError.unreadable("Login Data kept changing while it was copied"))
    XCTAssertEqual("\(changing)", "Couldn't copy Login Data: Login Data kept changing while it was copied")
    let io = SQLiteSnapshot.copyFailure("Login Data", CocoaError(.fileReadNoPermission))
    XCTAssertFalse("\(io)".contains("ImportError"))
  }
}
