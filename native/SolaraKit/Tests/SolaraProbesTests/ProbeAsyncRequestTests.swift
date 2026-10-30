#if SOLARA_PROBES
import Foundation
import Testing
@testable import SolaraProbes

@MainActor
struct ProbeAsyncRequestTests {
  @Test(.timeLimit(.minutes(1))) func revokingGateDuringPasswordLookupStopsAdaptersAndReply() async throws {
    let requests = ProbeAsyncRequest()
    let lookup = DelayedPasswordLookup()
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: output) }
    let effects = RequestEffects()
    let task = try requests.start(id: "snapshot", expiresAtMs: deadline(), checkGate: {
      guard effects.allowed else { throw ProbeFailure.testHooksDenied }
    }, lookup: {
      await lookup.exists()
    }, after: { exists in
      effects.adapterCalls += 1
      return exists
    }, reply: { result in
      effects.replyCalls += 1
      try? Data(String(describing: result).utf8).write(to: output)
    })
    await lookup.waitUntilStarted()
    effects.allowed = false
    lookup.resume(returning: true)
    await task.value
    #expect(effects.adapterCalls == 0)
    #expect(effects.replyCalls == 0)
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func checksGateWhenScheduledTaskEnters() async throws {
    let requests = ProbeAsyncRequest()
    let effects = RequestEffects()
    let task = try requests.start(id: "snapshot", expiresAtMs: deadline(), checkGate: {
      guard effects.allowed else { throw ProbeFailure.testHooksDenied }
    }, lookup: {
      effects.lookupCalls += 1
      return true
    }, after: { exists in
      effects.adapterCalls += 1
      return exists
    }, reply: { _ in effects.replyCalls += 1 })
    effects.allowed = false
    await task.value
    #expect(effects.lookupCalls == 0)
    #expect(effects.adapterCalls == 0)
    #expect(effects.replyCalls == 0)
  }

  @Test func returnsLookupThroughAdaptersAndRepliesOnce() async throws {
    let requests = ProbeAsyncRequest()
    var adapterValues: [Bool] = []
    var replies: [Bool] = []
    let task = try requests.start(id: "snapshot", expiresAtMs: deadline(), checkGate: {}, lookup: {
      false
    }, after: { exists in
      adapterValues.append(exists)
      return !exists
    }, reply: { result in
      if case .success(let value) = result { replies.append(value) }
      else { Issue.record("Allowed request failed") }
    })
    await task.value
    #expect(adapterValues == [false])
    #expect(replies == [true])
  }

  @Test func checksGateAgainBeforeReply() async throws {
    let requests = ProbeAsyncRequest()
    var allowed = true
    var replyCalls = 0
    let task = try requests.start(id: "snapshot", expiresAtMs: deadline(), checkGate: {
      guard allowed else { throw ProbeFailure.testHooksDenied }
    }, lookup: { true }, after: { exists in
      allowed = false
      return exists
    }, reply: { _ in replyCalls += 1 })
    await task.value
    #expect(replyCalls == 0)
  }

  @Test func lookupFailureRepliesOnlyWhileGateAllows() async throws {
    for revoke in [false, true] {
      let requests = ProbeAsyncRequest()
      var allowed = true
      var adapterCalls = 0
      var errors: [ProbeFailure] = []
      let task = try requests.start(id: "snapshot", expiresAtMs: deadline(), checkGate: {
        guard allowed else { throw ProbeFailure.testHooksDenied }
      }, lookup: { () async throws -> Bool in
        allowed = !revoke
        throw ProbeFailure.notReady
      }, after: { exists in
        adapterCalls += 1
        return exists
      }, reply: { result in
        if case .failure(let error) = result, let error = error as? ProbeFailure { errors.append(error) }
        else { Issue.record("Failed lookup returned success") }
      })
      await task.value
      #expect(adapterCalls == 0)
      #expect(errors == (revoke ? [] : [.notReady]))
    }
  }

  @Test(.timeLimit(.minutes(1))) func timeoutCancelsLookupAndKeepsPendingRequestsCappedUntilTheyReturn() async throws {
    let requests = ProbeAsyncRequest()
    let lookups = (0..<4).map { _ in DelayedPasswordLookup() }
    var tasks: [Task<Void, Never>] = []
    var adapterCalls = 0
    var errors: [ProbeFailure] = []
    var timeoutWaiter: CheckedContinuation<Void, Never>?
    for (index, lookup) in lookups.enumerated() {
      tasks.append(try requests.start(id: String(index), expiresAtMs: deadline(seconds: 2), checkGate: {}, lookup: {
        await lookup.exists()
      }, after: { exists in
        adapterCalls += 1
        return exists
      }, reply: { result in
        if case .failure(let error) = result, let error = error as? ProbeFailure { errors.append(error) }
        else { Issue.record("Expired lookup returned success") }
        if errors.count == 4 { timeoutWaiter?.resume(); timeoutWaiter = nil }
      }))
    }
    for lookup in lookups { await lookup.waitUntilStarted() }
    if errors.count < 4 { await withCheckedContinuation { timeoutWaiter = $0 } }
    #expect(errors == [.timeout, .timeout, .timeout, .timeout])
    #expect(tasks.allSatisfy { $0.isCancelled })
    #expect(throws: ProbeFailure.notReady) {
      try requests.start(id: "overflow", expiresAtMs: deadline(), checkGate: {}, lookup: { true }, after: { $0 }, reply: { _ in
        Issue.record("Over-cap request replied")
      })
    }
    for lookup in lookups { lookup.resume(returning: true) }
    for task in tasks { await task.value }
    #expect(adapterCalls == 0)
    #expect(lookups.allSatisfy { $0.cancelledOnReturn })
    #expect(errors.count == 4)
    var completed = false
    let next = try requests.start(id: "next", expiresAtMs: deadline(), checkGate: {}, lookup: { true }, after: { $0 }, reply: { _ in completed = true })
    await next.value
    #expect(completed)
  }

  private func deadline(seconds: Double = 30) -> Int64 {
    Int64((Date().timeIntervalSince1970 + seconds) * 1000)
  }
}

@MainActor
private final class RequestEffects {
  var allowed = true
  var lookupCalls = 0
  var adapterCalls = 0
  var replyCalls = 0
}

@MainActor
private final class DelayedPasswordLookup {
  private var callback: CheckedContinuation<Bool, Never>?
  private var started: CheckedContinuation<Void, Never>?
  private(set) var cancelledOnReturn = false

  func exists() async -> Bool {
    let value = await withCheckedContinuation { callback in
      self.callback = callback
      started?.resume()
      started = nil
    }
    cancelledOnReturn = Task.isCancelled
    return value
  }

  func waitUntilStarted() async {
    if callback != nil { return }
    await withCheckedContinuation { started = $0 }
  }

  func resume(returning value: Bool) {
    callback?.resume(returning: value)
    callback = nil
  }
}
#endif
