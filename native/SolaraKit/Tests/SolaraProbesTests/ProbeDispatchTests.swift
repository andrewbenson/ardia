#if SOLARA_PROBES
import Foundation
import Testing
@testable import SolaraProbes

struct ProbeDispatchTests {
  @Test func capsSynchronousSnapshotsPerPoll() {
    var budget = ProbePollBudget()
    let savedLogin = budget.takeSynchronousSnapshot(hasSavedLogin: true)
    #expect(!savedLogin)
    for _ in 0..<4 {
      let admitted = budget.takeSynchronousSnapshot(hasSavedLogin: false)
      #expect(admitted)
    }
    let overflow = budget.takeSynchronousSnapshot(hasSavedLogin: false)
    let savedLoginAfterLimit = budget.takeSynchronousSnapshot(hasSavedLogin: true)
    #expect(!overflow)
    #expect(!savedLoginAfterLimit)
    var nextPoll = ProbePollBudget()
    let next = nextPoll.takeSynchronousSnapshot(hasSavedLogin: false)
    #expect(next)
  }

  @Test func admitsOnlyDefaultModeWithoutModalOrSheets() throws {
    try ProbeActionAdmission.check(mode: .default, hasModalWindow: false, hasAttachedSheet: false, hasSheetParent: false)
    let modes: [RunLoop.Mode?] = [nil, .common, RunLoop.Mode("NSEventTrackingRunLoopMode"), RunLoop.Mode("NSModalPanelRunLoopMode")]
    for mode in modes {
      #expect(throws: ProbeFailure.notReady) {
        try ProbeActionAdmission.check(mode: mode, hasModalWindow: false, hasAttachedSheet: false, hasSheetParent: false)
      }
    }
    for flags in [(true, false, false), (false, true, false), (false, false, true)] {
      #expect(throws: ProbeFailure.notReady) {
        try ProbeActionAdmission.check(mode: .default, hasModalWindow: flags.0, hasAttachedSheet: flags.1, hasSheetParent: flags.2)
      }
    }
  }

  @Test func gatesAfterEncodingAndSuppressesRevokedReplies() {
    var allowed = true
    var encoded = false
    #expect(throws: ProbeFailure.testHooksDenied) {
      try ProbeReply.encode(success(), id: "test", expiresAtMs: 100, checkGate: {
        #expect(encoded)
        guard allowed else { throw ProbeFailure.testHooksDenied }
      }, nowMs: { 0 }, encodeJSON: { value in
        encoded = true
        allowed = false
        return try JSONSerialization.data(withJSONObject: value)
      })
    }
  }

  @Test func convertsSuccessExpiringDuringEncodingToTimeout() throws {
    var time: Int64 = 0
    var gates = 0
    let data = try ProbeReply.encode(success(), id: "test", expiresAtMs: 100, checkGate: { gates += 1 }, nowMs: { time }, encodeJSON: { value in
      time = 100
      return try JSONSerialization.data(withJSONObject: value)
    })
    #expect(try errorCode(data) == ProbeFailure.timeout.code)
    #expect(gates == 2)
  }

  @Test func checksGateAfterTimeoutEncoding() {
    var encodings = 0
    #expect(throws: ProbeFailure.testHooksDenied) {
      try ProbeReply.encode(success(), id: "test", expiresAtMs: 100, checkGate: {
        guard encodings < 2 else { throw ProbeFailure.testHooksDenied }
      }, nowMs: { 100 }, encodeJSON: { value in
        encodings += 1
        return try JSONSerialization.data(withJSONObject: value)
      })
    }
    #expect(encodings == 2)
  }

  @Test func preservesErrorsAfterExpiry() throws {
    let value: [String: Any] = ["id": "test", "protocol": 1, "error": ["code": ProbeFailure.notReady.code]]
    let data = try ProbeReply.encode(value, id: "test", expiresAtMs: 100, checkGate: {}, nowMs: { 100 })
    #expect(try errorCode(data) == ProbeFailure.notReady.code)
  }

  @Test func preservesAllowedSuccessAndOptionalExpiry() throws {
    for expiry: Int64? in [nil, 101] {
      let data = try ProbeReply.encode(success(), id: "test", expiresAtMs: expiry, checkGate: {}, nowMs: { 100 })
      let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect((value["result"] as? [String: Bool])?["delivered"] == true)
    }
  }

  @Test func rejectsNonJSONAndOversizedReplies() throws {
    let invalid: [String: Any] = ["id": "test", "result": Date()]
    let invalidData = try ProbeReply.encode(invalid, id: "test", expiresAtMs: nil, checkGate: {})
    #expect(try errorCode(invalidData) == ProbeFailure.invalidEnvelope.code)
    let oversized: [String: Any] = ["id": "test", "result": String(repeating: "x", count: 65_536)]
    let data = try ProbeReply.encode(oversized, id: "test", expiresAtMs: nil, checkGate: {})
    #expect(data.count <= 65_536)
    #expect(try errorCode(data) == ProbeFailure.oversized.code)
    let expired = try ProbeReply.encode(oversized, id: "test", expiresAtMs: 100, checkGate: {}, nowMs: { 100 })
    #expect(try errorCode(expired) == ProbeFailure.timeout.code)
  }

  private func success() -> [String: Any] {
    ["id": "test", "protocol": 1, "result": ["delivered": true]]
  }

  private func errorCode(_ data: Data) throws -> String? {
    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return (value?["error"] as? [String: String])?["code"]
  }
}
#endif
