import Foundation

enum JS {
  static func isSpace(_ c: UInt16) -> Bool {
    switch c {
    case 0x09...0x0d, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff: true
    default: false
    }
  }

  static func hasSpace(_ s: Units) -> Bool { s.contains(where: isSpace) }

  static func trim(_ s: Units) -> Units {
    var start = 0
    var end = s.count
    while start < end && isSpace(s[start]) { start += 1 }
    while end > start && isSpace(s[end - 1]) { end -= 1 }
    return start == 0 && end == s.count ? s : Array(s[start..<end])
  }

  static func trimStart(_ s: Units) -> Units {
    var start = 0
    while start < s.count && isSpace(s[start]) { start += 1 }
    return start == 0 ? s : Array(s[start...])
  }

  static func trimEnd(_ s: Units) -> Units {
    var end = s.count
    while end > 0 && isSpace(s[end - 1]) { end -= 1 }
    return end == s.count ? s : Array(s[..<end])
  }

  static func trim(_ s: String) -> String { trim(s.units).string }

  static func splitSpaces(_ s: Units) -> [Units] {
    var out: [Units] = []
    var i = 0
    while i < s.count {
      while i < s.count && isSpace(s[i]) { i += 1 }
      let start = i
      while i < s.count && !isSpace(s[i]) { i += 1 }
      if i > start { out.append(Array(s[start..<i])) }
    }
    return out
  }

  static func splitSpacesKeepingEmpty(_ s: Units) -> [Units] {
    var out: [Units] = []
    var start = 0
    var i = 0
    while i < s.count {
      if isSpace(s[i]) {
        out.append(Array(s[start..<i]))
        while i < s.count && isSpace(s[i]) { i += 1 }
        start = i
      } else {
        i += 1
      }
    }
    out.append(Array(s[start...]))
    return out
  }

  static func collapseSpaces(_ s: Units) -> Units {
    var out = Units()
    out.reserveCapacity(s.count)
    var i = 0
    while i < s.count {
      if isSpace(s[i]) {
        out.append(Unit.space)
        while i < s.count && isSpace(s[i]) { i += 1 }
      } else {
        out.append(s[i])
        i += 1
      }
    }
    return out
  }

  static func lower(_ s: Units) -> Units {
    var ascii = true
    for c in s where c >= 0x80 {
      ascii = false
      break
    }
    if ascii {
      var out = s
      for i in out.indices where out[i] >= 0x41 && out[i] <= 0x5a { out[i] += 0x20 }
      return out
    }
    return lower(s.string).units
  }

  static func lower(_ s: String) -> String {
    if s.utf8.allSatisfy({ $0 < 0x80 }) { return s.lowercased() }
    let scalars = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    for i in scalars.indices {
      let c = scalars[i]
      if c.value == 0x3a3 && isFinalSigma(scalars, i) {
        out.append(Unicode.Scalar(0x3c2)!)
      } else if c.value < 0x80 {
        out.append(c.value >= 0x41 && c.value <= 0x5a ? Unicode.Scalar(c.value + 0x20)! : c)
      } else {
        out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
      }
    }
    return String(out)
  }

  private static func isFinalSigma(_ scalars: [Unicode.Scalar], _ at: Int) -> Bool {
    var i = at - 1
    while i >= 0 && scalars[i].properties.isCaseIgnorable { i -= 1 }
    guard i >= 0, scalars[i].properties.isCased else { return false }
    var j = at + 1
    while j < scalars.count && scalars[j].properties.isCaseIgnorable { j += 1 }
    return !(j < scalars.count && scalars[j].properties.isCased)
  }

  static func upper(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for c in s.unicodeScalars { out.append(contentsOf: c.properties.uppercaseMapping.unicodeScalars) }
    return String(out)
  }

  private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

  private static func isURIUnreserved(_ c: UInt32) -> Bool {
    switch c {
    case 0x41...0x5a, 0x61...0x7a, 0x30...0x39: true
    case 0x2d, 0x5f, 0x2e, 0x21, 0x7e, 0x2a, 0x27, 0x28, 0x29: true
    default: false
    }
  }

  static func encodeURIComponent(_ s: String) -> String {
    var out = [UInt8]()
    out.reserveCapacity(s.utf8.count)
    for scalar in s.unicodeScalars {
      if isURIUnreserved(scalar.value) {
        out.append(UInt8(scalar.value))
        continue
      }
      for byte in String(scalar).utf8 {
        out.append(0x25)
        out.append(hexDigits[Int(byte >> 4)])
        out.append(hexDigits[Int(byte & 0xf)])
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  private static func hexValue(_ c: UInt16) -> UInt8? {
    switch c {
    case 0x30...0x39: UInt8(c - 0x30)
    case 0x41...0x46: UInt8(c - 0x41 + 10)
    case 0x61...0x66: UInt8(c - 0x61 + 10)
    default: nil
    }
  }

  static func decodeURIComponent(_ s: String) -> String? {
    let u = s.units
    var out = Units()
    out.reserveCapacity(u.count)
    var k = 0
    func byte(at i: Int) -> UInt8? {
      guard i + 2 < u.count, u[i] == Unit.percent, let hi = hexValue(u[i + 1]), let lo = hexValue(u[i + 2]) else { return nil }
      return hi << 4 | lo
    }
    while k < u.count {
      let c = u[k]
      if c != Unit.percent {
        out.append(c)
        k += 1
        continue
      }
      guard let first = byte(at: k) else { return nil }
      k += 3
      if first & 0x80 == 0 {
        out.append(UInt16(first))
        continue
      }
      let n: Int
      if first & 0xe0 == 0xc0 { n = 2 } else if first & 0xf0 == 0xe0 { n = 3 } else if first & 0xf8 == 0xf0 { n = 4 } else { return nil }
      var bytes = [first]
      for _ in 1..<n {
        guard let b = byte(at: k), b & 0xc0 == 0x80 else { return nil }
        bytes.append(b)
        k += 3
      }
      var cp: UInt32
      switch n {
      case 2: cp = UInt32(first & 0x1f)
      case 3: cp = UInt32(first & 0x0f)
      default: cp = UInt32(first & 0x07)
      }
      for b in bytes.dropFirst() { cp = cp << 6 | UInt32(b & 0x3f) }
      let minimum: UInt32 = n == 2 ? 0x80 : n == 3 ? 0x800 : 0x10000
      if cp < minimum || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff) { return nil }
      out.append(contentsOf: String(Unicode.Scalar(cp)!).utf16)
    }
    return out.string
  }
}
