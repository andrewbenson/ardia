import Foundation

public enum RekeyStoresError: Error, Equatable, CustomStringConvertible {
  case badSecret
  case sameKey
  case notQuiescent(String)
  case stagedSidecarRemains(String)
  case sqlite(String, String)
  case io(String, String)
  case implausible(String)
  case integrity(String)
  case mismatch(String)
  case sweepHit(String)

  public var description: String {
    switch self {
    case .badSecret: "a Safe Storage secret is empty or unusable"
    case .sameKey: "the old and new Safe Storage secrets derive the same key"
    case .notQuiescent(let path): "a live journal survived a checkpoint: \(path)"
    case .stagedSidecarRemains(let path): "a staged journal survived closing its database: \(path)"
    case .sqlite(let path, let message): "SQLite: \(path): \(message)"
    case .io(let path, let message): "\(path): \(message)"
    case .implausible(let place): "decrypts under the old key but isn't what that column holds: \(place)"
    case .integrity(let place): "integrity check failed: \(place)"
    case .mismatch(let place): "re-keyed copy doesn't match the original: \(place)"
    case .sweepHit(let place): "still readable with the old key after re-keying: \(place)"
    }
  }
}

public struct RekeyStores: RekeyStoreOperations {
  public static let mockSecret = Data("mock_password".utf8)

  let onStaged: (String) -> Void

  public init(onStaged: @escaping (String) -> Void = { _ in }) {
    self.onStaged = onStaged
  }

  public func preflight(userDataDir: URL, oldSecret: Data) -> RekeyPreflight {
    guard let old = try? Key(secret: oldSecret) else {
      return RekeyPreflight(mockKeyed: false, oldKeyedValues: 0, blocking: [RekeyStoresError.badSecret.description], notes: [])
    }
    let found: Found
    do { found = try Self.discover(userDataDir, excluding: nil) } catch {
      return RekeyPreflight(mockKeyed: false, oldKeyedValues: 0, blocking: ["\(error)"], notes: [])
    }
    var values = 0
    var blocking: [String] = []
    var notes: [String] = []
    for item in found.items {
      do {
        switch item.kind {
        case .database(let kind):
          let db = try Database(item.url, mode: .immutable)
          defer { try? db.close() }
          guard try db.integrityOK() else {
            blocking.append(RekeyStoresError.integrity(item.relativePath).description)
            continue
          }
          let counted = try Self.tally(db, kind: kind, key: old, label: item.relativePath)
          values += counted.plausible
          blocking += counted.implausible.map { RekeyStoresError.implausible($0).description }
          if counted.implausibleCookies > 0 {
            notes.append("\(item.relativePath): \(counted.implausibleCookies) cookies don't start with their host's hash and will be dropped")
          }
          blocking += try Self.sweep(db, key: old, skipping: try Self.presentColumns(db, kind: kind))
            .map { "\(item.relativePath): \($0)" }
        case .prefs:
          values += Self.countPrefs(try Self.readFile(item.url), key: old)
        case .nigori, .blob:
          let data = try Self.readFile(item.url)
          guard let plain = data.withUnsafeBytes({ Self.decrypt($0, key: old) }) else { continue }
          defer { plain.wipe() }
          if Check.proto.accepts(plain) { values += 1 } else { blocking.append(RekeyStoresError.implausible(item.relativePath).description) }
        }
      } catch {
        blocking.append("\(error)")
      }
    }
    return RekeyPreflight(mockKeyed: Self.provesKey(found, old), oldKeyedValues: values, blocking: blocking,
                          notes: notes + Self.unlistedHits(found, old, in: userDataDir))
  }

  public func stage(userDataDir: URL, stagingDir: URL, oldSecret: Data, newSecret: Data) throws -> RekeyStageReport {
    let old = try Key(secret: oldSecret)
    let new = try Key(secret: newSecret)
    guard !old.same(as: new) else { throw RekeyStoresError.sameKey }
    let found = try Self.discover(userDataDir, excluding: stagingDir)
    try Self.makeFolder(stagingDir)

    var stores: [RekeyStagedStore] = []
    var notes: [String] = []
    for item in found.items {
      let staged = stagingDir.appendingPathComponent(item.relativePath)
      let values: Int
      switch item.kind {
      case .database(let kind):
        let counts = try Self.stageDatabase(live: item.url, staged: staged, kind: kind, from: old, to: new, label: item.relativePath)
        let compared = try Self.compareDatabases(original: item.url, candidate: staged, kind: kind, from: old, to: new, label: item.relativePath)
        guard compared.rekeyed == counts.rekeyed, compared.dropped == counts.dropped else {
          throw RekeyStoresError.mismatch("\(item.relativePath): re-keyed \(counts.rekeyed), compared \(compared.rekeyed)")
        }
        try Self.clearStagedSidecars(staged)
        if counts.untouched > 0 { notes.append("\(item.relativePath): \(counts.untouched) values not under the old key, left as they are") }
        if counts.dropped > 0 { notes.append("\(item.relativePath): dropped \(counts.dropped) cookies that don't start with their host's hash; Chrome discards those at load") }
        if counts.rekeyed == 0 && counts.dropped == 0 {
          try Self.removeWithSidecars(staged)
          continue
        }
        values = counts.rekeyed
      case .prefs:
        let original = try Self.readFile(item.url)
        let result = try Self.rekeyPrefs(original, from: old, to: new)
        notes += result.notes.map { "\(item.relativePath): \($0)" }
        values = result.rekeyed
        guard values > 0 else { continue }
        try Self.writeNew(result.bytes, to: staged)
        let compared = try Self.verifyPrefs(original: original, candidate: try Self.readFile(staged), from: old, to: new)
        guard compared == values else { throw RekeyStoresError.mismatch("\(item.relativePath): re-keyed \(values), compared \(compared)") }
      case .nigori, .blob:
        let original = try Self.readFile(item.url)
        switch original.withUnsafeBytes({ Self.rekey($0, from: old, to: new, check: .proto) }) {
        case .notEncrypted, .otherKey: continue
        case .implausible: throw RekeyStoresError.implausible(item.relativePath)
        case .rekeyed(let fresh, let digest):
          try Self.writeNew(fresh, to: staged)
          guard try Self.readFile(staged).withUnsafeBytes({ Self.digest($0, key: new) }) == digest else {
            throw RekeyStoresError.mismatch(item.relativePath)
          }
          values = 1
        }
      }
      try Self.mirrorPermissions(from: item.url, to: staged)
      try Self.fullSync(staged)
      try Self.syncFolders(from: staged.deletingLastPathComponent(), upTo: stagingDir)
      stores.append(RekeyStagedStore(relativePath: item.relativePath, kind: item.kind.storeKind, values: values))
      onStaged(item.relativePath)
    }
    try Self.syncFolders(from: stagingDir, upTo: stagingDir)
    return RekeyStageReport(stores: stores, discard: found.discard.map { Self.relativePath($0, in: userDataDir) }, notes: notes)
  }

  public func verify(file: URL, kind: RekeyStoreKind, newSecret: Data, oldSecret: Data, expectedValues: Int) -> Bool {
    guard let new = try? Key(secret: newSecret), let old = try? Key(secret: oldSecret), !old.same(as: new) else { return false }
    switch kind {
    case .sqlite:
      return (try? Self.verifyDatabase(file, newKey: new, oldKey: old, expected: expectedValues)) ?? false
    case .prefs:
      guard let data = try? Self.readFile(file) else { return false }
      return Self.countPrefs(data, key: new) == expectedValues && Self.countPrefs(data, key: old, unlessOpensUnder: new) == 0
    case .nigori, .blob:
      guard expectedValues == 1, let data = try? Self.readFile(file),
            let plain = data.withUnsafeBytes({ Self.decrypt($0, key: new) }) else { return false }
      defer { plain.wipe() }
      return Check.proto.accepts(plain)
    }
  }
}

extension RekeyStores {
  enum ItemKind {
    case database(DatabaseKind)
    case prefs, nigori, blob

    var storeKind: RekeyStoreKind {
      switch self {
      case .database: .sqlite
      case .prefs: .prefs
      case .nigori: .nigori
      case .blob: .blob
      }
    }
  }

  struct Found {
    struct Item {
      let kind: ItemKind
      let url: URL
      let relativePath: String
    }

    var items: [Item] = []
    var otherDatabases: [URL] = []
    var discard: [URL] = []
  }

  static let prefsNames: Set<String> = ["Preferences", "Secure Preferences", "Local State"]

  static func discover(_ dataDir: URL, excluding staging: URL?) throws -> Found {
    var found = Found()
    let skip = staging.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    guard let walker = FileManager.default.enumerator(at: dataDir, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
      throw RekeyStoresError.io(dataDir.path, "can't list the data folder")
    }
    var sqlite: [URL] = []
    for case let url as URL in walker {
      let values = try? url.resourceValues(forKeys: Set(keys))
      let name = url.lastPathComponent
      if values?.isSymbolicLink == true { continue }
      if values?.isDirectory == true {
        if name.hasPrefix(".rekey-") || url.standardizedFileURL.resolvingSymlinksInPath().path == skip {
          walker.skipDescendants()
        } else if name == "GCM Store" {
          found.discard.append(url)
          walker.skipDescendants()
        }
        continue
      }
      guard values?.isRegularFile == true else { continue }
      let relative = relativePath(url, in: dataDir)
      if prefsNames.contains(name) {
        found.items.append(.init(kind: .prefs, url: url, relativePath: relative))
      } else if name == "Nigori.bin", url.deletingLastPathComponent().lastPathComponent == "Sync Data" {
        found.items.append(.init(kind: .nigori, url: url, relativePath: relative))
      } else if name == "passkey_enclave_state" {
        found.items.append(.init(kind: .blob, url: url, relativePath: relative))
      } else if !sidecarSuffixes.contains(where: { name.hasSuffix($0) }), isSQLite(url) {
        sqlite.append(url)
      }
    }
    for url in sqlite {
      let kind: DatabaseKind?
      do {
        let db = try Database(url, mode: .immutable)
        kind = try Self.kind(of: db)
        try db.close()
      } catch {
        found.otherDatabases.append(url)
        continue
      }
      if let kind {
        found.items.append(.init(kind: .database(kind), url: url, relativePath: relativePath(url, in: dataDir)))
      } else {
        found.otherDatabases.append(url)
      }
    }
    found.items.sort { $0.relativePath < $1.relativePath }
    return found
  }

  static func unlistedHits(_ found: Found, _ key: Key, in dataDir: URL) -> [String] {
    var hits: [String] = []
    for url in found.otherDatabases {
      guard let db = try? Database(url, mode: .immutable) else { continue }
      if let found = try? sweep(db, key: key, binaryMinimum: unlistedBinaryMinimum) {
        hits += found.map { "\(relativePath(url, in: dataDir)): \($0)" }
      }
      try? db.close()
    }
    return hits
  }

  static func provesKey(_ found: Found, _ key: Key) -> Bool {
    var passwords = 0
    for item in found.items {
      guard case .database(let kind) = item.kind, kind != .webData,
            let db = try? Database(item.url, mode: .immutable) else { continue }
      defer { try? db.close() }
      if kind == .cookies {
        let version = (try? cookieVersion(db)) ?? 0
        guard version >= 24, let rows = try? rows(db, cookieColumns[0], hostKeys: true) else { continue }
        for row in rows {
          guard let cell = row.cell, let plain = decrypt(cell.bytes, key: key) else { continue }
          defer { plain.wipe() }
          if Check.cookie.accepts(plain, hostKey: row.hostKey) { return true }
        }
      } else {
        guard let rows = try? rows(db, loginColumns[0], hostKeys: false) else { continue }
        for row in rows {
          guard let cell = row.cell, let plain = decrypt(cell.bytes, key: key) else { continue }
          if plain.isStrictUTF8 { passwords += 1 }
          plain.wipe()
        }
      }
    }
    return passwords >= 3
  }

  static func isSQLite(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let header = (try? handle.read(upToCount: 16)) ?? Data()
    return header == Data("SQLite format 3\u{0}".utf8)
  }

  static func relativePath(_ url: URL, in dir: URL) -> String {
    let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
    let full = url.standardizedFileURL.resolvingSymlinksInPath().path
    return full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
  }

  static func fileSize(_ url: URL) -> Int? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return Int(info.st_size)
  }

  static func readFile(_ url: URL) throws -> Data {
    do { return try Data(contentsOf: url) } catch { throw RekeyStoresError.io(url.path, "can't read") }
  }

  static func makeFolder(_ url: URL) throws {
    do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch {
      throw RekeyStoresError.io(url.path, "can't create")
    }
  }

  static func writeNew(_ data: Data, to url: URL) throws {
    try makeFolder(url.deletingLastPathComponent())
    try removeWithSidecars(url)
    guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw RekeyStoresError.io(url.path, "can't write")
    }
  }

  static func mirrorPermissions(from live: URL, to staged: URL) throws {
    var info = stat()
    guard lstat(live.path, &info) == 0 else { throw RekeyStoresError.io(live.path, "stat: \(String(cString: strerror(errno)))") }
    guard chmod(staged.path, info.st_mode & 0o7777) == 0 else { throw RekeyStoresError.io(staged.path, "chmod: \(String(cString: strerror(errno)))") }
  }

  static func fullSync(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw RekeyStoresError.io(url.path, "open for sync: \(String(cString: strerror(errno)))") }
    defer { Darwin.close(fd) }
    guard fcntl(fd, F_FULLFSYNC) == 0 else { throw RekeyStoresError.io(url.path, "F_FULLFSYNC: \(String(cString: strerror(errno)))") }
  }

  static func syncFolders(from folder: URL, upTo root: URL) throws {
    var current = folder.standardizedFileURL
    let stop = root.standardizedFileURL.path
    while true {
      try fullSync(current)
      if current.path == stop || !current.path.hasPrefix(stop) { break }
      current = current.deletingLastPathComponent()
    }
    try fullSync(root.standardizedFileURL.deletingLastPathComponent())
  }
}
