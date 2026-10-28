import Foundation
import SolaraModel
import SolaraSync
import Testing

final class MemoryDisk: JournalDisk {
  var docs = [String: String]()
  var writes: [JSONValue] = []

  func read(_ name: String) -> String? { docs[name] }

  func write(_ name: String, _ text: String) {
    docs[name] = text
    writes.append([.string(name), .string(text)])
  }
}

@Suite struct JournalReplayTests {
  func steps(_ script: JSONValue) -> JSONValue {
    let disk = MemoryDisk()
    if let text = script["journal"]?.string { disk.docs[journalDocName] = text }
    if let text = script["gen"]?.string { disk.docs[genDocName] = text }
    let storeG = script["storeG"]?.number ?? 0
    let journal = EditJournal(disk: disk, storeG: storeG, storeT: script["storeT"]?.number ?? 0)
    let probes = (script["probes"]?.array ?? []).map { ($0.array?.first?.string ?? "", $0.array?.last?.string ?? "") }
    var scopes = OrderedSet<String>()
    for (scope, _) in probes { _ = scopes.insert(scope) }
    func report() -> JSONValue {
      let state: JSONObject = [
        "lost": .bool(journal.lost), "fallback": .string(journal.fallback.rawValue), "inStep": journal.inStep?.json ?? .null,
        "g": .number(journal.g), "lastInStepT": .number(journal.lastInStepT),
        "probes": .array(probes.map { journal.entry($0.0, $0.1) ?? .null }),
        "entries": .array(scopes.elements.map { scope in .array(journal.entries(scope).map { .array([.string($0.key), $0.value]) }) }),
        "writes": .array(disk.writes),
      ]
      disk.writes = []
      return .object(state)
    }
    var out = [report()]
    for call in script["calls"]?.array ?? [] {
      switch call["op"]?.string {
      case "record": journal.record(call["scope"]?.string ?? "", call["key"]?.string ?? "", call["entry"] ?? .null)
      case "clear": journal.clear(call["scope"]?.string ?? "", call["key"]?.string ?? "", call["h"]?.string ?? "")
      default: journal.inStepAt(call["at"]?.number ?? 0, call["vv"] ?? .null)
      }
      out.append(report())
    }
    return .array(out)
  }

  func union(_ input: JSONValue) -> JSONValue {
    var records = OrderedDict<String, (v: JSONValue, o: Origin)>()
    for pair in input["records"]?.array ?? [] {
      guard let key = pair.array?.first?.string, let record = pair.array?.last else { continue }
      let o = record["o"]?.array ?? []
      records[key] = (record["v"] ?? .null, Origin(o.first?.string ?? "", o.last?.number ?? 0))
    }
    let local = (input["local"]?.array ?? []).map { (key: $0.array?.first?.string ?? "", value: $0.array?.last ?? .null) }
    let result = unionFallback(
      scope: input["scope"]?.string ?? "", T: input["T"]?.number ?? 0, vvT: input["vvT"] ?? .null, local: local, records: records,
      everSeen: Set(input["everSeen"]?.array?.compactMap(\.string) ?? []), tombstoned: Set(input["tombstoned"]?.array?.compactMap(\.string) ?? []))
    return [
      "publish": .array(result.publish.map { .array([.string($0.key), ["v": $0.v, "at": .number($0.at)]]) }),
      "apply": JSONValue(result.apply.elements), "publishDeletions": .bool(result.publishDeletions),
    ]
  }

  @Test func everyJournalScriptMatchesEditJournalTs() throws {
    let data = try (Data(contentsOf: Cases.folder.appending(path: "journal.json.deflate")) as NSData).decompressed(using: .zlib) as Data
    let all = try JSONValue.parse(data)
    let cases = all["cases"]?.array ?? []
    let unions = all["unions"]?.array ?? []
    #expect(cases.count >= 1500 && unions.count >= 1500)
    var bad = 0
    for (i, item) in cases.enumerated() {
      let got = steps(item["script"] ?? .null).text()
      let expected = (item["steps"] ?? .null).text()
      if got != expected {
        bad += 1
        if bad <= 3 { Issue.record("script \(i)\n  ts:    \(expected.prefix(1200))\n  swift: \(got.prefix(1200))") }
      }
    }
    for (i, item) in unions.enumerated() {
      let got = union(item["input"] ?? .null).text()
      let expected = (item["output"] ?? .null).text()
      if got != expected {
        bad += 1
        if bad <= 3 { Issue.record("union \(i)\n  ts:    \(expected)\n  swift: \(got)") }
      }
    }
    #expect(bad == 0, "\(bad) journal cases differ")
  }
}
