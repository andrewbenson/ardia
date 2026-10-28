import Foundation
import SolaraModel
import SolaraSync
import Testing

@Suite struct LedgerReplayTests {
  func logins(_ json: JSONValue?) -> OrderedDict<String, LocalLogin> {
    var out = OrderedDict<String, LocalLogin>()
    for pair in json?.array ?? [] {
      guard let key = pair.array?.first?.string, let value = LedgerValue(json: pair.array?.last?["value"] ?? .null) else { continue }
      out[key] = LocalLogin(value: value, modified: pair.array?.last?["modified"]?.number ?? 0)
    }
    return out
  }

  func records(_ json: JSONValue?) -> OrderedDict<String, LedgerRecord> {
    var out = OrderedDict<String, LedgerRecord>()
    for pair in json?.array ?? [] {
      guard let key = pair.array?.first?.string else { continue }
      out[key] = LedgerRecord(v: LedgerValue(json: pair.array?.last?["v"] ?? .null), h: pair.array?.last?["h"]?.string ?? "")
    }
    return out
  }

  func mark(_ json: JSONValue?) -> Mark? {
    guard let json, !json.isNull else { return nil }
    return Mark(L: json["L"]?.number ?? 0, t: json["t"]?.number ?? 0)
  }

  func output(_ input: JSONValue) -> JSONValue {
    let local = logins(input["local"])
    let folder = records(input["records"])
    let ledger = input["ledger"].flatMap { $0.isNull ? nil : Ledger(json: $0) }
    var agreed = OrderedDict<String, LedgerValue>()
    for pair in input["agreed"]?.array ?? [] {
      guard let key = pair.array?.first?.string, let value = LedgerValue(json: pair.array?.last ?? .null) else { continue }
      agreed[key] = value
    }
    let unapplied = input["unapplied"]?.array?.compactMap(\.string) ?? []
    let judged = judge(
      local, mark(input["mark"]), ledger, folder, input["now"]?.number ?? 0, agreedHere: { agreed[$0] },
      unapplied: { key in unapplied.contains(where: { $0.jsEquals(key) }) })
    let next = nextLedger(
      ledger, local, folder, mark(input["nextMark"])!, input["nextKeys"]?.array?.compactMap(\.string) ?? [],
      deletedBeforeUpgrade: judged.deletedBeforeUpgrade.elements)
    let markText = mark(input["mark"]).map(formatMark) ?? ""
    let ledgerText = input["ledgerText"].flatMap { $0.isNull ? nil : $0.string }
    let ledgerDoc: JSONValue =
      switch readLedgerDocument(ledgerText) {
      case .doc(let object): .object(object)
      case .older: "older"
      case .newer: "newer"
      case .unreadable: "unreadable"
      }
    return [
      "ledgerDoc": ledgerDoc,
      "judge": [
        "mode": .string(judged.mode.rawValue), "claims": .array(judged.claims.map(\.json)), "apply": JSONValue(judged.apply.elements),
        "seed": JSONValue(judged.seed.elements), "deletedBeforeUpgrade": JSONValue(judged.deletedBeforeUpgrade.elements),
      ],
      "next": next.json,
      "digests": JSONValue(local.values.map { digestOf($0.value) }),
      "mark": ["text": .string(markText), "parsed": parseMark(markText)?.json ?? .null, "junk": parseMark(markText + "x")?.json ?? .null],
    ]
  }

  @Test func everyLedgerCaseMatchesPasswordLedgerTs() throws {
    let cases = try Cases.load("ledger")
    #expect(cases.count >= 600)
    var bad = 0
    for (i, item) in cases.enumerated() {
      let got = output(item["input"] ?? .null).text()
      let expected = (item["output"] ?? .null).text()
      if got != expected {
        bad += 1
        if bad <= 3 { Issue.record("case \(i)\n  ts:    \(expected.prefix(900))\n  swift: \(got.prefix(900))") }
      }
    }
    #expect(bad == 0, "\(bad) of \(cases.count) ledger cases differ")
  }

  @Test func aLedgerFromANewerVersionIsRefusedAndAStoredLedgerKeepsItsOtherKeys() throws {
    #expect(readLedgerDocument(DocumentRead.failure("EIO")) == .unreadable)
    #expect(readLedgerDocument(DocumentRead.missing) == .doc(["v": 2, "profiles": .object(JSONObject())]))
    let stored = try JSONValue.parse(#"{"v":1,"L":2,"t":3,"keys":{},"scope":"s","held":["pw:a"],"gated":{"pw:b":5},"later":1}"#)
    #expect(Ledger(json: stored).json.text() == stored.text(), "scope, held, gated and unknown keys are kept")
  }

  @Test func aLedgerEntryKeepsFieldsItDoesntKnow() throws {
    let stored = try JSONValue.parse(#"{"v":1,"L":1,"t":1,"keys":{"pw:k":{"d":["a"],"h":null,"m":1,"extra":true}}}"#)
    #expect(Ledger(json: stored).json.text() == stored.text())
  }
}
