import CryptoKit
import Foundation

extension RekeyStores {
  struct PrefsResult {
    let bytes: Data
    let rekeyed: Int
    let notes: [String]
  }

  static let superHashKey = "super_encrypted_hash"

  static func rekeyPrefs(_ data: Data, from old: Key, to new: Key) throws -> PrefsResult {
    var bytes = [UInt8](data)
    var rekeyed = 0
    var notes: [String] = []
    for range in stringRanges(bytes) {
      guard let decoded = base64Token(bytes[range]), looksEncrypted(decoded) else { continue }
      guard case .rekeyed(let fresh, _) = decoded.withUnsafeBytes({ rekey($0, from: old, to: new, check: .anything) }) else { continue }
      let text = Array(fresh.base64EncodedString().utf8)
      guard text.count == range.count else { throw RekeyStoresError.mismatch("a re-keyed preference changed length") }
      bytes.replaceSubrange(range, with: text)
      rekeyed += 1
    }
    guard rekeyed > 0 else { return PrefsResult(bytes: data, rekeyed: 0, notes: notes) }

    if let place = superHashRange(bytes) {
      if superHashValid(Array(data), key: old) == true,
         let fresh = expectedSuperHash(bytes, key: new) {
        let text = Array(fresh.utf8)
        guard text.count == place.count else { throw RekeyStoresError.mismatch("the super encrypted hash changed length") }
        bytes.replaceSubrange(place, with: text)
      } else {
        notes.append("protection.super_encrypted_hash couldn't be reproduced under the old key, so it was re-encrypted as it was and won't match: tracked prefs with no stored MAC may reset")
      }
    }
    return PrefsResult(bytes: Data(bytes), rekeyed: rekeyed, notes: notes)
  }

  static func verifyPrefs(original: Data, candidate: Data, from old: Key, to new: Key) throws -> Int {
    let before = [UInt8](original)
    let after = [UInt8](candidate)
    guard before.count == after.count else { throw RekeyStoresError.mismatch("preferences changed length") }
    let superPlace = superHashRange(before)
    let superRecomputed = superHashValid(before, key: old) == true
    var restored = after
    var rekeyed = 0
    for range in stringRanges(before) {
      guard let decoded = base64Token(before[range]), looksEncrypted(decoded),
            let digest = decoded.withUnsafeBytes({ self.digest($0, key: old) }) else { continue }
      guard let now = base64Token(after[range]) else { throw RekeyStoresError.mismatch("preference at byte \(range.lowerBound)") }
      if range == superPlace && superRecomputed {
        guard String(decoding: after[range], as: UTF8.self) == expectedSuperHash(after, key: new) else {
          throw RekeyStoresError.mismatch("protection.super_encrypted_hash")
        }
      } else {
        guard now.withUnsafeBytes({ self.digest($0, key: new) }) == digest else {
          throw RekeyStoresError.mismatch("preference at byte \(range.lowerBound)")
        }
      }
      restored.replaceSubrange(range, with: before[range])
      rekeyed += 1
    }
    guard restored == before else { throw RekeyStoresError.mismatch("preferences changed outside re-keyed values") }
    return rekeyed
  }

  static func countPrefs(_ data: Data, key: Key, unlessOpensUnder other: Key? = nil) -> Int {
    let bytes = [UInt8](data)
    var count = 0
    for range in stringRanges(bytes) {
      guard let decoded = base64Token(bytes[range]), looksEncrypted(decoded) else { continue }
      let opens = { (key: Key) -> Bool in
        guard let plain = decoded.withUnsafeBytes({ decrypt($0, key: key) }) else { return false }
        plain.wipe()
        return true
      }
      guard opens(key) else { continue }
      if let other, opens(other) { continue }
      count += 1
    }
    return count
  }

  static func stringRanges(_ bytes: [UInt8]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var i = 0
    let n = bytes.count
    while i < n {
      guard bytes[i] == 0x22 else { i += 1; continue }
      let start = i + 1
      var j = start
      var escaped = false
      while j < n, bytes[j] != 0x22 {
        if bytes[j] == 0x5C { escaped = true; j += 2 } else { j += 1 }
      }
      guard j < n else { break }
      if !escaped { out.append(start..<j) }
      i = j + 1
    }
    return out
  }

  static func base64Token(_ slice: ArraySlice<UInt8>) -> Data? {
    guard slice.count >= 4, slice.count % 4 == 0 else { return nil }
    for b in slice {
      let ok = (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) || b == 0x2B || b == 0x2F || b == 0x3D
      if !ok { return nil }
    }
    let text = String(decoding: slice, as: UTF8.self)
    guard let data = Data(base64Encoded: text), data.base64EncodedString() == text else { return nil }
    return data
  }

  static func superHashRange(_ bytes: [UInt8]) -> Range<Int>? {
    let ranges = stringRanges(bytes)
    let key = Array(superHashKey.utf8)
    var found: Range<Int>?
    for (index, range) in ranges.enumerated() where Array(bytes[range]) == key {
      var j = range.upperBound + 1
      while j < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[j]) { j += 1 }
      guard j < bytes.count, bytes[j] == 0x3A, index + 1 < ranges.count else { continue }
      guard found == nil else { return nil }
      found = ranges[index + 1]
    }
    return found
  }

  static func superHashValid(_ bytes: [UInt8], key: Key) -> Bool? {
    guard let place = superHashRange(bytes), let expected = expectedSuperHash(bytes, key: key) else { return nil }
    return String(decoding: bytes[place], as: UTF8.self) == expected
  }

  static func expectedSuperHash(_ bytes: [UInt8], key: Key) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
          let protection = root["protection"] as? [String: Any],
          let macs = protection["macs"] as? [String: Any] else { return nil }
    let filtered = encryptedHashesOnly(macs)
    guard !filtered.isEmpty, let json = chromeJSON(filtered) else { return nil }
    let hash = Data(SHA256.hash(data: Data(json.utf8)))
    return encrypt(copying: hash, key: key)?.base64EncodedString()
  }

  static func encryptedHashesOnly(_ dict: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in dict {
      if key.hasSuffix("_encrypted_hash") {
        out[key] = value
      } else if let sub = value as? [String: Any] {
        let filtered = encryptedHashesOnly(sub)
        if !filtered.isEmpty { out[key] = filtered }
      }
    }
    return out
  }

  static func chromeJSON(_ value: Any) -> String? {
    if let dict = value as? [String: Any] {
      var parts: [String] = []
      for key in dict.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
        if let sub = dict[key] as? [String: Any], sub.isEmpty { continue }
        if let list = dict[key] as? [Any], list.isEmpty { continue }
        guard let inner = chromeJSON(dict[key]!) else { return nil }
        if inner == "{}" || inner == "[]" { continue }
        parts.append(chromeString(key) + ":" + inner)
      }
      return "{" + parts.joined(separator: ",") + "}"
    }
    if let string = value as? String { return chromeString(string) }
    return nil
  }

  static func chromeString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x08: out += "\\b"
      case 0x0C: out += "\\f"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0x5C: out += "\\\\"
      case 0x22: out += "\\\""
      case 0x3C: out += "\\u003C"
      case 0x2028: out += "\\u2028"
      case 0x2029: out += "\\u2029"
      case 0..<0x20: out += String(format: "\\u%04X", scalar.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }
}
