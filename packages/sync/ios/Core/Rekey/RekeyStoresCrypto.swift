import CommonCrypto
import CryptoKit
import Foundation

extension RekeyStores {
  static let versionTag: [UInt8] = Array("v10".utf8)
  static let salt: [UInt8] = Array("saltysalt".utf8)
  static let iterations: UInt32 = 1003
  static let blockSize = kCCBlockSizeAES128
  static let fixedIV = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)

  final class Buffer {
    let base: UnsafeMutableRawPointer
    let capacity: Int
    var count: Int

    init(capacity: Int) {
      self.capacity = max(capacity, 1)
      base = UnsafeMutableRawPointer.allocate(byteCount: self.capacity, alignment: 16)
      base.initializeMemory(as: UInt8.self, repeating: 0, count: self.capacity)
      count = 0
    }

    deinit {
      wipe()
      base.deallocate()
    }

    var bytes: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: base, count: count) }

    func wipe() {
      _ = memset_s(base, capacity, 0, capacity)
      count = 0
    }

    var isStrictUTF8: Bool { Validate.utf8(bytes) }

    func digest() -> Data { Data(SHA256.hash(data: bytes)) }

    func starts(with prefix: Data) -> Bool {
      guard count >= prefix.count else { return false }
      return prefix.withUnsafeBytes { memcmp(base, $0.baseAddress!, prefix.count) == 0 }
    }
  }

  final class Key {
    fileprivate let buffer = Buffer(capacity: kCCKeySizeAES128)

    init(secret: Data) throws {
      guard !secret.isEmpty else { throw RekeyStoresError.badSecret }
      let status = secret.withUnsafeBytes { secret in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                             secret.bindMemory(to: Int8.self).baseAddress, secret.count,
                             salt, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations,
                             buffer.base.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
      }
      guard status == kCCSuccess else { throw RekeyStoresError.badSecret }
      buffer.count = kCCKeySizeAES128
    }

    func matches(_ bytes: [UInt8]) -> Bool {
      bytes.count == kCCKeySizeAES128 && memcmp(buffer.base, bytes, kCCKeySizeAES128) == 0
    }

    func same(as other: Key) -> Bool { memcmp(buffer.base, other.buffer.base, kCCKeySizeAES128) == 0 }
  }

  static func looksEncrypted(_ value: UnsafeRawBufferPointer) -> Bool {
    let body = value.count - versionTag.count
    guard body >= blockSize, body % blockSize == 0 else { return false }
    return value[0] == versionTag[0] && value[1] == versionTag[1] && value[2] == versionTag[2]
  }

  static func looksEncrypted(_ value: Data) -> Bool { value.withUnsafeBytes { looksEncrypted($0) } }

  static func decrypt(_ value: UnsafeRawBufferPointer, key: Key) -> Buffer? {
    guard looksEncrypted(value) else { return nil }
    let bodyCount = value.count - versionTag.count
    let out = Buffer(capacity: bodyCount)
    var written = 0
    let status = fixedIV.withUnsafeBytes { iv in
      CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
              key.buffer.base, kCCKeySizeAES128, iv.baseAddress,
              value.baseAddress! + versionTag.count, bodyCount, out.base, out.capacity, &written)
    }
    guard status == kCCSuccess, written == bodyCount else { return nil }
    let bytes = out.base.assumingMemoryBound(to: UInt8.self)
    let pad = Int(bytes[bodyCount - 1])
    guard pad >= 1, pad <= blockSize else { return nil }
    for i in (bodyCount - pad)..<bodyCount where bytes[i] != UInt8(pad) { return nil }
    _ = memset_s(out.base + (bodyCount - pad), pad, 0, pad)
    out.count = bodyCount - pad
    return out
  }

  static func decrypt(_ value: Data, key: Key) -> Buffer? { value.withUnsafeBytes { decrypt($0, key: key) } }

  static func encrypt(_ plain: Buffer, key: Key) -> Data? {
    let capacity = plain.count + blockSize
    var out = Data(count: versionTag.count + capacity)
    var written = 0
    let status = out.withUnsafeMutableBytes { dst in
      fixedIV.withUnsafeBytes { iv in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key.buffer.base, kCCKeySizeAES128, iv.baseAddress,
                plain.base, plain.count, dst.baseAddress! + versionTag.count, capacity, &written)
      }
    }
    guard status == kCCSuccess else { return nil }
    out.replaceSubrange(0..<versionTag.count, with: versionTag)
    return out.prefix(versionTag.count + written)
  }

  static func encrypt(copying plaintext: Data, key: Key) -> Data? {
    let plain = Buffer(capacity: plaintext.count)
    plaintext.withUnsafeBytes { if !$0.isEmpty { plain.base.copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
    plain.count = plaintext.count
    return encrypt(plain, key: key)
  }

  enum Check: String, Sendable {
    case utf8, digits, iban, anything, proto, cookie, keywordHash

    func accepts(_ plain: Buffer, hostKey: Data? = nil) -> Bool {
      let bytes = plain.bytes
      switch self {
      case .utf8: return Validate.utf8(bytes)
      case .digits: return bytes.allSatisfy { (0x30...0x39).contains($0) || $0 == 0x20 }
      case .iban: return bytes.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || $0 == 0x20 }
      case .anything: return true
      case .proto: return Validate.proto(bytes)
      case .keywordHash: return bytes.count == 1 + SHA256.byteCount && (bytes[0] == 1 || bytes[0] == 2)
      case .cookie:
        guard let hostKey else { return true }
        let hash = Data(SHA256.hash(data: hostKey))
        return plain.starts(with: hash)
      }
    }
  }

  enum Outcome {
    case notEncrypted
    case otherKey
    case implausible
    case rekeyed(Data, digest: Data)
  }

  static func rekey(_ value: UnsafeRawBufferPointer, from old: Key, to new: Key, check: Check, hostKey: Data? = nil) -> Outcome {
    guard looksEncrypted(value) else { return .notEncrypted }
    guard let plain = decrypt(value, key: old) else { return .otherKey }
    defer { plain.wipe() }
    guard check.accepts(plain, hostKey: hostKey) else { return .implausible }
    guard let fresh = encrypt(plain, key: new) else { return .implausible }
    return .rekeyed(fresh, digest: plain.digest())
  }

  static func digest(_ value: UnsafeRawBufferPointer, key: Key) -> Data? {
    guard let plain = decrypt(value, key: key) else { return nil }
    defer { plain.wipe() }
    return plain.digest()
  }

  enum Validate {
    static func utf8(_ bytes: UnsafeRawBufferPointer) -> Bool {
      var i = 0
      let n = bytes.count
      while i < n {
        let b = bytes[i]
        if b < 0x80 { i += 1; continue }
        let len: Int
        let floor: UInt32
        var cp: UInt32
        switch b {
        case 0xC2...0xDF: len = 2; cp = UInt32(b & 0x1F); floor = 0x80
        case 0xE0...0xEF: len = 3; cp = UInt32(b & 0x0F); floor = 0x800
        case 0xF0...0xF4: len = 4; cp = UInt32(b & 0x07); floor = 0x10000
        default: return false
        }
        guard i + len <= n else { return false }
        for k in 1..<len {
          let c = bytes[i + k]
          guard c & 0xC0 == 0x80 else { return false }
          cp = (cp << 6) | UInt32(c & 0x3F)
        }
        guard cp >= floor, cp <= 0x10FFFF, !(0xD800...0xDFFF).contains(cp) else { return false }
        i += len
      }
      return true
    }

    static func proto(_ bytes: UnsafeRawBufferPointer) -> Bool {
      var i = 0
      func varint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < bytes.count, shift < 64 {
          let b = bytes[i]
          i += 1
          value |= UInt64(b & 0x7F) << shift
          if b & 0x80 == 0 { return value }
          shift += 7
        }
        return nil
      }
      while i < bytes.count {
        guard let tag = varint(), tag >> 3 != 0 else { return false }
        switch tag & 7 {
        case 0: guard varint() != nil else { return false }
        case 1: guard i + 8 <= bytes.count else { return false }; i += 8
        case 5: guard i + 4 <= bytes.count else { return false }; i += 4
        case 2:
          guard let length = varint(), length <= UInt64(bytes.count - i) else { return false }
          i += Int(length)
        default: return false
        }
      }
      return true
    }
  }
}
