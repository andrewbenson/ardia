import Foundation

typealias Units = [UInt16]

extension String {
  var units: Units { Array(utf16) }

  init(units: some Collection<UInt16>) {
    self = String(decoding: units, as: UTF16.self)
  }

  func sameUnits(_ other: String) -> Bool {
    utf16.elementsEqual(other.utf16)
  }
}

enum Unit {
  static let tab: UInt16 = 0x09
  static let newline: UInt16 = 0x0a
  static let carriageReturn: UInt16 = 0x0d
  static let space: UInt16 = 0x20
  static let bang: UInt16 = 0x21
  static let quote: UInt16 = 0x22
  static let hash: UInt16 = 0x23
  static let percent: UInt16 = 0x25
  static let plus: UInt16 = 0x2b
  static let comma: UInt16 = 0x2c
  static let dash: UInt16 = 0x2d
  static let dot: UInt16 = 0x2e
  static let slash: UInt16 = 0x2f
  static let zero: UInt16 = 0x30
  static let nine: UInt16 = 0x39
  static let colon: UInt16 = 0x3a
  static let question: UInt16 = 0x3f
  static let at: UInt16 = 0x40
  static let openBracket: UInt16 = 0x5b
  static let backslash: UInt16 = 0x5c
  static let closeBracket: UInt16 = 0x5d
  static let lowerA: UInt16 = 0x61
  static let lowerZ: UInt16 = 0x7a

  static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
  static func isLowerAlpha(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7a }
  static func isAlpha(_ c: UInt16) -> Bool { (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) }
  static func isAlnum(_ c: UInt16) -> Bool { isAlpha(c) || isDigit(c) }
  static func isLowerAlnum(_ c: UInt16) -> Bool { isLowerAlpha(c) || isDigit(c) }
  static func isSchemeTail(_ c: UInt16) -> Bool { isAlnum(c) || c == plus || c == dot || c == dash }
  static func asciiLower(_ c: UInt16) -> UInt16 { c >= 0x41 && c <= 0x5a ? c + 0x20 : c }
  static func isLineTerminator(_ c: UInt16) -> Bool { c == 0x0a || c == 0x0d || c == 0x2028 || c == 0x2029 }
}

extension Array where Element == UInt16 {
  var string: String { String(units: self) }

  func index(of needle: Units, from start: Int = 0) -> Int? {
    let n = needle.count
    let from = Swift.max(start, 0)
    if n == 0 { return from <= count ? from : nil }
    if n > count - from { return nil }
    return withUnsafeBufferPointer { hay in
      needle.withUnsafeBufferPointer { pin in
        let first = pin[0]
        let last = hay.count - n
        var i = from
        while i <= last {
          if hay[i] == first {
            var j = 1
            while j < n && hay[i + j] == pin[j] { j += 1 }
            if j == n { return i }
          }
          i += 1
        }
        return nil
      }
    }
  }

  func lastIndex(ofUnit unit: UInt16) -> Int? { lastIndex(of: unit) }

  func contains(_ needle: Units) -> Bool { index(of: needle) != nil }

  func hasPrefix(_ prefix: Units) -> Bool {
    let n = prefix.count
    if n > count { return false }
    return withUnsafeBufferPointer { hay in
      prefix.withUnsafeBufferPointer { p in
        var i = 0
        while i < n && hay[i] == p[i] { i += 1 }
        return i == n
      }
    }
  }

  func hasPrefix(_ prefix: some Collection<UInt16>, at offset: Int) -> Bool {
    guard offset >= 0, offset + prefix.count <= count else { return false }
    var i = offset
    for c in prefix {
      if self[i] != c { return false }
      i += 1
    }
    return true
  }

  func hasSuffix(_ suffix: Units) -> Bool {
    suffix.count <= count && self[(count - suffix.count)...].elementsEqual(suffix)
  }

  func asciiCaseInsensitivePrefix(_ lowerPrefix: String, at offset: Int = 0) -> Bool {
    let p = lowerPrefix.utf16
    guard offset + p.count <= count else { return false }
    var i = offset
    for c in p {
      if Unit.asciiLower(self[i]) != c { return false }
      i += 1
    }
    return true
  }

  func slice(_ from: Int, _ to: Int? = nil) -> Units {
    let end = Swift.min(to ?? count, count)
    let start = Swift.min(Swift.max(from, 0), end)
    return Array(self[start..<end])
  }

  func replacingAll(_ test: (UInt16) -> Bool, with replacement: some Collection<UInt16>) -> Units {
    var out = Units()
    out.reserveCapacity(count)
    for c in self {
      if test(c) { out.append(contentsOf: replacement) } else { out.append(c) }
    }
    return out
  }
}

extension Units {
  init(_ string: String) { self = Array(string.utf16) }
}

struct UnitsKey: Hashable {
  let units: Units

  init(_ units: Units) { self.units = units }

  static func == (a: UnitsKey, b: UnitsKey) -> Bool {
    a.units.count == b.units.count && a.units.withUnsafeBytes { x in b.units.withUnsafeBytes { y in memcmp(x.baseAddress, y.baseAddress, x.count) == 0 } }
  }

  func hash(into hasher: inout Hasher) {
    units.withUnsafeBytes { hasher.combine(bytes: $0) }
  }
}

func sameBytes(_ a: String, _ b: String) -> Bool {
  var a = a
  var b = b
  return a.withUTF8 { x in b.withUTF8 { y in x.count == y.count && (x.count == 0 || memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0) } }
}
