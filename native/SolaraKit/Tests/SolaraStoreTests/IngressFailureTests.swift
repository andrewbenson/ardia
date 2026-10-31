import Foundation
import SolaraModel
import SolaraStore
import Synchronization
import Testing

@Suite struct IngressFailureTests {
  @Test func queuedFailureAndPersistenceRefusalHooksRunOutsideIngress() {
    let subject = Mutex<Store?>(nil)
    let reads = SequencerValues<Bool>()
    let callbacks = SequencerValues<String>()
    let read: @Sendable () -> Void = {
      guard let store = subject.withLock({ $0 }) else { return }
      let done = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        _ = store.rev
        done.signal()
      }
      reads.append(done.wait(timeout: .now() + 3) == .success)
    }
    var config = StoreConfig()
    config.persistenceRefusal = "refused"
    let store = Store(
      config: config,
      sequencedFailure: { _, _ in callbacks.append("failure"); read() },
      onPersistenceRefusal: { _ in callbacks.append("refusal"); read() })
    subject.withLock { $0 = store }
    defer { subject.withLock { $0 = nil } }
    let token = store.observeSequencedFailures { _, _ in callbacks.append("observer"); read() }
    defer { store.unsubscribe(token) }
    store.enqueueSequenced(settingsCommand(["appearance": "dark"]))
    store.sequence {}
    #expect(callbacks.all == ["refusal", "failure", "observer"])
    #expect(reads.all == [true, true, true])
    #expect(store.rev == 0)
  }

  @Test func invariantReportsRunOutsideIngress() throws {
    let seed = Store()
    let window = try seed.dispatch(Command("createWindow", [["url": "https://invariant.example/"]])).result!.string!
    var state = seed.state
    let tab = state.windows[window]!.tabIds[0]
    var broken = state.windows[window]!
    broken.tabIds = [tab, tab]
    state.windows[window] = broken
    let subject = Mutex<Store?>(nil)
    let readable = Mutex<[Bool]>([])
    let store = Store(state: state, memory: seed.memory, checksInvariants: true, invariantHandler: { _, _ in
      guard let store = subject.withLock({ $0 }) else { return }
      let done = DispatchSemaphore(value: 0)
      Thread.detachNewThread { _ = store.rev; done.signal() }
      let ok = done.wait(timeout: .now() + 3) == .success
      readable.withLock { $0.append(ok) }
    })
    subject.withLock { $0 = store }
    _ = try store.dispatch(Command("nextId", ["probe"]))
    #expect(!readable.withLock { $0 }.isEmpty)
    #expect(readable.withLock { $0 }.allSatisfy { $0 })
  }
}
