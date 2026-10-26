import Foundation

public enum LiveJSON {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  public static func text<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encode(value), as: UTF8.self)
  }

  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
  }

  public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
    try decode(type, from: Data(text.utf8))
  }
}

enum JS {
  static func dateParse(_ text: String) -> Double {
    isoMilliseconds(text) ?? 0
  }

  static func isoMilliseconds(_ text: String) -> Double? {
    let s = Array(text.utf8)
    var i = 0
    func digits(_ n: Int) -> Int? {
      guard i + n <= s.count else { return nil }
      var v = 0
      for k in 0..<n {
        let b = s[i + k]
        guard b >= 48, b <= 57 else { return nil }
        v = v * 10 + Int(b - 48)
      }
      i += n
      return v
    }
    func take(_ c: UInt8) -> Bool {
      guard i < s.count, s[i] == c else { return false }
      i += 1
      return true
    }
    guard let year = digits(4) else { return nil }
    var month = 1, day = 1, hour = 0, minute = 0, second = 0, ms = 0
    var offsetMinutes: Int? = 0
    if take(UInt8(ascii: "-")) {
      guard let m = digits(2) else { return nil }
      month = m
      if take(UInt8(ascii: "-")) {
        guard let d = digits(2) else { return nil }
        day = d
      }
    }
    if take(UInt8(ascii: "T")) {
      guard let h = digits(2), take(UInt8(ascii: ":")), let mi = digits(2) else { return nil }
      hour = h
      minute = mi
      if take(UInt8(ascii: ":")) {
        guard let sec = digits(2) else { return nil }
        second = sec
        if take(UInt8(ascii: ".")) {
          var count = 0
          var fraction = 0
          while i < s.count, s[i] >= 48, s[i] <= 57 {
            if count < 3 { fraction = fraction * 10 + Int(s[i] - 48) }
            count += 1
            i += 1
          }
          guard count > 0 else { return nil }
          for _ in min(count, 3)..<3 { fraction *= 10 }
          ms = fraction
        }
      }
      if take(UInt8(ascii: "Z")) {
        offsetMinutes = 0
      } else if i < s.count, s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") {
        let sign = s[i] == UInt8(ascii: "-") ? -1 : 1
        i += 1
        guard let oh = digits(2), take(UInt8(ascii: ":")), let om = digits(2) else { return nil }
        offsetMinutes = sign * (oh * 60 + om)
      } else {
        offsetMinutes = nil
      }
    }
    guard i == s.count, (1...12).contains(month), (1...31).contains(day), hour <= 24, minute < 60, second < 60 else { return nil }
    guard let offsetMinutes else {
      var local = DateComponents()
      local.year = year
      local.month = month
      local.day = day
      local.hour = hour
      local.minute = minute
      local.second = second
      guard let date = Calendar(identifier: .gregorian).date(from: local) else { return nil }
      return (date.timeIntervalSince1970 * 1000).rounded() + Double(ms)
    }
    let days = daysFromCivil(year: year, month: month, day: day)
    return Double(days) * 86_400_000 + Double(hour * 3_600_000 + minute * 60_000 + second * 1000 + ms) - Double(offsetMinutes * 60_000)
  }

  static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (month + 9) % 12
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }

  static let uriUnreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8))

  static func encodeURIComponent(_ text: String) -> String {
    var out = ""
    for byte in text.utf8 {
      if uriUnreserved.contains(byte) {
        out.append(Character(UnicodeScalar(byte)))
      } else {
        out += String(format: "%%%02X", byte)
      }
    }
    return out
  }

  static func decodeURIComponent(_ text: String) -> String {
    text.removingPercentEncoding ?? text
  }

  static func base36(_ value: Int) -> String {
    String(value, radix: 36)
  }

  static func utf16Prefix(_ text: String, _ count: Int) -> String {
    let units = Array(text.utf16.prefix(count))
    return String(decoding: units, as: UTF16.self)
  }
}

extension Array {
  func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
    enumerated()
      .sorted { a, b in
        if areInIncreasingOrder(a.element, b.element) { return true }
        if areInIncreasingOrder(b.element, a.element) { return false }
        return a.offset < b.offset
      }
      .map(\.element)
  }

  func stableSorted(comparing compare: (Element, Element) -> Double) -> [Element] {
    stableSorted { compare($0, $1) < 0 }
  }
}

extension Sequence where Element: Hashable {
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
