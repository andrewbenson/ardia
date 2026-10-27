import Foundation
import SQLite3

final class SQLiteSnapshot {
  private var db: OpaquePointer?
  private let tempDir: URL

  init(copying source: URL, assumeCoarseTimes: Bool = false) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: source.path) else {
      throw ImportError.notFound("\(source.lastPathComponent) not found")
    }
    tempDir = fm.temporaryDirectory.appendingPathComponent("ardia-import-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let copy = tempDir.appendingPathComponent("db.sqlite")
    do {
      try Self.copyUnchanged(source, to: copy, assumeCoarseTimes: assumeCoarseTimes)
    } catch {
      try? fm.removeItem(at: tempDir)
      throw Self.copyFailure(source.lastPathComponent, error)
    }

    if sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
      sqlite3_close(db)
      db = nil
      let uri = "file:\(copy.path)?immutable=1"
      if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close(db)
        db = nil
        try? fm.removeItem(at: tempDir)
        throw ImportError.unreadable("Couldn't open \(source.lastPathComponent): \(message)")
      }
    }
    sqlite3_busy_timeout(db, 2000)
  }

  static let siblings = ["-wal", "-journal"]

  static func copyFailure(_ name: String, _ error: Error) -> ImportError {
    let cause = (error as? ImportError).map { "\($0)" } ?? error.localizedDescription
    return .unreadable("Couldn't copy \(name): \(cause)")
  }

  struct FileStamp: Equatable {
    var size: Int64
    var seconds: Int
    var nanoseconds: Int
  }

  static func stamp(_ path: String) -> FileStamp? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return FileStamp(size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
  }

  static func stamps(_ source: URL) -> [FileStamp?] {
    [stamp(source.path)] + siblings.map { stamp(source.path + $0) }
  }

  static func copyUnchanged(_ source: URL, to copy: URL, attempts: Int = 50, assumeCoarseTimes: Bool = false) throws {
    let fm = FileManager.default
    let second = URL(fileURLWithPath: copy.path + ".check")
    let copies = { (to: URL) throws in
      for path in [to.path] + siblings.map({ to.path + $0 }) { try? fm.removeItem(atPath: path) }
      try fm.copyItem(at: source, to: to)
      for suffix in siblings where fm.fileExists(atPath: source.path + suffix) {
        try fm.copyItem(at: URL(fileURLWithPath: source.path + suffix), to: URL(fileURLWithPath: to.path + suffix))
      }
    }
    let sameBytes = { () -> Bool in
      ([""] + siblings).allSatisfy { suffix in
        fm.contents(atPath: copy.path + suffix) == fm.contents(atPath: second.path + suffix)
      }
    }
    var failure: Error = ImportError.unreadable("\(source.lastPathComponent) kept changing while it was copied")
    defer { for path in [second.path] + siblings.map({ second.path + $0 }) { try? fm.removeItem(atPath: path) } }
    for attempt in 0..<attempts {
      if attempt > 0 { usleep(20_000) }
      let before = stamps(source)
      do {
        try copies(copy)
      } catch {
        failure = error
        continue
      }
      guard stamps(source) == before else {
        failure = ImportError.unreadable("\(source.lastPathComponent) kept changing while it was copied")
        continue
      }
      let coarse = assumeCoarseTimes || before.contains { $0 != nil && $0!.nanoseconds == 0 }
      if !coarse { return }
      do {
        try copies(second)
      } catch {
        failure = error
        continue
      }
      if stamps(source) == before && sameBytes() { return }
      failure = ImportError.unreadable("\(source.lastPathComponent) kept changing while it was copied")
    }
    throw failure
  }

  deinit {
    sqlite3_close(db)
    try? FileManager.default.removeItem(at: tempDir)
  }

  func tableExists(_ name: String) -> Bool {
    (try? scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", [.text(name)])) ?? 0 > 0
  }

  func scalar(_ sql: String, _ bindings: [Value] = []) throws -> Int64? {
    var result: Int64?
    try query(sql, bindings) { row in
      result = row.int(0)
      return false
    }
    return result
  }

  enum Value {
    case int(Int64)
    case text(String)
  }

  func query(_ sql: String, _ bindings: [Value] = [], _ body: (Row) throws -> Bool) throws {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw ImportError.unreadable(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, value) in bindings.enumerated() {
      switch value {
      case .int(let v): sqlite3_bind_int64(stmt, Int32(i + 1), v)
      case .text(let v): sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient)
      }
    }
    let row = Row(stmt: stmt!)
    while true {
      let rc = sqlite3_step(stmt)
      if rc == SQLITE_DONE { return }
      guard rc == SQLITE_ROW else { throw ImportError.unreadable(String(cString: sqlite3_errmsg(db))) }
      if try !body(row) { return }
    }
  }

  struct Row {
    let stmt: OpaquePointer
    private let columns: [String: Int32]

    init(stmt: OpaquePointer) {
      self.stmt = stmt
      var columns: [String: Int32] = [:]
      for i in 0..<sqlite3_column_count(stmt) {
        let name = String(cString: sqlite3_column_name(stmt, i))
        if columns[name] == nil { columns[name] = i }
      }
      self.columns = columns
    }

    func index(_ name: String) -> Int32? { columns[name] }

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func int(_ name: String) -> Int64? { index(name).flatMap { isNull($0) ? nil : int($0) } }

    func text(_ i: Int32) -> String? {
      guard let p = sqlite3_column_text(stmt, i) else { return nil }
      return String(cString: p)
    }
    func text(_ name: String) -> String? { index(name).flatMap { text($0) } }

    func blob(_ i: Int32) -> Data? {
      let count = Int(sqlite3_column_bytes(stmt, i))
      guard let p = sqlite3_column_blob(stmt, i) else { return count == 0 && !isNull(i) ? Data() : nil }
      return Data(bytes: p, count: count)
    }
    func blob(_ name: String) -> Data? { index(name).flatMap { blob($0) } }

    func blobPointer(_ i: Int32) -> UnsafeRawBufferPointer? {
      guard !isNull(i) else { return nil }
      let p = sqlite3_column_blob(stmt, i)
      let count = Int(sqlite3_column_bytes(stmt, i))
      return UnsafeRawBufferPointer(start: count > 0 ? p : nil, count: count)
    }

    func secret(_ name: String) -> SecretBytes? {
      index(name).flatMap { blobPointer($0) }.map { SecretBytes(copying: $0) }
    }

    func has(_ name: String) -> Bool { index(name) != nil }
  }
}
