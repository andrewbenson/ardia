import Foundation
import SolaraModel
import SolaraSync
import Testing

enum Cases {
  static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Cases")

  static func load(_ name: String) throws -> [JSONValue] {
    let data = try (Data(contentsOf: folder.appending(path: "\(name).json.deflate")) as NSData).decompressed(using: .zlib) as Data
    return try JSONValue.parse(data)["cases"]?.array ?? []
  }
}

@Suite struct StateDecodeTests {
  @Test func everyStateCaseGetsTheEnginesVerdicts() throws {
    let cases = try Cases.load("state")
    #expect(cases.count >= 3000)
    var bad = 0
    for (i, item) in cases.enumerated() {
      let value = item["value"] ?? .null
      let object = value.object
      let got: JSONValue = [
        "scope": .bool(readableScope(value)),
        "batch": .bool(readableBatch(object?["journal"]?.array?.first ?? (object?["journal"]?.array != nil ? nil : value))),
        "rebuild": .bool(readableRebuild(object != nil ? object!["rebuild"] : value)),
        "record": .bool(readableRecord(object?["records"]?.object.map { $0.values.first } ?? value)),
        "op": .bool(readableOp(object?["outbox"]?.array.map { $0.first } ?? value)),
      ]
      if got.text() != (item["verdicts"] ?? .null).text() {
        bad += 1
        if bad <= 3 { Issue.record("case \(i): ts \((item["verdicts"] ?? .null).text()) swift \(got.text())\n  \(value.text().prefix(600))") }
      }
    }
    #expect(bad == 0, "\(bad) of \(cases.count) state cases differ")
  }

  func validState() throws -> JSONValue {
    try JSONValue.parse(
      #"{"records":{},"base":{},"unapplied":[],"vv":{},"extra":{},"files":{},"damaged":{},"seq":4,"outbox":[],"seen":{},"joined":true,"snapshotAt":0,"pending":0}"#)
  }

  @Test func aScopeWithoutItsSeqIsRejectedNotReadAsZero() throws {
    var object = try validState().object!
    #expect(readableScope(.object(object)))
    object.removeValue(forKey: "seq")
    #expect(!readableScope(.object(object)), "a scope that lost seq would reuse seqs other Macs already cover")
    object["seq"] = "4"
    #expect(!readableScope(.object(object)))
  }

  @Test func keysTheMergeDoesntKnowSurviveARoundTrip() throws {
    var object = try validState().object!
    object["rebuild"] = ["since": 5, "noted": ["pw:": ["pw:a\nb": "4.abc"]]]
    object["heldOutbox"] = [["k": "x:1", "h": "000000001.0000.dev1", "v": 1]]
    object["rebuildBaseline"] = ["x": [1, 2]]
    object["fromANewerVersion"] = ["kept": true]
    let state = ScopeState(json: .object(object))
    let back = state.json.object!
    for key in ["rebuild", "heldOutbox", "rebuildBaseline", "fromANewerVersion"] { #expect(back[key] == object[key], "\(key) is kept") }
    #expect(syncCanonical(ScopeState(json: state.json).json) == syncCanonical(state.json))
  }

  @Test func aSyncDocFromANewerVersionIsRefused() throws {
    #expect(syncDocIsNewer(try JSONValue.parse(#"{"v":2}"#)))
    #expect(syncDocIsNewer(try JSONValue.parse(#"{"enabled":true}"#)))
    #expect(!syncDocIsNewer(try JSONValue.parse(#"{"v":1}"#)))
    #expect(!syncDocIsNewer(try JSONValue.parse("[1]")))
  }

  final class CapturingTransport: SyncTransport, @unchecked Sendable {
    var payloads: [String] = []
    func write(_ scope: String, _ payload: String) async throws -> String {
      payloads.append(payload)
      return "f\(payloads.count)"
    }
    func read(_ scope: String, _ known: [String]) async throws -> Listing { Listing(files: [], pending: [], damaged: [], present: []) }
    func remove(_ scope: String, _ ids: [String]) async throws {}
  }

  @Test func aCrashedBatchFromANewerVersionIsResentWithTheFieldsItCarried() async throws {
    let saved = try JSONValue.parse(
      #"{"v":1,"kind":"log","device":"dev1","seq":1,"at":5,"ops":[{"k":"x:1","h":"000000005.0000.dev1","v":1,"why":"edit"}],"chain":"c1"}"#)
    let state = ScopeState()
    let clock = Clock(device: "dev1", now: { 10 })
    restoreJournal(state, [LogFile(json: saved)], clock)
    let transport = CapturingTransport()
    try await flush(state, transport, "s", "dev1", 10)
    #expect(transport.payloads.count == 1)
    #expect(syncCanonical(try JSONValue.parse(transport.payloads[0])) == syncCanonical(saved), "the re-sent batch is the batch that took the seq, field for field")
  }

  @Test func recordsAndFileEntriesKeepTheirUnknownFieldsThroughSavedState() throws {
    var object = try validState().object!
    object["records"] = ["x:1": ["h": "000000005.0000.dev1", "v": 1, "o": ["dev1", 1], "chain": "c1"]]
    object["files"] = ["f1": ["d": "dev1", "k": "log", "s": 1, "at": 5, "chain": "c1"]]
    object["outbox"] = [["k": "x:2", "h": "000000006.0000.dev1", "v": 2, "why": "edit"]]
    let back = ScopeState(json: .object(object)).json
    for key in ["records", "files", "outbox"] {
      #expect(syncCanonical(back[key] ?? .null) == syncCanonical(object[key] ?? .null), "\(key) keeps its unknown fields")
    }
  }
}
