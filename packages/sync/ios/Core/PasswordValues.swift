import Foundation

public enum PasswordValues {
  public enum Shape: Sendable {
    case folderFile
    case state
    case journal
  }

  public enum Direction: Sendable {
    case seal
    case open
  }

  public struct Refused: Error, Equatable, CustomStringConvertible {
    public let key: String
    public let reason: String
    public var description: String { "\(key.firstIndex(of: ":").map { String(key[...$0]) } ?? key) \(reason)" }
  }

  public static let unmatched = "v1:unmatched"

  public static func convert(_ text: String, _ shape: Shape, _ direction: Direction, keys: SyncKeys) throws -> String {
    let bytes = Array(text.utf8)
    var scanner = JSONScanner(bytes)
    let root = try scanner.document()
    var edits: [(Range<Int>, String)] = []
    let context = Context(keys: keys, direction: direction)
    switch shape {
    case .folderFile: try context.folderFile(root, &edits)
    case .state: try context.state(root, &edits)
    case .journal: try context.journal(root, &edits)
    }
    var out = bytes
    for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
      out.replaceSubrange(range, with: Array(replacement.utf8))
    }
    return String(decoding: out, as: UTF8.self)
  }

  public static func plainValues(_ text: String, _ shape: Shape) throws -> Bool {
    var scanner = JSONScanner(Array(text.utf8))
    let root = try scanner.document()
    var found = false
    func visit(_ value: JSONSpan?) {
      guard case .object(let members) = value?.kind else { return }
      if members.contains(where: { $0.key == "p" }) { found = true }
    }
    for (key, value) in Context.passwordValues(root, shape) where key.hasPrefix("pw:") { visit(value) }
    guard shape == .state else { return found }
    for scope in root.members ?? [] {
      for base in scope.value.member("base")?.members ?? [] where base.key.hasPrefix("pw:") {
        guard let inner = base.value.text else { continue }
        var innerScanner = JSONScanner(Array(inner.utf8))
        visit(try? innerScanner.document())
      }
    }
    return found
  }

  struct Context {
    let keys: SyncKeys
    let direction: Direction

    static func passwordValues(_ root: JSONSpan, _ shape: Shape) -> [(String, JSONSpan?)] {
      var out: [(String, JSONSpan?)] = []
      func ops(_ list: JSONSpan?) {
        for op in list?.items ?? [] { if let k = op.member("k")?.text { out.append((k, op.member("v"))) } }
      }
      func batches(_ list: JSONSpan?) { for batch in list?.items ?? [] { ops(batch.member("ops")) } }
      switch shape {
      case .folderFile:
        ops(root.member("ops"))
        for record in root.member("records")?.members ?? [] { out.append((record.key, record.value.member("v"))) }
      case .state:
        for scope in root.members ?? [] {
          for record in scope.value.member("records")?.members ?? [] { out.append((record.key, record.value.member("v"))) }
          ops(scope.value.member("outbox"))
          ops(scope.value.member("heldOutbox"))
          batches(scope.value.member("journal"))
        }
      case .journal:
        for list in root.member("journal")?.members ?? [] { batches(list.value) }
      }
      return out
    }

    func folderFile(_ root: JSONSpan, _ edits: inout [(Range<Int>, String)]) throws {
      for (key, value) in Self.passwordValues(root, .folderFile) where key.hasPrefix("pw:") { try convertValue(key, value, &edits) }
    }

    func journal(_ root: JSONSpan, _ edits: inout [(Range<Int>, String)]) throws {
      for (key, value) in Self.passwordValues(root, .journal) where key.hasPrefix("pw:") { try convertValue(key, value, &edits) }
    }

    func state(_ root: JSONSpan, _ edits: inout [(Range<Int>, String)]) throws {
      for (key, value) in Self.passwordValues(root, .state) where key.hasPrefix("pw:") { try convertValue(key, value, &edits) }
      for scope in root.members ?? [] {
        var plainBase: [CodeUnits: String] = [:]
        for base in scope.value.member("base")?.members ?? [] where base.key.hasPrefix("pw:") {
          guard let inner = base.value.text else { continue }
          let converted = try convertCanonical(base.key, inner)
          plainBase[CodeUnits(base.key)] = inner
          if converted != inner { edits.append((base.value.range, PasswordText.jsonString(converted))) }
        }
        guard direction == .seal, let noted = scope.value.member("rebuild")?.member("noted")?.member("pw:") else { continue }
        var plainRecords: [CodeUnits: String] = [:]
        for record in scope.value.member("records")?.members ?? [] where record.key.hasPrefix("pw:") {
          if let value = record.value.member("v"), let canonical = canonicalPlain(value) { plainRecords[CodeUnits(record.key)] = canonical }
        }
        for digest in noted.members ?? [] {
          guard let current = digest.value.text else { continue }
          let candidates = [plainBase[CodeUnits(digest.key)], plainRecords[CodeUnits(digest.key)]].compactMap { $0 }
          let match = candidates.first { PasswordText.notedDigest($0) == current }
          let next = try match.map { PasswordText.notedDigest(try convertCanonical(digest.key, $0)) } ?? PasswordValues.unmatched
          if next != current { edits.append((digest.value.range, PasswordText.jsonString(next))) }
        }
      }
    }

    func canonicalPlain(_ value: JSONSpan) -> String? {
      guard let fields = loginFields(value), let p = fields.p else { return nil }
      return PasswordText.canonical(origin: fields.o, username: fields.u, password: p)
    }

    func loginFields(_ value: JSONSpan) -> (o: String, u: String, p: String?, s: String?)? {
      guard let members = value.members, let o = value.member("o")?.text, let u = value.member("u")?.text else { return nil }
      guard members.allSatisfy({ ["o", "u", "p", "s"].contains($0.key) }), Set(members.map { CodeUnits($0.key) }).count == members.count else { return nil }
      return (o, u, value.member("p")?.text, value.member("s")?.text)
    }

    func convertCanonical(_ key: String, _ inner: String) throws -> String {
      var scanner = JSONScanner(Array(inner.utf8))
      guard let value = try? scanner.document() else { return inner }
      guard let fields = loginFields(value) else {
        if value.member("p") != nil { throw Refused(key: key, reason: "a plain password in a value it can't convert") }
        return inner
      }
      switch direction {
      case .seal:
        guard value.member("p") != nil else { return inner }
        guard let p = fields.p, fields.s == nil else { throw Refused(key: key, reason: "a plain password it can't seal") }
        return PasswordText.canonical(origin: fields.o, username: fields.u, sealed: try keys.sealPassword(p, origin: fields.o, username: fields.u))
      case .open:
        if fields.p != nil { throw Refused(key: key, reason: "a plain password where a sealed one belongs") }
        guard let s = fields.s else { return inner }
        guard let p = try? keys.openPassword(s, origin: fields.o, username: fields.u) else { throw Refused(key: key, reason: "a sealed password that doesn't open") }
        return PasswordText.canonical(origin: fields.o, username: fields.u, password: p)
      }
    }

    func convertValue(_ key: String, _ value: JSONSpan?, _ edits: inout [(Range<Int>, String)]) throws {
      guard let value, let members = value.members else { return }
      guard let fields = loginFields(value) else {
        if value.member("p") != nil { throw Refused(key: key, reason: "a plain password in a value it can't convert") }
        return
      }
      switch direction {
      case .seal:
        guard let member = members.first(where: { $0.key == "p" }) else { return }
        guard let p = fields.p, fields.s == nil else { throw Refused(key: key, reason: "a plain password it can't seal") }
        let sealed = try keys.sealPassword(p, origin: fields.o, username: fields.u)
        edits.append((member.keyRange, "\"s\""))
        edits.append((member.value.range, PasswordText.jsonString(sealed)))
      case .open:
        if fields.p != nil { throw Refused(key: key, reason: "a plain password where a sealed one belongs") }
        guard let s = fields.s, let member = members.first(where: { $0.key == "s" }) else { return }
        guard let p = try? keys.openPassword(s, origin: fields.o, username: fields.u) else { throw Refused(key: key, reason: "a sealed password that doesn't open") }
        edits.append((member.keyRange, "\"p\""))
        edits.append((member.value.range, PasswordText.jsonString(p)))
      }
    }
  }
}

struct JSONSpan {
  enum Kind {
    case object([(key: String, keyRange: Range<Int>, value: JSONSpan)])
    case array([JSONSpan])
    case string(String)
    case other
  }

  let range: Range<Int>
  let kind: Kind

  var members: [(key: String, keyRange: Range<Int>, value: JSONSpan)]? {
    if case .object(let members) = kind { return members }
    return nil
  }

  var items: [JSONSpan]? {
    if case .array(let items) = kind { return items }
    return nil
  }

  var text: String? {
    if case .string(let text) = kind { return text }
    return nil
  }

  func member(_ key: String) -> JSONSpan? { members?.last(where: { $0.key.utf16.elementsEqual(key.utf16) })?.value }
}

struct JSONScanner {
  struct Malformed: Error {}

  let bytes: [UInt8]
  var at = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  mutating func document() throws -> JSONSpan {
    let value = try self.value()
    skipSpace()
    guard at == bytes.count else { throw Malformed() }
    return value
  }

  mutating func skipSpace() {
    while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
  }

  mutating func value() throws -> JSONSpan {
    skipSpace()
    guard at < bytes.count else { throw Malformed() }
    let start = at
    switch bytes[at] {
    case UInt8(ascii: "{"):
      at += 1
      var members: [(key: String, keyRange: Range<Int>, value: JSONSpan)] = []
      skipSpace()
      if at < bytes.count, bytes[at] == UInt8(ascii: "}") {
        at += 1
        return JSONSpan(range: start..<at, kind: .object(members))
      }
      while true {
        skipSpace()
        let keyStart = at
        let key = try string()
        let keyRange = keyStart..<at
        skipSpace()
        guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw Malformed() }
        at += 1
        members.append((key, keyRange, try value()))
        skipSpace()
        guard at < bytes.count else { throw Malformed() }
        if bytes[at] == UInt8(ascii: ",") {
          at += 1
          continue
        }
        guard bytes[at] == UInt8(ascii: "}") else { throw Malformed() }
        at += 1
        return JSONSpan(range: start..<at, kind: .object(members))
      }
    case UInt8(ascii: "["):
      at += 1
      var items: [JSONSpan] = []
      skipSpace()
      if at < bytes.count, bytes[at] == UInt8(ascii: "]") {
        at += 1
        return JSONSpan(range: start..<at, kind: .array(items))
      }
      while true {
        items.append(try value())
        skipSpace()
        guard at < bytes.count else { throw Malformed() }
        if bytes[at] == UInt8(ascii: ",") {
          at += 1
          continue
        }
        guard bytes[at] == UInt8(ascii: "]") else { throw Malformed() }
        at += 1
        return JSONSpan(range: start..<at, kind: .array(items))
      }
    case UInt8(ascii: "\""):
      let text = try string()
      return JSONSpan(range: start..<at, kind: .string(text))
    default:
      while at < bytes.count, !([UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[at])) { at += 1 }
      guard at > start else { throw Malformed() }
      return JSONSpan(range: start..<at, kind: .other)
    }
  }

  mutating func string() throws -> String {
    guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw Malformed() }
    at += 1
    var units: [UInt16] = []
    var run = at
    func flush(_ end: Int) { units += String(decoding: bytes[run..<end], as: UTF8.self).utf16 }
    while at < bytes.count {
      let byte = bytes[at]
      if byte == UInt8(ascii: "\"") {
        flush(at)
        at += 1
        return String(decoding: units, as: UTF16.self)
      }
      if byte == UInt8(ascii: "\\") {
        flush(at)
        at += 1
        guard at < bytes.count else { throw Malformed() }
        switch bytes[at] {
        case UInt8(ascii: "\""): units.append(0x22)
        case UInt8(ascii: "\\"): units.append(0x5C)
        case UInt8(ascii: "/"): units.append(0x2F)
        case UInt8(ascii: "b"): units.append(0x08)
        case UInt8(ascii: "f"): units.append(0x0C)
        case UInt8(ascii: "n"): units.append(0x0A)
        case UInt8(ascii: "r"): units.append(0x0D)
        case UInt8(ascii: "t"): units.append(0x09)
        case UInt8(ascii: "u"):
          guard at + 4 < bytes.count, let unit = UInt16(String(decoding: bytes[(at + 1)...(at + 4)], as: UTF8.self), radix: 16) else { throw Malformed() }
          units.append(unit)
          at += 4
        default: throw Malformed()
        }
        at += 1
        run = at
        continue
      }
      at += 1
    }
    throw Malformed()
  }
}
