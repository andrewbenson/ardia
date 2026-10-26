import Foundation

enum WhatwgUrl {
  static func httpHostname(_ raw: Units) -> Units? {
    var start = 0
    var end = raw.count
    while start < end && raw[start] <= 0x20 { start += 1 }
    while end > start && raw[end - 1] <= 0x20 { end -= 1 }
    let input = raw[start..<end].filter { $0 != Unit.tab && $0 != Unit.newline && $0 != Unit.carriageReturn }
    guard let first = input.first, Unit.isAlpha(first) else { return nil }
    var i = 1
    while i < input.count && Unit.isSchemeTail(input[i]) { i += 1 }
    guard i < input.count, input[i] == Unit.colon else { return nil }
    let scheme = input[..<i].map(Unit.asciiLower)
    guard scheme == Units("http") || scheme == Units("https") else { return nil }
    var at = i + 1
    while at < input.count && (input[at] == Unit.slash || input[at] == Unit.backslash) { at += 1 }
    var authorityEnd = at
    while authorityEnd < input.count && !isAuthorityTerminator(input[authorityEnd]) { authorityEnd += 1 }
    var authority = Array(input[at..<authorityEnd])
    if let lastAt = authority.lastIndex(of: Unit.at) {
      authority = Array(authority[(lastAt + 1)...])
      if authority.isEmpty { return nil }
    }
    var hostEnd = 0
    var insideBrackets = false
    while hostEnd < authority.count {
      let c = authority[hostEnd]
      if c == Unit.colon && !insideBrackets { break }
      if c == Unit.openBracket { insideBrackets = true }
      if c == Unit.closeBracket { insideBrackets = false }
      hostEnd += 1
    }
    let hostText = Array(authority[..<hostEnd])
    if hostText.isEmpty { return nil }
    if hostEnd < authority.count {
      let port = authority[(hostEnd + 1)...]
      guard port.allSatisfy(Unit.isDigit) else { return nil }
      if !port.isEmpty {
        let digits = port.drop { $0 == Unit.zero }
        if digits.count > 5 || (Int(String(units: digits)) ?? 0) > 65535 { return nil }
      }
    }
    return parseHost(hostText)
  }

  private static func isAuthorityTerminator(_ c: UInt16) -> Bool {
    c == Unit.slash || c == Unit.backslash || c == Unit.question || c == Unit.hash
  }

  private static func parseHost(_ input: Units) -> Units? {
    if input.first == Unit.openBracket {
      guard input.last == Unit.closeBracket, input.count >= 2, isIPv6(Array(input[1..<(input.count - 1)])) else { return nil }
      return input
    }
    let domain = percentDecode(input)
    guard let ascii = domainToASCII(domain) else { return nil }
    if ascii.contains(where: isForbiddenDomainUnit) { return nil }
    if endsInNumber(ascii) { return isIPv4(ascii) ? ascii : nil }
    return ascii
  }

  private static func percentDecode(_ input: Units) -> String {
    let bytes = Array(input.string.utf8)
    var out: [UInt8] = []
    var i = 0
    while i < bytes.count {
      if bytes[i] == 0x25, i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
        out.append(hi << 4 | lo)
        i += 3
      } else {
        out.append(bytes[i])
        i += 1
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  private static func hex(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: b - 0x30
    case 0x41...0x46: b - 0x41 + 10
    case 0x61...0x66: b - 0x61 + 10
    default: nil
    }
  }

  private static let labelSeparators: Set<UInt32> = [0x2e, 0x3002, 0xff0e, 0xff61]

  private static func domainToASCII(_ domain: String) -> Units? {
    let mapped = JS.lower(domain.precomposedStringWithCompatibilityMapping).precomposedStringWithCanonicalMapping
    var labels: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in mapped.unicodeScalars {
      if labelSeparators.contains(scalar.value) {
        labels.append(String(current))
        current = String.UnicodeScalarView()
      } else {
        if scalar.properties.isNoncharacterCodePoint || (scalar.value >= 0xe000 && scalar.value <= 0xf8ff) { return nil }
        if scalar.properties.isDefaultIgnorableCodePoint { continue }
        current.append(scalar)
      }
    }
    labels.append(String(current))
    var out: [Units] = []
    for label in labels {
      let units = label.units
      if units.allSatisfy({ $0 < 0x80 }) {
        if units.asciiCaseInsensitivePrefix("xn--") {
          guard let decoded = punycodeDecode(Array(units[4...])), !decoded.isEmpty, !decoded.utf16.allSatisfy({ $0 < 0x80 }) else { return nil }
        }
        out.append(units)
      } else {
        out.append(Units("xn--" + punycodeEncode(label)))
      }
    }
    return Array(out.joined(separator: [Unit.dot]))
  }

  private static func isForbiddenDomainUnit(_ c: UInt16) -> Bool {
    switch c {
    case 0x00...0x20, 0x23, 0x25, 0x2f, 0x3a, 0x3c, 0x3e, 0x3f, 0x40, 0x5b, 0x5c, 0x5d, 0x5e, 0x7c, 0x7f: true
    default: false
    }
  }

  private static func endsInNumber(_ host: Units) -> Bool {
    var parts = host.split(separator: Unit.dot, omittingEmptySubsequences: false).map(Array.init)
    if parts.last?.isEmpty == true {
      if parts.count == 1 { return false }
      parts.removeLast()
    }
    guard let last = parts.last, !last.isEmpty else { return false }
    if last.allSatisfy(Unit.isDigit) { return true }
    return ipv4Number(last) != nil
  }

  private static func ipv4Number(_ part: Units) -> UInt64? {
    if part.isEmpty { return nil }
    var digits = part[...]
    var radix: UInt64 = 10
    if digits.count >= 2, digits.first == Unit.zero, digits.dropFirst().first.map({ $0 == 0x78 || $0 == 0x58 }) == true {
      digits = digits.dropFirst(2)
      radix = 16
    } else if digits.count >= 2, digits.first == Unit.zero {
      digits = digits.dropFirst()
      radix = 8
    }
    if digits.isEmpty { return 0 }
    var value: UInt64 = 0
    for c in digits {
      let d: UInt64
      switch c {
      case 0x30...0x39: d = UInt64(c - 0x30)
      case 0x61...0x66: d = UInt64(c - 0x61 + 10)
      case 0x41...0x46: d = UInt64(c - 0x41 + 10)
      default: return nil
      }
      if d >= radix { return nil }
      value = value.multipliedReportingOverflow(by: radix).partialValue
      value = min(value &+ d, UInt64.max / 32)
    }
    return value
  }

  private static func isIPv4(_ host: Units) -> Bool {
    var parts = host.split(separator: Unit.dot, omittingEmptySubsequences: false).map(Array.init)
    if parts.last?.isEmpty == true && parts.count > 1 { parts.removeLast() }
    if parts.count > 4 { return false }
    var numbers: [UInt64] = []
    for part in parts {
      guard let n = ipv4Number(part) else { return false }
      numbers.append(n)
    }
    for n in numbers.dropLast() where n > 255 { return false }
    let limit = UInt64(1) << (8 * UInt64(5 - numbers.count))
    return numbers.last! < limit
  }

  private static func isIPv6(_ input: Units) -> Bool {
    var pieces = 0
    var compress = false
    var i = 0
    let n = input.count
    func hexDigit(_ c: UInt16) -> Bool { Unit.isDigit(c) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46) }
    if i < n && input[i] == Unit.colon {
      guard i + 1 < n, input[i + 1] == Unit.colon else { return false }
      i += 2
      pieces += 1
      compress = true
    }
    while i < n {
      if pieces == 8 { return false }
      if input[i] == Unit.colon {
        if compress { return false }
        i += 1
        pieces += 1
        compress = true
        continue
      }
      var length = 0
      let pieceStart = i
      while length < 4 && i < n && hexDigit(input[i]) {
        i += 1
        length += 1
      }
      if i < n && input[i] == Unit.dot {
        if length == 0 { return false }
        i = pieceStart
        if pieces > 6 { return false }
        var numbersSeen = 0
        while i < n {
          if numbersSeen > 0 {
            if input[i] == Unit.dot && numbersSeen < 4 { i += 1 } else { return false }
          }
          guard i < n, Unit.isDigit(input[i]) else { return false }
          var value: Int? = nil
          while i < n && Unit.isDigit(input[i]) {
            let d = Int(input[i] - Unit.zero)
            if value == nil {
              value = d
            } else if value == 0 {
              return false
            } else {
              value = value! * 10 + d
            }
            if value! > 255 { return false }
            i += 1
          }
          numbersSeen += 1
          if numbersSeen == 2 || numbersSeen == 4 { pieces += 1 }
        }
        if numbersSeen != 4 { return false }
        break
      } else if i < n && input[i] == Unit.colon {
        i += 1
        if i >= n { return false }
      } else if i < n {
        return false
      }
      pieces += 1
    }
    return compress || pieces == 8
  }
}
