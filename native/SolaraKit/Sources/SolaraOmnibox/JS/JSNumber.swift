import Foundation

extension JS {
  struct Digits {
    var digits: [UInt8]
    var pointPosition: Int
  }

  static func shortestDigits(_ x: Double) -> Digits {
    let text = Array(x.magnitude.description.utf8)
    var mantissa: [UInt8] = []
    var exponent = 0
    var pointAt: Int?
    var i = 0
    while i < text.count {
      let c = text[i]
      if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
        exponent = Int(String(decoding: text[(i + 1)...], as: UTF8.self))!
        break
      }
      if c == UInt8(ascii: ".") {
        pointAt = mantissa.count
      } else {
        mantissa.append(c - 0x30)
      }
      i += 1
    }
    var point = (pointAt ?? mantissa.count) + exponent
    while mantissa.count > 1 && mantissa.first == 0 {
      mantissa.removeFirst()
      point -= 1
    }
    while mantissa.count > 1 && mantissa.last == 0 { mantissa.removeLast() }
    return Digits(digits: mantissa, pointPosition: point)
  }

  static func numberToString(_ x: Double) -> String {
    if x.isNaN { return "NaN" }
    if x == 0 { return "0" }
    if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
    let d = shortestDigits(x)
    let sign = x < 0 ? "-" : ""
    let s = d.digits.map { Character(Unicode.Scalar($0 + 0x30)) }
    let k = s.count
    let n = d.pointPosition
    if k <= n && n <= 21 { return sign + String(s) + String(repeating: "0", count: n - k) }
    if 0 < n && n <= 21 { return sign + String(s[..<n]) + "." + String(s[n...]) }
    if -6 < n && n <= 0 { return sign + "0." + String(repeating: "0", count: -n) + String(s) }
    let e = n - 1
    let mantissa = k == 1 ? String(s) : String(s[0]) + "." + String(s[1...])
    return sign + mantissa + "e" + (e < 0 ? "-" : "+") + String(abs(e))
  }

  static func toExponential(_ x: Double) -> String {
    if x.isNaN { return "NaN" }
    if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
    if x == 0 { return "0e+0" }
    let d = shortestDigits(x)
    let sign = x < 0 ? "-" : ""
    let s = d.digits.map { Character(Unicode.Scalar($0 + 0x30)) }
    let e = d.pointPosition - 1
    let mantissa = s.count == 1 ? String(s) : String(s[0]) + "." + String(s[1...])
    return sign + mantissa + "e" + (e < 0 ? "-" : "+") + String(abs(e))
  }

  static func toPrecision(_ x: Double, _ p: Int) -> String {
    if x.isNaN { return "NaN" }
    if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
    let sign = x < 0 ? "-" : ""
    let v = x.magnitude
    if v == 0 { return p == 1 ? "0" : "0." + String(repeating: "0", count: p - 1) }
    var (digits, e) = roundedDigits(v, p)
    if digits.count > p {
      digits.removeLast()
      e += 1
    }
    let s = String(digits.map { Character(Unicode.Scalar($0 + 0x30)) })
    if e < -6 || e >= p {
      let mantissa = p == 1 ? s : String(s.prefix(1)) + "." + String(s.dropFirst())
      return sign + mantissa + "e" + (e < 0 ? "-" : "+") + String(abs(e))
    }
    if e == p - 1 { return sign + s }
    if e >= 0 { return sign + String(s.prefix(e + 1)) + "." + String(s.dropFirst(e + 1)) }
    return sign + "0." + String(repeating: "0", count: -(e + 1)) + s
  }

  private static func roundedDigits(_ v: Double, _ p: Int) -> ([UInt8], Int) {
    let (wide, wideExponent) = scientificDigits(v, p + 25)
    let head = Array(wide.prefix(p))
    let tail = wide.dropFirst(p)
    let tie = tail.first == 5 && tail.dropFirst().allSatisfy { $0 == 0 }
    if tie {
      let (exact, _) = scientificDigits(v, 1100)
      let exactTail = exact.dropFirst(p)
      if exactTail.first == 5 && exactTail.dropFirst().allSatisfy({ $0 == 0 }) {
        return roundUp(head, wideExponent)
      }
    }
    let (rounded, exponent) = scientificDigits(v, p)
    return (rounded, exponent)
  }

  private static func roundUp(_ head: [UInt8], _ exponent: Int) -> ([UInt8], Int) {
    var digits = head
    var i = digits.count - 1
    while i >= 0 {
      if digits[i] == 9 {
        digits[i] = 0
        i -= 1
      } else {
        digits[i] += 1
        return (digits, exponent)
      }
    }
    digits.insert(1, at: 0)
    return (digits, exponent)
  }

  private static func scientificDigits(_ v: Double, _ count: Int) -> ([UInt8], Int) {
    let text = String(format: "%.\(count - 1)e", v)
    let parts = text.split(separator: "e")
    let digits = parts[0].utf8.compactMap { $0 == UInt8(ascii: ".") ? nil : $0 - 0x30 }
    return (digits, Int(parts[1])!)
  }

  static func number(_ text: String) -> Double {
    Double(text) ?? .nan
  }

  static func round(_ x: Double) -> Double {
    if !x.isFinite || x == 0 { return x }
    let floor = x.rounded(.down)
    let result = x - floor >= 0.5 ? floor + 1 : floor
    if result == 0 && x < 0 { return -0.0 }
    return result
  }

  static func pow(_ base: Double, _ exponent: Double) -> Double {
    if exponent.isNaN { return .nan }
    if exponent == 0 { return 1 }
    if (base == 1 || base == -1) && exponent.isInfinite { return .nan }
    return Foundation.pow(base, exponent)
  }

  static func isInteger(_ x: Double) -> Bool { x.isFinite && x.rounded(.towardZero) == x }

  static func max(_ values: [Double]) -> Double {
    var result = -Double.infinity
    for v in values {
      if v.isNaN { return .nan }
      if v > result || (v == 0 && result == 0 && result.sign == .minus) { result = v }
    }
    return result
  }

  static func min(_ values: [Double]) -> Double {
    var result = Double.infinity
    for v in values {
      if v.isNaN { return .nan }
      if v < result || (v == 0 && result == 0 && v.sign == .minus) { result = v }
    }
    return result
  }
}
