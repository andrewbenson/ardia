import Foundation
import SolaraModel
@testable import SolaraSync
import Testing

private final class WritesOne: SyncAdapter {
  let prefix = "pw:"
  let writes: String

  init(writes: String) { self.writes = writes }

  func extract(_ context: ExtractContext) async throws -> Extraction? { nil }

  func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? { nil }

  func applyKeys(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws
    -> ApplyOutcome
  {
    .written(changed.filter { $0.jsEquals(writes) })
  }
}

struct JSIdentityTests {
  let nfc = "pw:https://a.example\njos\u{e9}"
  let nfd = "pw:https://a.example\njose\u{301}"

  @Test func aKeyTheAdapterSkippedStaysUnappliedWhenItsCanonicalTwinWasWritten() async {
    let state = ScopeState()
    state.joined = true
    for key in [nfc, nfd] { state.records[key] = SyncRecord(h: "1", v: ["o": "https://a.example", "u": .string(key), "s": "x"], o: Origin("b", 1)) }
    let left = await applyAdapter(state, WritesOne(writes: nfc), OrderedSet([nfc, nfd]), 0, 0, true, nil)
    #expect(left.count == 1 && left[0].jsEquals(nfd), "the login that isn't here is left to apply again")
    #expect(state.base[nfc] != nil)
    #expect(state.base[nfd] == nil, "its base isn't set, so the next cycle can't read the missing login as a deletion here")
  }

  @Test func prefixesCompareAsJSStartsWithDoes() {
    #expect("x:\u{301}abc".jsStartsWith("x:"))
    #expect(!"caf\u{e9}!".jsStartsWith("cafe\u{301}"))
  }

  @Test func syncSourcesKeepJSIdentity() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/SolaraSync").standardized
    let forbidden = [#"\.hasPrefix\("#, #"\.hasSuffix\("#, #"(?<![A-Za-z])Set<String>"#, "uniquingKeysWith", #"(?<![A-Za-z])Set\(changed\)"#, #"unapplied\.contains\(key\)"#, #"dropFirst\(\w+\.count\)"#]
    var found: [String] = []
    for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
      let lines = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8).components(separatedBy: "\n")
      for (n, line) in lines.enumerated() {
        for pattern in forbidden where line.range(of: pattern, options: .regularExpression) != nil { found.append("\(file):\(n + 1): \(pattern)") }
      }
    }
    #expect(found.isEmpty, "Swift compares these by canonical equivalence and JS by UTF-16 units; use jsStartsWith, jsEquals, JSKey or OrderedSet: \(found)")
  }
}
