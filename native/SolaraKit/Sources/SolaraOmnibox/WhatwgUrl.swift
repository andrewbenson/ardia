import Foundation

public struct WhatwgURL: Sendable, Equatable {
  enum Host: Sendable, Equatable {
    case domain(Units)
    case ipv4(UInt32)
    case ipv6([UInt16])
    case opaque(Units)
    case empty
  }

  var scheme: Units
  var username: Units = []
  var password: Units = []
  var hostValue: Host?
  var portValue: Int?
  var path: [Units] = []
  var opaquePath: Units?
  var query: Units?
  var fragment: Units?

  public init?(_ string: String) {
    guard let parsed = WhatwgParser.parse(string.units) else { return nil }
    self = parsed
  }

  init(scheme: Units) { self.scheme = scheme }

  var isSpecial: Bool { WhatwgParser.specialPorts[UnitsKey(scheme)] != nil }

  public var `protocol`: String { (scheme + [Unit.colon]).string }
  public var usernameText: String { username.string }
  public var passwordText: String { password.string }

  public var hostname: String { hostValue.map(WhatwgParser.serialize)?.string ?? "" }

  public var host: String {
    guard let hostValue else { return "" }
    let name = WhatwgParser.serialize(hostValue).string
    return portValue.map { "\(name):\($0)" } ?? name
  }

  public var port: String { portValue.map(String.init) ?? "" }

  public var pathname: String {
    if let opaquePath { return opaquePath.string }
    return path.map { "/" + $0.string }.joined()
  }

  public var search: String {
    guard let query, !query.isEmpty else { return "" }
    return "?" + query.string
  }

  public var hash: String {
    guard let fragment, !fragment.isEmpty else { return "" }
    return "#" + fragment.string
  }

  public var href: String {
    var out = scheme + [Unit.colon]
    if let hostValue {
      out += Units("//")
      if !username.isEmpty || !password.isEmpty {
        out += username
        if !password.isEmpty { out += [Unit.colon] + password }
        out.append(Unit.at)
      }
      out += WhatwgParser.serialize(hostValue)
      if let portValue { out += Units(":\(portValue)") }
    } else if opaquePath == nil && path.count > 1 && path[0].isEmpty {
      out += Units("/.")
    }
    out += Units(pathname)
    if let query { out += [Unit.question] + query }
    if let fragment { out += [Unit.hash] + fragment }
    return out.string
  }
}

enum WhatwgParser {
  static let specialPorts: [UnitsKey: Int?] = [
    UnitsKey(Units("ftp")): 21, UnitsKey(Units("file")): nil, UnitsKey(Units("http")): 80, UnitsKey(Units("https")): 443,
    UnitsKey(Units("ws")): 80, UnitsKey(Units("wss")): 443,
  ]

  private enum State {
    case schemeStart, scheme, specialAuthoritySlashes, specialAuthorityIgnoreSlashes, pathOrAuthority, authority, host, port
    case file, fileSlash, fileHost, pathStart, path, opaquePath, query, fragment
  }

  private static let eof: UInt32 = 0x110000

  static func isC0Control(_ c: UInt32) -> Bool { c <= 0x1f }

  private static func inC0Set(_ c: UInt32) -> Bool { c <= 0x1f || c > 0x7e }
  private static func inFragmentSet(_ c: UInt32) -> Bool { inC0Set(c) || c == 0x20 || c == 0x22 || c == 0x3c || c == 0x3e || c == 0x60 }
  private static func inQuerySet(_ c: UInt32) -> Bool { inC0Set(c) || c == 0x20 || c == 0x22 || c == 0x23 || c == 0x3c || c == 0x3e }
  private static func inSpecialQuerySet(_ c: UInt32) -> Bool { inQuerySet(c) || c == 0x27 }
  private static func inPathSet(_ c: UInt32) -> Bool { inQuerySet(c) || c == 0x3f || c == 0x5e || c == 0x60 || c == 0x7b || c == 0x7d }
  private static func inUserinfoSet(_ c: UInt32) -> Bool {
    inPathSet(c) || c == 0x2f || c == 0x3a || c == 0x3b || c == 0x3d || c == 0x40 || (c >= 0x5b && c <= 0x5d) || c == 0x7c
  }

  private static let hex: [UInt16] = Array("0123456789ABCDEF".utf16)

  private static func encode(_ scalar: Unicode.Scalar, _ set: (UInt32) -> Bool, into out: inout Units) {
    if !set(scalar.value) {
      out.append(contentsOf: String(scalar).utf16)
      return
    }
    for byte in String(scalar).utf8 {
      out.append(Unit.percent)
      out.append(hex[Int(byte >> 4)])
      out.append(hex[Int(byte & 0xf)])
    }
  }

  private static func scalars(_ units: Units) -> [UInt32] { units.string.unicodeScalars.map(\.value) }

  private static func isWindowsDriveLetter(_ s: Units, normalized: Bool = false) -> Bool {
    s.count == 2 && Unit.isAlpha(s[0]) && (s[1] == Unit.colon || (!normalized && s[1] == 0x7c))
  }

  private static func startsWithWindowsDriveLetter(_ c: [UInt32], _ at: Int) -> Bool {
    guard at + 1 < c.count, c[at] < 0x80, Unit.isAlpha(UInt16(c[at])), c[at + 1] == 0x3a || c[at + 1] == 0x7c else { return false }
    if at + 2 == c.count { return true }
    let next = c[at + 2]
    return next == 0x2f || next == 0x5c || next == 0x3f || next == 0x23
  }

  private static func isSingleDot(_ s: Units) -> Bool { s == [Unit.dot] || s.map(Unit.asciiLower) == Units("%2e") }

  private static func isDoubleDot(_ s: Units) -> Bool {
    let lower = s.map(Unit.asciiLower)
    return lower == Units("..") || lower == Units(".%2e") || lower == Units("%2e.") || lower == Units("%2e%2e")
  }

  private static func shorten(_ url: inout WhatwgURL) {
    if url.scheme == Units("file") && url.path.count == 1 && isWindowsDriveLetter(url.path[0], normalized: true) { return }
    if !url.path.isEmpty { url.path.removeLast() }
  }

  static func parse(_ raw: Units) -> WhatwgURL? {
    var start = 0
    var end = raw.count
    while start < end && raw[start] <= 0x20 { start += 1 }
    while end > start && raw[end - 1] <= 0x20 { end -= 1 }
    let input = raw[start..<end].filter { $0 != Unit.tab && $0 != Unit.newline && $0 != Unit.carriageReturn }
    let c = scalars(Array(input))
    var url = WhatwgURL(scheme: [])
    var state = State.schemeStart
    var buffer = Units()
    var atSignSeen = false
    var insideBrackets = false
    var passwordTokenSeen = false
    var pointer = 0

    func char(_ i: Int) -> UInt32 { i >= 0 && i < c.count ? c[i] : eof }
    func append(_ v: UInt32, _ to: inout Units) { to.append(contentsOf: String(Unicode.Scalar(v)!).utf16) }

    while true {
      let ch = char(pointer)
      let atEnd = pointer >= c.count
      let isAlpha = ch < 0x80 && Unit.isAlpha(UInt16(ch))
      switch state {
      case .schemeStart:
        guard isAlpha else { return nil }
        buffer.append(Unit.asciiLower(UInt16(ch)))
        state = .scheme
      case .scheme:
        if ch < 0x80 && (Unit.isAlnum(UInt16(ch)) || ch == 0x2b || ch == 0x2d || ch == 0x2e) {
          buffer.append(Unit.asciiLower(UInt16(ch)))
        } else if ch == 0x3a {
          url.scheme = buffer
          buffer = []
          if url.scheme == Units("file") {
            state = .file
          } else if url.isSpecial {
            state = .specialAuthoritySlashes
          } else if char(pointer + 1) == 0x2f {
            state = .pathOrAuthority
            pointer += 1
          } else {
            url.opaquePath = []
            state = .opaquePath
          }
        } else {
          return nil
        }
      case .specialAuthoritySlashes:
        if ch == 0x2f && char(pointer + 1) == 0x2f {
          state = .specialAuthorityIgnoreSlashes
          pointer += 1
        } else {
          state = .specialAuthorityIgnoreSlashes
          pointer -= 1
        }
      case .specialAuthorityIgnoreSlashes:
        if ch != 0x2f && ch != 0x5c {
          state = .authority
          pointer -= 1
        }
      case .pathOrAuthority:
        if ch == 0x2f {
          state = .authority
        } else {
          state = .path
          pointer -= 1
        }
      case .authority:
        if ch == 0x40 {
          if atSignSeen { buffer = Units("%40") + buffer }
          atSignSeen = true
          for v in scalars(buffer) {
            if v == 0x3a && !passwordTokenSeen {
              passwordTokenSeen = true
              continue
            }
            if passwordTokenSeen {
              encode(Unicode.Scalar(v)!, inUserinfoSet, into: &url.password)
            } else {
              encode(Unicode.Scalar(v)!, inUserinfoSet, into: &url.username)
            }
          }
          buffer = []
        } else if atEnd || ch == 0x2f || ch == 0x3f || ch == 0x23 || (url.isSpecial && ch == 0x5c) {
          if atSignSeen && buffer.isEmpty { return nil }
          pointer -= scalars(buffer).count + 1
          buffer = []
          state = .host
        } else {
          append(ch, &buffer)
        }
      case .host:
        if ch == 0x3a && !insideBrackets {
          if buffer.isEmpty { return nil }
          guard let host = parseHost(buffer, opaque: !url.isSpecial) else { return nil }
          url.hostValue = host
          buffer = []
          state = .port
        } else if atEnd || ch == 0x2f || ch == 0x3f || ch == 0x23 || (url.isSpecial && ch == 0x5c) {
          pointer -= 1
          if url.isSpecial && buffer.isEmpty { return nil }
          guard let host = parseHost(buffer, opaque: !url.isSpecial) else { return nil }
          url.hostValue = host
          buffer = []
          state = .pathStart
        } else {
          if ch == 0x5b { insideBrackets = true }
          if ch == 0x5d { insideBrackets = false }
          append(ch, &buffer)
        }
      case .port:
        if ch >= 0x30 && ch <= 0x39 {
          buffer.append(UInt16(ch))
        } else if atEnd || ch == 0x2f || ch == 0x3f || ch == 0x23 || (url.isSpecial && ch == 0x5c) {
          if !buffer.isEmpty {
            let digits = buffer.drop { $0 == Unit.zero }
            guard digits.count <= 5, let port = digits.isEmpty ? 0 : Int(String(units: digits)), port <= 65535 else { return nil }
            let defaultPort = specialPorts[UnitsKey(url.scheme)] ?? nil
            url.portValue = port == defaultPort ? nil : port
            buffer = []
          }
          state = .pathStart
          pointer -= 1
        } else {
          return nil
        }
      case .file:
        url.scheme = Units("file")
        url.hostValue = .empty
        if ch == 0x2f || ch == 0x5c {
          state = .fileSlash
        } else {
          state = .path
          pointer -= 1
        }
      case .fileSlash:
        if ch == 0x2f || ch == 0x5c {
          state = .fileHost
        } else {
          state = .path
          pointer -= 1
        }
      case .fileHost:
        if atEnd || ch == 0x2f || ch == 0x5c || ch == 0x3f || ch == 0x23 {
          pointer -= 1
          if isWindowsDriveLetter(buffer) {
            state = .path
          } else if buffer.isEmpty {
            url.hostValue = .empty
            state = .pathStart
          } else {
            guard var host = parseHost(buffer, opaque: false) else { return nil }
            if host == .domain(Units("localhost")) { host = .empty }
            url.hostValue = host
            buffer = []
            state = .pathStart
          }
        } else {
          append(ch, &buffer)
        }
      case .pathStart:
        if url.isSpecial {
          state = .path
          if ch != 0x2f && ch != 0x5c { pointer -= 1 }
        } else if ch == 0x3f {
          url.query = []
          state = .query
        } else if ch == 0x23 {
          url.fragment = []
          state = .fragment
        } else if !atEnd {
          state = .path
          if ch != 0x2f { pointer -= 1 }
        }
      case .path:
        let slash = ch == 0x2f || (url.isSpecial && ch == 0x5c)
        if atEnd || slash || ch == 0x3f || ch == 0x23 {
          if isDoubleDot(buffer) {
            shorten(&url)
            if !slash { url.path.append([]) }
          } else if isSingleDot(buffer) && !slash {
            url.path.append([])
          } else if !isSingleDot(buffer) {
            if url.scheme == Units("file") && url.path.isEmpty && isWindowsDriveLetter(buffer) { buffer[1] = Unit.colon }
            url.path.append(buffer)
          }
          buffer = []
          if ch == 0x3f {
            url.query = []
            state = .query
          } else if ch == 0x23 {
            url.fragment = []
            state = .fragment
          }
        } else {
          encode(Unicode.Scalar(ch)!, inPathSet, into: &buffer)
        }
      case .opaquePath:
        if ch == 0x3f {
          url.query = []
          state = .query
        } else if ch == 0x23 {
          url.fragment = []
          state = .fragment
        } else if ch == 0x20 {
          let next = char(pointer + 1)
          url.opaquePath! += next == 0x3f || next == 0x23 ? Units("%20") : [Unit.space]
        } else if !atEnd {
          encode(Unicode.Scalar(ch)!, inC0Set, into: &url.opaquePath!)
        }
      case .query:
        if ch == 0x23 || atEnd {
          let set = url.isSpecial ? inSpecialQuerySet : inQuerySet
          var encoded = Units()
          for v in scalars(buffer) { encode(Unicode.Scalar(v)!, set, into: &encoded) }
          url.query = (url.query ?? []) + encoded
          buffer = []
          if ch == 0x23 {
            url.fragment = []
            state = .fragment
          }
        } else {
          append(ch, &buffer)
        }
      case .fragment:
        if !atEnd { encode(Unicode.Scalar(ch)!, inFragmentSet, into: &url.fragment!) }
      }
      if pointer >= c.count { break }
      pointer += 1
    }
    return url
  }

  static func parseHost(_ input: Units, opaque: Bool) -> WhatwgURL.Host? {
    if input.first == Unit.openBracket {
      guard input.last == Unit.closeBracket, input.count >= 2, let pieces = parseIPv6(Array(input[1..<(input.count - 1)])) else { return nil }
      return .ipv6(pieces)
    }
    if opaque {
      let s = scalars(input)
      for v in s where v != 0x25 && isForbiddenHost(v) { return nil }
      var out = Units()
      for v in s { encode(Unicode.Scalar(v)!, inC0Set, into: &out) }
      return out.isEmpty ? .empty : .opaque(out)
    }
    let domain = percentDecode(input)
    guard let ascii = domainToASCII(domain), !ascii.isEmpty else { return nil }
    if ascii.contains(where: { isForbiddenDomain(UInt32($0)) }) { return nil }
    if endsInNumber(ascii) {
      guard let v4 = parseIPv4(ascii) else { return nil }
      return .ipv4(v4)
    }
    return .domain(ascii)
  }

  static func serialize(_ host: WhatwgURL.Host) -> Units {
    switch host {
    case .domain(let d): return d
    case .opaque(let o): return o
    case .empty: return []
    case .ipv4(let v):
      return Units("\(v >> 24).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)")
    case .ipv6(let pieces):
      var bestStart = -1
      var bestLength = 1
      var i = 0
      while i < 8 {
        if pieces[i] == 0 {
          var j = i
          while j < 8 && pieces[j] == 0 { j += 1 }
          if j - i > bestLength {
            bestStart = i
            bestLength = j - i
          }
          i = j
        } else {
          i += 1
        }
      }
      var out = "["
      var ignore0 = false
      for k in 0..<8 {
        if ignore0 && pieces[k] == 0 { continue }
        ignore0 = false
        if k == bestStart {
          out += k == 0 ? "::" : ":"
          ignore0 = true
          continue
        }
        out += String(pieces[k], radix: 16)
        if k != 7 { out += ":" }
      }
      return Units(out + "]")
    }
  }

  private static func isForbiddenHost(_ c: UInt32) -> Bool {
    switch c {
    case 0x00, 0x09, 0x0a, 0x0d, 0x20, 0x23, 0x2f, 0x3a, 0x3c, 0x3e, 0x3f, 0x40, 0x5b, 0x5c, 0x5d, 0x5e, 0x7c: true
    default: false
    }
  }

  private static func isForbiddenDomain(_ c: UInt32) -> Bool { isForbiddenHost(c) || isC0Control(c) || c == 0x25 || c == 0x7f }

  private static func percentDecode(_ input: Units) -> String {
    let bytes = Array(input.string.utf8)
    var out: [UInt8] = []
    var i = 0
    func hexValue(_ b: UInt8) -> UInt8? {
      switch b {
      case 0x30...0x39: b - 0x30
      case 0x41...0x46: b - 0x41 + 10
      case 0x61...0x66: b - 0x61 + 10
      default: nil
      }
    }
    while i < bytes.count {
      if bytes[i] == 0x25, i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
        out.append(hi << 4 | lo)
        i += 3
      } else {
        out.append(bytes[i])
        i += 1
      }
    }
    return String(decoding: out, as: UTF8.self)
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
          guard let decoded = punycodeDecode(Array(units[4...])), !decoded.isEmpty, !decoded.utf16.allSatisfy({ $0 < 0x80 }), isValidLabel(decoded) else { return nil }
          out.append(Units("xn--" + punycodeEncode(decoded)))
        } else {
          out.append(units)
        }
      } else {
        guard !units.asciiCaseInsensitivePrefix("xn--"), isValidLabel(label) else { return nil }
        out.append(Units("xn--" + punycodeEncode(label)))
      }
    }
    return Array(out.joined(separator: [Unit.dot]))
  }

  private static func isValidLabel(_ label: String) -> Bool {
    guard label.precomposedStringWithCanonicalMapping.sameUnits(label), let first = label.unicodeScalars.first else { return false }
    if [.nonspacingMark, .spacingMark, .enclosingMark].contains(first.properties.generalCategory) { return false }
    for scalar in label.unicodeScalars where scalar.value >= 0x80 {
      switch scalar.properties.generalCategory {
      case .unassigned, .control, .privateUse, .surrogate, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator: return false
      default: break
      }
      if scalar.value == 0xfffd || scalar.properties.isNoncharacterCodePoint { return false }
      let one = String(scalar)
      if !JS.lower(one.precomposedStringWithCompatibilityMapping).sameUnits(one) { return false }
    }
    return true
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
      value = min(value &* radix &+ d, UInt64(1) << 40)
    }
    return value
  }

  private static func parseIPv4(_ host: Units) -> UInt32? {
    var parts = host.split(separator: Unit.dot, omittingEmptySubsequences: false).map(Array.init)
    if parts.last?.isEmpty == true && parts.count > 1 { parts.removeLast() }
    if parts.count > 4 { return nil }
    var numbers: [UInt64] = []
    for part in parts {
      guard let n = ipv4Number(part) else { return nil }
      numbers.append(n)
    }
    for n in numbers.dropLast() where n > 255 { return nil }
    let last = numbers.last!
    if last >= UInt64(1) << (8 * UInt64(5 - numbers.count)) { return nil }
    var value = last
    for (i, n) in numbers.dropLast().enumerated() { value += n << (8 * UInt64(3 - i)) }
    return UInt32(value)
  }

  private static func parseIPv6(_ input: Units) -> [UInt16]? {
    var address = [UInt16](repeating: 0, count: 8)
    var pieceIndex = 0
    var compress: Int?
    var i = 0
    let n = input.count
    func hexDigit(_ c: UInt16) -> UInt16? {
      switch c {
      case 0x30...0x39: c - 0x30
      case 0x61...0x66: c - 0x61 + 10
      case 0x41...0x46: c - 0x41 + 10
      default: nil
      }
    }
    if i < n && input[i] == Unit.colon {
      guard i + 1 < n, input[i + 1] == Unit.colon else { return nil }
      i += 2
      pieceIndex += 1
      compress = pieceIndex
    }
    while i < n {
      if pieceIndex == 8 { return nil }
      if input[i] == Unit.colon {
        if compress != nil { return nil }
        i += 1
        pieceIndex += 1
        compress = pieceIndex
        continue
      }
      var value: UInt16 = 0
      var length = 0
      while length < 4 && i < n, let d = hexDigit(input[i]) {
        value = value * 0x10 + d
        i += 1
        length += 1
      }
      if i < n && input[i] == Unit.dot {
        if length == 0 { return nil }
        i -= length
        if pieceIndex > 6 { return nil }
        var numbersSeen = 0
        while i < n {
          var piece: Int?
          if numbersSeen > 0 {
            if input[i] == Unit.dot && numbersSeen < 4 { i += 1 } else { return nil }
          }
          guard i < n, Unit.isDigit(input[i]) else { return nil }
          while i < n && Unit.isDigit(input[i]) {
            let d = Int(input[i] - Unit.zero)
            if piece == nil {
              piece = d
            } else if piece == 0 {
              return nil
            } else {
              piece = piece! * 10 + d
            }
            if piece! > 255 { return nil }
            i += 1
          }
          address[pieceIndex] = address[pieceIndex] &* 0x100 &+ UInt16(piece!)
          numbersSeen += 1
          if numbersSeen == 2 || numbersSeen == 4 { pieceIndex += 1 }
        }
        if numbersSeen != 4 { return nil }
        break
      } else if i < n && input[i] == Unit.colon {
        i += 1
        if i >= n { return nil }
      } else if i < n {
        return nil
      }
      address[pieceIndex] = value
      pieceIndex += 1
    }
    if let compress {
      var swaps = pieceIndex - compress
      pieceIndex = 7
      while pieceIndex != 0 && swaps > 0 {
        address.swapAt(pieceIndex, compress + swaps - 1)
        pieceIndex -= 1
        swaps -= 1
      }
    } else if pieceIndex != 8 {
      return nil
    }
    return address
  }
}

enum WhatwgUrl {
  static func httpHostname(_ raw: Units) -> Units? {
    guard let url = WhatwgParser.parse(raw), url.scheme == Units("http") || url.scheme == Units("https"), let host = url.hostValue else { return nil }
    return WhatwgParser.serialize(host)
  }
}
