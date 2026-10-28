import Foundation

public final class SealedPasswords: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false

  public init() {}

  public var latched: Bool {
    lock.lock()
    defer { lock.unlock() }
    return on
  }

  public func latch() {
    lock.lock()
    defer { lock.unlock() }
    on = true
  }

  static let whitespace: Set<UInt16> = Set([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] + Array(UInt16(0x2000)...UInt16(0x200A)))
  static let slash: UInt16 = 0x2F

  public static func origin(of realm: String) -> String? {
    var units = Array(realm.utf16)
    if units.last == slash { units.removeLast() }
    let host: ArraySlice<UInt16>
    if units.starts(with: "https://".utf16) {
      host = units.dropFirst(8)
    } else if units.starts(with: "http://".utf16) {
      host = units.dropFirst(7)
    } else {
      return nil
    }
    guard !host.isEmpty, !host.contains(where: { $0 == slash || whitespace.contains($0) }) else { return nil }
    return String(decoding: units, as: UTF16.self)
  }

  public static func key(origin: String, username: String) -> String { "pw:\(origin)\n\(username)" }

  public static func opens(_ value: [String: Any], keys: SyncKeys) -> Bool {
    guard Set(value.keys) == ["o", "u", "s"], let o = value["o"] as? String, let u = value["u"] as? String, let s = value["s"] as? String else { return false }
    return (try? keys.openPassword(s, origin: o, username: u)) != nil
  }

  public static func folderListing(_ listing: SyncVault.Listing, keys: SyncKeys) -> SyncVault.Listing {
    var out = listing
    out.files = []
    for file in listing.files {
      if let sealed = try? PasswordValues.convert(String(decoding: file.payload, as: UTF8.self), .folderFile, .seal, keys: keys) {
        out.files.append(SyncVault.File(id: file.id, payload: Data(sealed.utf8)))
      } else {
        out.damaged.append((file.id, 0))
      }
    }
    return out
  }

  public static func folderPayload(_ payload: String, keys: SyncKeys) throws -> String {
    try PasswordValues.convert(payload, .folderFile, .open, keys: keys)
  }
}
