import CoreText
import Foundation
import Synchronization

public enum URLPrefixWidths {
  private struct Key: Hashable {
    var prefix: String
    var size: Double
  }

  private static let cache = Mutex<[Key: Double]>([:])
  public static let common = ["https://", "http://", "https://www.", "http://www.", "file://", "solara://", "chrome://"]

  public static func width(prefix: String, in text: String, size: Double) -> Double {
    guard !prefix.isEmpty, text.hasPrefix(prefix) else { return 0 }
    let key = Key(prefix: prefix, size: size)
    if let known = cache.withLock({ $0[key] }) { return known }
    let measured = measure(prefixLength: (prefix as NSString).length, of: text, size: size)
    cache.withLock { $0[key] = measured }
    return measured
  }

  public static func warm(size: Double) {
    for prefix in common { _ = width(prefix: prefix, in: prefix + "example.com", size: size) }
  }

  public static func reset() {
    cache.withLock { $0.removeAll() }
  }

  private static func measure(prefixLength: Int, of text: String, size: Double) -> Double {
    let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let line = CTLineCreateWithAttributedString(attributed)
    return Double(CTLineGetOffsetForStringIndex(line, prefixLength, nil))
  }
}
