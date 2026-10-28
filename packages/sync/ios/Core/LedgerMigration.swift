import Foundation

public enum LedgerMigration {
  public struct Login: Sendable, Equatable {
    public var origin: String
    public var username: String
    public var password: String

    public init(origin: String, username: String, password: String) {
      self.origin = origin
      self.username = username
      self.password = password
    }
  }

  public struct Profile: Sendable {
    public var logins: [CodeUnits: Login]?
    public var records: [CodeUnits: Login]

    public init(logins: [CodeUnits: Login]?, records: [CodeUnits: Login]) {
      self.logins = logins
      self.records = records
    }
  }

  public static func needsMigration(_ ledgerText: String?) -> Bool {
    guard let ledgerText else { return false }
    let bytes = Array(ledgerText.utf8)
    var scanner = JSONScanner(bytes)
    guard let root = try? scanner.document(), let version = root.member("v") else { return false }
    return String(decoding: bytes[version.range], as: UTF8.self) == "1"
  }

  public static func migrate(_ ledgerText: String, profiles: [String: Profile], keys: SyncKeys) throws -> String? {
    let bytes = Array(ledgerText.utf8)
    var scanner = JSONScanner(bytes)
    let root = try scanner.document()
    guard let version = root.member("v"), String(decoding: bytes[version.range], as: UTF8.self) == "1" else { return nil }
    var edits: [(Range<Int>, String)] = [(version.range, "2")]
    for entry in root.member("profiles")?.members ?? [] {
      guard let keyed = entry.value.member("keys")?.members, !keyed.isEmpty else { continue }
      guard let profile = profiles[entry.key], let logins = profile.logins else { return nil }
      for key in keyed {
        guard let digests = key.value.member("d"), let first = digests.items?.first?.text else { continue }
        var next = PasswordValues.unmatched
        for candidate in [logins[CodeUnits(key.key)], profile.records[CodeUnits(key.key)]].compactMap({ $0 })
        where PasswordText.ledgerDigest(origin: candidate.origin, username: candidate.username, last: candidate.password) == first {
          let sealed = try keys.sealPassword(candidate.password, origin: candidate.origin, username: candidate.username)
          next = PasswordText.ledgerDigest(origin: candidate.origin, username: candidate.username, last: sealed)
          break
        }
        edits.append((digests.range, "[\(PasswordText.jsonString(next))]"))
      }
    }
    var out = bytes
    for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { out.replaceSubrange(range, with: Array(replacement.utf8)) }
    return String(decoding: out, as: UTF8.self)
  }

  public static func logins(_ credentials: [(realm: String, username: String, password: String)]) -> [CodeUnits: Login] {
    var out: [CodeUnits: Login] = [:]
    for c in credentials {
      guard let origin = SealedPasswords.origin(of: c.realm) else { continue }
      out[CodeUnits(SealedPasswords.key(origin: origin, username: c.username))] = Login(origin: origin, username: c.username, password: c.password)
    }
    return out
  }

  public static func records(fromState stateText: String, scope: String, keys: SyncKeys) -> [CodeUnits: Login] {
    var scanner = JSONScanner(Array(stateText.utf8))
    guard let root = try? scanner.document(), let records = root.member(scope)?.member("records")?.members else { return [:] }
    var out: [CodeUnits: Login] = [:]
    for record in records where record.key.hasPrefix("pw:") {
      guard let value = record.value.member("v"), let o = value.member("o")?.text, let u = value.member("u")?.text else { continue }
      if let p = value.member("p")?.text {
        out[CodeUnits(record.key)] = Login(origin: o, username: u, password: p)
      } else if let s = value.member("s")?.text, let p = try? keys.openPassword(s, origin: o, username: u) {
        out[CodeUnits(record.key)] = Login(origin: o, username: u, password: p)
      }
    }
    return out
  }
}
