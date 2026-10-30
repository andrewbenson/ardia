#if SOLARA_PROBES
import Foundation

@MainActor
public final class ProbeAsyncRequest {
  private var tasks: [String: Task<Void, Never>] = [:]
  private var timeouts: [String: Task<Void, Never>] = [:]

  public init() {}

  public func start<Lookup, Response>(id: String, expiresAtMs: Int64,
    checkGate: @escaping @MainActor () throws -> Void,
    lookup: @escaping @MainActor () async throws -> Lookup,
    after: @escaping @MainActor (Lookup) throws -> Response,
    reply: @escaping @MainActor (Result<Response, Error>) -> Void) throws -> Task<Void, Never> {
    guard tasks.count < 4, tasks[id] == nil else { throw ProbeFailure.notReady }
    let task = Task { @MainActor in
      defer {
        tasks.removeValue(forKey: id)
        timeouts.removeValue(forKey: id)?.cancel()
      }
      do {
        try check(id: id, expiresAtMs: expiresAtMs, checkGate: checkGate)
        let value = try await lookup()
        try check(id: id, expiresAtMs: expiresAtMs, checkGate: checkGate)
        let response = try after(value)
        try check(id: id, expiresAtMs: expiresAtMs, checkGate: checkGate)
        finish(id: id, expiresAtMs: expiresAtMs, result: .success(response), checkGate: checkGate, reply: reply)
      } catch {
        finish(id: id, expiresAtMs: expiresAtMs, result: .failure(error), checkGate: checkGate, reply: reply)
      }
    }
    tasks[id] = task
    let seconds = max(0, Double(expiresAtMs) / 1000 - Date().timeIntervalSince1970)
    timeouts[id] = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) }
      catch { return }
      guard let self else { return }
      tasks[id]?.cancel()
      finish(id: id, expiresAtMs: expiresAtMs, result: .failure(ProbeFailure.timeout), checkGate: checkGate, reply: reply)
    }
    return task
  }

  public func check(id: String, expiresAtMs: Int64, checkGate: @MainActor () throws -> Void) throws {
    try checkGate()
    try checkPending(id: id, expiresAtMs: expiresAtMs)
  }

  private func checkPending(id: String, expiresAtMs: Int64) throws {
    guard !Task.isCancelled, timeouts[id] != nil,
      Int64(Date().timeIntervalSince1970 * 1000) < expiresAtMs else { throw ProbeFailure.timeout }
  }

  private func finish<Response>(id: String, expiresAtMs: Int64, result: Result<Response, Error>,
    checkGate: @MainActor () throws -> Void, reply: @MainActor (Result<Response, Error>) -> Void) {
    guard let timeout = timeouts.removeValue(forKey: id) else { return }
    timeout.cancel()
    do { try checkGate() }
    catch { return }
    if Int64(Date().timeIntervalSince1970 * 1000) >= expiresAtMs {
      reply(.failure(ProbeFailure.timeout))
    } else {
      reply(result)
    }
  }
}
#endif
