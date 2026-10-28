import Foundation

public enum LocalDocuments {
  public enum Kind: String, Sendable {
    case state
    case journal

    public var fileId: String { "\(rawValue).v2" }

    public func fileId(part: String?) -> String { part.map { "\(fileId).\($0)" } ?? fileId }
    var shape: PasswordValues.Shape { self == .state ? .state : .journal }
  }

  static let scopeTag = "local"
  public static func legacyFileId(part: String?) -> String { part.map { "state.\($0)" } ?? "state" }

  public static func seal(_ body: String, _ kind: Kind, part: String? = nil, keys: SyncKeys) throws -> Data {
    if try PasswordValues.plainValues(body, kind.shape) { throw PasswordValues.Refused(key: kind.rawValue, reason: "a plain password in the local \(kind.rawValue)") }
    return try keys.seal(wrap(body), scopeTag: scopeTag, fileId: kind.fileId(part: part))
  }

  public static func open(_ sealed: Data, _ kind: Kind, part: String? = nil, keys: SyncKeys) -> String? {
    if let plain = try? keys.open(sealed, scopeTag: scopeTag, fileId: kind.fileId(part: part)) { return unwrap(plain) }
    guard let legacy = try? keys.open(sealed, scopeTag: scopeTag, fileId: legacyFileId(part: part)) else { return nil }
    return try? PasswordValues.convert(String(decoding: legacy, as: UTF8.self), kind.shape, .seal, keys: keys)
  }

  static func wrap(_ body: String) -> Data {
    Data("{\"sealedPasswords\":1,\"body\":\(PasswordText.jsonString(body))}".utf8)
  }

  static func unwrap(_ data: Data) -> String? {
    var scanner = JSONScanner(Array(data))
    guard let root = try? scanner.document(), let flag = root.member("sealedPasswords"), case .other = flag.kind,
      String(decoding: Array(data)[flag.range], as: UTF8.self) == "1"
    else { return nil }
    return root.member("body")?.text
  }
}
