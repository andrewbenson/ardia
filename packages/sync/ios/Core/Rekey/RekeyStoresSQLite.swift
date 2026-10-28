import CryptoKit
import Foundation
import SQLite3

extension RekeyStores {
  enum DatabaseKind: Sendable { case cookies, logins, webData }

  struct Column: Sendable {
    let table: String
    let column: String
    let check: Check
  }

  static let cookieColumns = [Column(table: "cookies", column: "encrypted_value", check: .cookie)]

  static let loginColumns = [
    Column(table: "logins", column: "password_value", check: .utf8),
    Column(table: "password_notes", column: "value", check: .utf8),
  ]

  static let webDataColumns = [
    Column(table: "credit_cards", column: "card_number_encrypted", check: .digits),
    Column(table: "local_ibans", column: "value_encrypted", check: .iban),
    Column(table: "local_stored_cvc", column: "value_encrypted", check: .digits),
    Column(table: "server_stored_cvc", column: "value_encrypted", check: .digits),
    Column(table: "generic_payment_instruments", column: "serialized_value_encrypted", check: .proto),
    Column(table: "payment_instrument_creation_options", column: "serialized_value_encrypted", check: .proto),
    Column(table: "token_service", column: "encrypted_token", check: .utf8),
    Column(table: "keywords", column: "url_hash", check: .keywordHash),
    Column(table: "autofill_ai_attributes", column: "value_encrypted", check: .utf8),
  ]

  static func columns(for kind: DatabaseKind) -> [Column] {
    switch kind {
    case .cookies: cookieColumns
    case .logins: loginColumns
    case .webData: webDataColumns
    }
  }

  static let sidecarSuffixes = ["-wal", "-journal", "-shm"]
  static let unlistedBinaryMinimum = 32

  final class Database {
    private(set) var handle: OpaquePointer?
    let path: String

    enum Mode { case checkpoint, immutable, create }

    init(_ url: URL, mode: Mode) throws {
      path = url.path
      var flags: Int32 = SQLITE_OPEN_NOMUTEX
      var name = url.path
      switch mode {
      case .checkpoint: flags |= SQLITE_OPEN_READWRITE
      case .create: flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
      case .immutable:
        flags |= SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        name = url.standardizedFileURL.absoluteString + "?immutable=1"
      }
      var db: OpaquePointer?
      let status = sqlite3_open_v2(name, &db, flags, nil)
      handle = db
      guard status == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close_v2(db)
        handle = nil
        throw RekeyStoresError.sqlite(path, message)
      }
      sqlite3_busy_timeout(db, 0)
    }

    deinit { if handle != nil { sqlite3_close_v2(handle) } }

    func close() throws {
      guard let db = handle else { return }
      handle = nil
      guard sqlite3_close(db) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(db))
        sqlite3_close_v2(db)
        throw RekeyStoresError.sqlite(path, "close: \(message)")
      }
    }

    var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    func run(_ sql: String) throws {
      let stmt = try statement(sql)
      while try stmt.step() {}
    }

    func statement(_ sql: String) throws -> Statement {
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
        throw RekeyStoresError.sqlite(path, "\(sql): \(lastError)")
      }
      return Statement(stmt, db: self)
    }

    func strings(_ sql: String) throws -> [String] {
      let stmt = try statement(sql)
      var out: [String] = []
      while try stmt.step() { out.append(stmt.text(0) ?? "") }
      return out
    }

    func tables() throws -> [String] {
      try strings("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND (sql IS NULL OR sql NOT LIKE 'CREATE VIRTUAL TABLE%') ORDER BY name")
    }

    func schema() throws -> [String] {
      try strings("SELECT type || ' ' || name || ' ' || coalesce(sql, '') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name")
    }

    func columns(of table: String) throws -> [String] {
      let stmt = try statement("PRAGMA table_info(\(quote(table)))")
      var out: [String] = []
      while try stmt.step() { out.append(stmt.text(1) ?? "") }
      return out
    }

    func has(_ table: String, _ column: String) throws -> Bool {
      try columns(of: table).contains(column)
    }

    func integrityOK() throws -> Bool {
      try strings("PRAGMA integrity_check") == ["ok"]
    }
  }

  final class Statement {
    let stmt: OpaquePointer
    unowned let db: Database

    init(_ stmt: OpaquePointer, db: Database) {
      self.stmt = stmt
      self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    func step() throws -> Bool {
      switch sqlite3_step(stmt) {
      case SQLITE_ROW: return true
      case SQLITE_DONE: return false
      default: throw RekeyStoresError.sqlite(db.path, db.lastError)
      }
    }

    func reset() {
      sqlite3_reset(stmt)
      sqlite3_clear_bindings(stmt)
    }

    var columnCount: Int32 { sqlite3_column_count(stmt) }

    func name(_ i: Int32) -> String { sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "" }

    func type(_ i: Int32) -> Int32 { sqlite3_column_type(stmt, i) }

    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }

    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }

    func text(_ i: Int32) -> String? {
      guard let p = sqlite3_column_text(stmt, i) else { return nil }
      return String(cString: p)
    }

    func value(_ i: Int32) -> Cell? {
      let type = sqlite3_column_type(stmt, i)
      guard type == SQLITE_BLOB || type == SQLITE_TEXT else { return nil }
      let count = Int(sqlite3_column_bytes(stmt, i))
      let base: UnsafeRawPointer? = type == SQLITE_BLOB ? sqlite3_column_blob(stmt, i) : sqlite3_column_text(stmt, i).map { UnsafeRawPointer($0) }
      let bytes = count > 0 && base != nil ? Data(bytes: base!, count: count) : Data()
      return Cell(bytes: bytes, isText: type == SQLITE_TEXT)
    }

    func bind(_ cell: Cell, at i: Int32) {
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      _ = cell.bytes.withUnsafeBytes { raw in
        if cell.isText, let base = raw.baseAddress, raw.count > 0 {
          sqlite3_bind_text(stmt, i, base.assumingMemoryBound(to: CChar.self), Int32(raw.count), transient)
        } else if cell.isText {
          sqlite3_bind_text(stmt, i, "", 0, transient)
        } else if let base = raw.baseAddress, raw.count > 0 {
          sqlite3_bind_blob(stmt, i, base, Int32(raw.count), transient)
        } else {
          sqlite3_bind_zeroblob(stmt, i, 0)
        }
      }
    }

    func bind(_ value: Int64, at i: Int32) { sqlite3_bind_int64(stmt, i, value) }
  }

  struct Cell: Equatable {
    let bytes: Data
    let isText: Bool
  }

  static func quote(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  static func literal(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
  }

  static func encryptedFilter(_ column: String) -> String {
    "substr(CAST(\(column) AS BLOB), 1, 3) = X'763130'"
  }

  static func kind(of db: Database) throws -> DatabaseKind? {
    let tables = Set(try db.tables())
    if tables.contains("cookies"), try db.has("cookies", "encrypted_value") { return .cookies }
    if tables.contains("logins"), try db.has("logins", "password_value") { return .logins }
    for column in webDataColumns where tables.contains(column.table) {
      if try db.has(column.table, column.column) { return .webData }
    }
    return nil
  }

  static func cookieVersion(_ db: Database) throws -> Int {
    guard try db.tables().contains("meta") else { return 0 }
    let stmt = try db.statement("SELECT value FROM meta WHERE key='version'")
    return try stmt.step() ? Int(stmt.text(0) ?? "") ?? 0 : 0
  }

  static func usesHostHash(_ column: Column, version: Int) -> Bool { column.check == .cookie && version >= 24 }

  struct Row {
    let rowid: Int64
    let cell: Cell?
    let hostKey: Data?
  }

  static func rows(_ db: Database, _ column: Column, hostKeys: Bool) throws -> [Row] {
    let c = quote(column.column)
    let host = hostKeys ? ", CAST(host_key AS BLOB)" : ""
    let stmt = try db.statement("SELECT rowid, \(c)\(host) FROM \(quote(column.table)) WHERE " + encryptedFilter(c))
    var out: [Row] = []
    while try stmt.step() {
      out.append(Row(rowid: stmt.int64(0), cell: stmt.value(1), hostKey: hostKeys ? (stmt.value(2)?.bytes ?? Data()) : nil))
    }
    return out
  }

  static func presentColumns(_ db: Database, kind: DatabaseKind) throws -> [Column] {
    let tables = Set(try db.tables())
    return try columns(for: kind).filter { tables.contains($0.table) ? try db.has($0.table, $0.column) : false }
  }

  static func checkpoint(_ url: URL) throws {
    let db = try Database(url, mode: .checkpoint)
    _ = try db.strings("SELECT count(*) FROM sqlite_master")
    if try db.strings("PRAGMA journal_mode").first?.lowercased() == "wal" {
      _ = try db.strings("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    try db.close()
    for suffix in ["-wal", "-journal"] {
      let side = URL(fileURLWithPath: url.path + suffix)
      if let size = fileSize(side), size > 0 { throw RekeyStoresError.notQuiescent(side.path) }
    }
  }

  static func removeWithSidecars(_ url: URL) throws {
    for item in [url] + sidecarSuffixes.map({ URL(fileURLWithPath: url.path + $0) }) where fileSize(item) != nil {
      do { try FileManager.default.removeItem(at: item) } catch { throw RekeyStoresError.io(item.path, "can't remove") }
    }
  }

  struct Staged {
    var rekeyed = 0
    var untouched = 0
    var dropped = 0
  }

  static func stageDatabase(live: URL, staged: URL, kind: DatabaseKind, from old: Key, to new: Key, label: String) throws -> Staged {
    try checkpoint(live)
    try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
    let work = URL(fileURLWithPath: staged.path + ".rekey-work")
    try removeWithSidecars(work)
    try removeWithSidecars(staged)
    defer { try? removeWithSidecars(work) }

    let source = try Database(live, mode: .immutable)
    let dest = try Database(work, mode: .create)
    guard let backup = sqlite3_backup_init(dest.handle, "main", source.handle, "main") else {
      throw RekeyStoresError.sqlite(work.path, "backup: \(dest.lastError)")
    }
    let stepped = sqlite3_backup_step(backup, -1)
    let finished = sqlite3_backup_finish(backup)
    guard stepped == SQLITE_DONE, finished == SQLITE_OK else { throw RekeyStoresError.sqlite(work.path, "backup: \(dest.lastError)") }
    try source.close()

    guard try dest.strings("PRAGMA journal_mode=DELETE").first?.lowercased() == "delete" else {
      throw RekeyStoresError.sqlite(work.path, "couldn't leave WAL mode")
    }
    var counts = Staged()
    try dest.run("BEGIN IMMEDIATE")
    do {
      let version = kind == .cookies ? try cookieVersion(dest) : 0
      for column in try presentColumns(dest, kind: kind) {
        let table = quote(column.table)
        let update = try dest.statement("UPDATE \(table) SET \(quote(column.column)) = ?1 WHERE rowid = ?2")
        let drop = try dest.statement("DELETE FROM \(table) WHERE rowid = ?1")
        for row in try rows(dest, column, hostKeys: usesHostHash(column, version: version)) {
          guard let cell = row.cell else { continue }
          let outcome = cell.bytes.withUnsafeBytes {
            rekey($0, from: old, to: new, check: column.check, hostKey: row.hostKey)
          }
          switch outcome {
          case .notEncrypted: continue
          case .otherKey: counts.untouched += 1
          case .implausible:
            guard column.check == .cookie else {
              throw RekeyStoresError.implausible("\(label): \(column.table).\(column.column) rowid \(row.rowid)")
            }
            drop.reset()
            drop.bind(row.rowid, at: 1)
            _ = try drop.step()
            guard sqlite3_changes(dest.handle) == 1 else { throw RekeyStoresError.sqlite(work.path, "drop of rowid \(row.rowid) changed nothing") }
            counts.dropped += 1
          case .rekeyed(let fresh, _):
            update.reset()
            update.bind(Cell(bytes: fresh, isText: cell.isText), at: 1)
            update.bind(row.rowid, at: 2)
            _ = try update.step()
            guard sqlite3_changes(dest.handle) == 1 else { throw RekeyStoresError.sqlite(work.path, "update of rowid \(row.rowid) changed nothing") }
            counts.rekeyed += 1
          }
        }
      }
      try dest.run("COMMIT")
    } catch {
      try? dest.run("ROLLBACK")
      throw error
    }
    try dest.run("VACUUM INTO \(literal(staged.path))")
    try dest.close()

    let result = try Database(staged, mode: .checkpoint)
    guard try result.strings("PRAGMA journal_mode=DELETE").first?.lowercased() == "delete" else {
      throw RekeyStoresError.sqlite(staged.path, "couldn't leave WAL mode")
    }
    try result.close()
    try clearStagedSidecars(staged)
    return counts
  }

  static func clearStagedSidecars(_ staged: URL) throws {
    for suffix in sidecarSuffixes {
      let side = URL(fileURLWithPath: staged.path + suffix)
      guard let size = fileSize(side) else { continue }
      if size > 0 && suffix != "-shm" { throw RekeyStoresError.stagedSidecarRemains(side.path) }
      do { try FileManager.default.removeItem(at: side) } catch { throw RekeyStoresError.io(side.path, "can't remove") }
    }
  }

  struct Fingerprint {
    var rows: [Data: Int] = [:]
    var decrypted = 0
    var dropped = 0
  }

  enum Side { case original, candidate }

  static func fingerprint(_ db: Database, table: String, listed: [String: Check], hostHashes: Bool, key: Key, side: Side, label: String) throws -> Fingerprint {
    var out = Fingerprint()
    let stmt = try db.statement("SELECT * FROM \(quote(table))")
    let count = stmt.columnCount
    let names = (0..<count).map { stmt.name($0) }
    let hostIndex = hostHashes ? names.firstIndex(of: "host_key").map(Int32.init) : nil
    while try stmt.step() {
      var hasher = SHA256()
      var skip = false
      for i in 0..<count {
        let type = stmt.type(i)
        var tag = UInt8(truncatingIfNeeded: type)
        var payload: Data
        switch type {
        case SQLITE_INTEGER: payload = withUnsafeBytes(of: stmt.int64(i).bigEndian) { Data($0) }
        case SQLITE_FLOAT: payload = withUnsafeBytes(of: stmt.double(i).bitPattern.bigEndian) { Data($0) }
        case SQLITE_NULL: payload = Data()
        default: payload = stmt.value(i)?.bytes ?? Data()
        }
        if let check = listed[names[Int(i)]], looksEncrypted(payload),
           let plain = payload.withUnsafeBytes({ decrypt($0, key: key) }) {
          let host = hostIndex.flatMap { stmt.value($0)?.bytes }
          let plausible = check.accepts(plain, hostKey: check == .cookie ? host : nil)
          let digest = plain.digest()
          plain.wipe()
          let place = "\(label): \(table).\(names[Int(i)])"
          if plausible {
            tag = 0xD0 | tag
            payload = digest
            out.decrypted += 1
          } else if side == .original {
            guard check == .cookie else { throw RekeyStoresError.implausible(place) }
            skip = true
            break
          }
        }
        hasher.update(data: [tag])
        hasher.update(data: withUnsafeBytes(of: UInt64(payload.count).bigEndian) { Data($0) })
        hasher.update(data: payload)
      }
      if skip {
        out.dropped += 1
        continue
      }
      out.rows[Data(hasher.finalize()), default: 0] += 1
    }
    return out
  }

  static func compareDatabases(original: URL, candidate: URL, kind: DatabaseKind, from old: Key, to new: Key, label: String) throws -> (rekeyed: Int, dropped: Int) {
    for suffix in ["-wal", "-journal"] {
      if let size = fileSize(URL(fileURLWithPath: candidate.path + suffix)), size > 0 {
        throw RekeyStoresError.stagedSidecarRemains(candidate.path + suffix)
      }
    }
    let before = try Database(original, mode: .immutable)
    let after = try Database(candidate, mode: .immutable)
    defer {
      try? before.close()
      try? after.close()
    }
    guard try after.integrityOK() else { throw RekeyStoresError.integrity(label) }
    guard try before.schema() == after.schema() else { throw RekeyStoresError.mismatch("\(label): schema differs") }
    let listed = try presentColumns(before, kind: kind)
    let version = kind == .cookies ? try cookieVersion(before) : 0
    var rekeyed = 0
    var dropped = 0
    for table in try before.tables() {
      var checks: [String: Check] = [:]
      for column in listed where column.table == table { checks[column.column] = column.check }
      let hostHashes = checks.values.contains(.cookie) && version >= 24
      let was = try fingerprint(before, table: table, listed: checks, hostHashes: hostHashes, key: old, side: .original, label: label)
      let now = try fingerprint(after, table: table, listed: checks, hostHashes: hostHashes, key: new, side: .candidate, label: label)
      guard was.rows == now.rows else { throw RekeyStoresError.mismatch("\(label): \(table)") }
      rekeyed += now.decrypted
      dropped += was.dropped
    }
    let stale = try tally(after, kind: kind, key: old, unlessOpensUnder: new, label: label)
    if let place = stale.places.first { throw RekeyStoresError.sweepHit(place) }
    if let hit = try sweep(after, key: old, skipping: listed).first { throw RekeyStoresError.sweepHit("\(label): \(hit)") }
    return (rekeyed, dropped)
  }

  struct Tally {
    var plausible = 0
    var places: [String] = []
    var implausibleCookies = 0
    var implausible: [String] = []
  }

  static func opens(_ raw: UnsafeRawBufferPointer, key: Key, check: Check, hostKey: Data?) -> Bool? {
    guard let plain = decrypt(raw, key: key) else { return nil }
    defer { plain.wipe() }
    return check.accepts(plain, hostKey: hostKey)
  }

  static func tally(_ db: Database, kind: DatabaseKind, key: Key, unlessOpensUnder other: Key? = nil, label: String) throws -> Tally {
    var out = Tally()
    let version = kind == .cookies ? try cookieVersion(db) : 0
    for column in try presentColumns(db, kind: kind) {
      for row in try rows(db, column, hostKeys: usesHostHash(column, version: version)) {
        guard let cell = row.cell else { continue }
        let verdict = cell.bytes.withUnsafeBytes { raw -> Bool? in
          guard let verdict = opens(raw, key: key, check: column.check, hostKey: row.hostKey) else { return nil }
          if let other, verdict, opens(raw, key: other, check: column.check, hostKey: row.hostKey) == true { return nil }
          return verdict
        }
        let place = "\(label): \(column.table).\(column.column) rowid \(row.rowid)"
        switch verdict {
        case true?:
          out.plausible += 1
          out.places.append(place)
        case false? where column.check == .cookie: out.implausibleCookies += 1
        case false?: out.implausible.append(place)
        case nil: continue
        }
      }
    }
    return out
  }

  static func verifyDatabase(_ file: URL, newKey: Key, oldKey: Key, expected: Int) throws -> Bool {
    for suffix in ["-wal", "-journal"] {
      if let size = fileSize(URL(fileURLWithPath: file.path + suffix)), size > 0 { return false }
    }
    let db = try Database(file, mode: .immutable)
    defer { try? db.close() }
    guard try db.integrityOK(), let kind = try kind(of: db) else { return false }
    let fresh = try tally(db, kind: kind, key: newKey, label: "")
    let stale = try tally(db, kind: kind, key: oldKey, unlessOpensUnder: newKey, label: "")
    guard fresh.plausible == expected, stale.plausible == 0 else { return false }
    return try sweep(db, key: oldKey, skipping: try presentColumns(db, kind: kind)).isEmpty
  }

  static func sweep(_ db: Database, key: Key, skipping: [Column] = [], binaryMinimum: Int? = nil) throws -> [String] {
    let skip = Set(skipping.map { "\($0.table)\u{0}\($0.column)" })
    var hits: [String] = []
    for table in try db.tables() {
      for column in try db.columns(of: table) where !skip.contains("\(table)\u{0}\(column)") {
        let c = quote(column)
        let stmt = try db.statement("SELECT \(c) FROM \(quote(table)) WHERE " + encryptedFilter(c))
        var count = 0
        while try stmt.step() {
          guard let cell = stmt.value(0) else { continue }
          let hit = cell.bytes.withUnsafeBytes { raw -> Bool in
            guard let plain = decrypt(raw, key: key) else { return false }
            defer { plain.wipe() }
            if let binaryMinimum, plain.count >= binaryMinimum { return true }
            return plain.isStrictUTF8
          }
          if hit { count += 1 }
        }
        if count > 0 { hits.append("\(table).\(column) (\(count))") }
      }
    }
    return hits
  }
}
