#if SOLARA_PROBES
import Foundation

public struct ProbePollBudget {
  private var synchronousSnapshots = 0

  public init() {}

  public mutating func takeSynchronousSnapshot(hasSavedLogin: Bool) -> Bool {
    guard !hasSavedLogin, synchronousSnapshots < 4 else { return false }
    synchronousSnapshots += 1
    return true
  }
}

public enum ProbeActionAdmission {
  public static func check(mode: RunLoop.Mode?, hasModalWindow: Bool, hasAttachedSheet: Bool, hasSheetParent: Bool) throws {
    guard mode == .default, !hasModalWindow, !hasAttachedSheet, !hasSheetParent else { throw ProbeFailure.notReady }
  }
}

public enum ProbeReply {
  public static func encode(_ response: [String: Any], id: String, expiresAtMs: Int64?,
    checkGate: () throws -> Void,
    nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
    encodeJSON: ([String: Any]) throws -> Data = { try JSONSerialization.data(withJSONObject: $0) }) throws -> Data {
    let success = response["result"] != nil && response["error"] == nil
    let valid = JSONSerialization.isValidJSONObject(response) ? response : failure(.invalidEnvelope, id: id)
    var encoded = try encodeJSON(valid)
    if encoded.count > 65_536 { encoded = try encodeJSON(failure(.oversized, id: id)) }
    try checkGate()
    if success, let expiresAtMs, nowMs() >= expiresAtMs {
      encoded = try encodeJSON(failure(.timeout, id: id))
      try checkGate()
    }
    guard encoded.count <= 65_536 else { throw ProbeFailure.oversized }
    return encoded
  }

  public static func publish(_ response: [String: Any], id: String, expiresAtMs: Int64?,
    checkGate: @escaping () throws -> Void,
    nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
    write: (Data, () throws -> Void) throws -> Void) throws {
    let encoded = try encode(response, id: id, expiresAtMs: expiresAtMs, checkGate: checkGate, nowMs: nowMs)
    do {
      try write(encoded) {
        try checkGate()
        if response["result"] != nil, response["error"] == nil,
          let expiresAtMs, nowMs() >= expiresAtMs { throw ProbeFailure.timeout }
      }
    } catch ProbeFailure.timeout {
      let timeout = try encode(failure(.timeout, id: id), id: id, expiresAtMs: nil, checkGate: checkGate, nowMs: nowMs)
      try write(timeout) { try checkGate() }
    }
  }

  private static func failure(_ error: ProbeFailure, id: String) -> [String: Any] {
    ["id": id, "protocol": 1, "error": ["code": error.code]]
  }
}
#endif
