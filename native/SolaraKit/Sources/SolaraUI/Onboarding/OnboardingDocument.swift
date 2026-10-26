import Foundation
import SolaraModel

enum OnboardingDocument {
  static func parse(_ text: String?) -> JSONObject? {
    guard let text, let value = try? JSONValue.parse(text) else { return nil }
    return value.object
  }

  static func merged(_ saved: JSONObject?, _ patch: JSONObject) -> JSONObject {
    var out: JSONObject = ["version": 1, "completedAt": nil]
    for (key, value) in saved ?? [:] { out[key] = value }
    for (key, value) in patch { out[key] = value }
    return out
  }

  static func stringify(_ value: JSONValue) -> String {
    switch value {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return number(n)
    case .string(let s): return quote(s)
    case .array(let items): return "[" + items.map(stringify).joined(separator: ",") + "]"
    case .object(let object): return "{" + object.map { "\(quote($0.key)):\(stringify($0.value))" }.joined(separator: ",") + "}"
    }
  }

  static func number(_ n: Double) -> String {
    guard n.isFinite else { return "null" }
    if n.rounded() == n, abs(n) < 1e21 { return String(format: "%.0f", n) }
    return "\(n)"
  }

  static func quote(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}
