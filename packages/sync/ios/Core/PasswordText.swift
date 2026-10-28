import Foundation

public enum PasswordText {
  public static func jsonString(_ text: String) -> String {
    var out = "\""
    for unit in text.unicodeScalars {
      switch unit {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\u{8}": out += "\\b"
      case "\u{C}": out += "\\f"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if unit.value < 0x20 {
          out += "\\u" + String(repeating: "0", count: 4 - String(unit.value, radix: 16).count) + String(unit.value, radix: 16)
        } else {
          out.unicodeScalars.append(unit)
        }
      }
    }
    return out + "\""
  }

  public static func canonical(origin: String, username: String, password: String) -> String {
    "{\"o\":\(jsonString(origin)),\"p\":\(jsonString(password)),\"u\":\(jsonString(username))}"
  }

  public static func canonical(origin: String, username: String, sealed: String) -> String {
    "{\"o\":\(jsonString(origin)),\"s\":\(jsonString(sealed)),\"u\":\(jsonString(username))}"
  }

  static func fnv(_ text: String) -> UInt32 {
    var h: UInt32 = 0x811c_9dc5
    for unit in text.utf16 {
      h ^= UInt32(unit)
      h = h &* 0x0100_0193
    }
    return h
  }

  public static func notedDigest(_ canonicalText: String) -> String { String(fnv(canonicalText), radix: 36) }

  public static func ledgerDigest(origin: String, username: String, last: String) -> String {
    let text = "\(origin)\u{0}\(username)\u{0}\(last)"
    return "\(text.utf16.count).\(String(fnv(text), radix: 36))"
  }
}

public struct CodeUnits: Hashable, Sendable {
  public let text: String

  public init(_ text: String) { self.text = text }

  public static func == (a: CodeUnits, b: CodeUnits) -> Bool { a.text.utf16.elementsEqual(b.text.utf16) }

  public func hash(into hasher: inout Hasher) {
    for unit in text.utf16 { hasher.combine(unit) }
  }
}
