import Foundation
import SolaraModel
import SolaraStore
import Synchronization
import Testing

final class SequencerValues<Value: Sendable>: Sendable {
  private let values: Mutex<[Value]>
  init(_ initial: [Value] = []) { values = Mutex(initial) }
  func append(_ value: Value) { values.withLock { $0.append(value) } }
  var all: [Value] { values.withLock { $0 } }
}

@Suite struct SequencerTests {
  @Test func queuedCommandsKeepFIFOAndTheirOwnCommits() throws {
    let store = makeStore()
    let commits = SequencerValues<Commit>()
    store.subscribe { commits.append($0) }
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 220]))
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 230]))
    #expect(commits.all.isEmpty)
    store.sequence {}
    #expect(commits.all.map(\.rev) == [1, 2, 3])
    #expect(commits.all.map { $0.state.settings.values["sidebarWidth"] } == [210, 220, 230])
    #expect(commits.all.allSatisfy { $0.commands.count == 1 && $0.origin == .engine && $0.durable })
  }

  @Test func reentrantDispatchDrainsOlderQueuedCommandsBeforeItsOwnCommand() throws {
    let store = makeStore()
    let commits = SequencerValues<Commit>()
    let errors = SequencerValues<String>()
    store.subscribe { commit in
      commits.append(commit)
      if commit.rev == 1 {
        do { try store.dispatch(settingsCommand(["sidebarWidth": 240])) }
        catch { errors.append(String(describing: error)) }
      }
    }
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 220]))
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 230]))
    store.sequence {}
    #expect(errors.all.isEmpty)
    #expect(commits.all.map { $0.state.settings.values["sidebarWidth"] } == [210, 220, 230, 240])
    #expect(commits.all.map(\.rev) == [1, 2, 3, 4])
  }

  @Test func nestedSequenceIsRecursiveAndDrainsAtEachEntry() {
    let store = makeStore()
    let values = SequencerValues<Int>()
    store.subscribe { values.append($0.rev) }
    let value = store.sequence {
      store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
      #expect(values.all.isEmpty)
      return store.sequence {
        #expect(store.rev == 1)
        #expect(values.all.isEmpty)
        store.enqueueSequenced(settingsCommand(["sidebarWidth": 220]))
        return store.sequence { store.rev }
      }
    }
    #expect(value == 2)
    #expect(values.all == [1, 2])
  }

  @Test func enqueuedInsideBodyWaitsForTheNextBarrierEvenWhenBodyThrows() {
    let store = makeStore()
    let values = SequencerValues<Int>()
    store.subscribe { values.append($0.rev) }
    store.sequence { store.enqueueSequenced(settingsCommand(["sidebarWidth": 210])) }
    #expect(values.all.isEmpty)
    #expect(store.rev == 1)
    #expect(throws: CommandError.self) {
      try store.sequence {
        store.enqueueSequenced(settingsCommand(["sidebarWidth": 220]))
        throw CommandError("body")
      }
    }
    #expect(values.all == [1])
    #expect(store.snapshot.rev == 2)
  }

  @Test(arguments: ["state", "snapshot", "memory", "patches", "submit", "transact", "queuedFromSyncCount", "rev"])
  func readsAndSubmissionsDrainQueuedCommands(barrier: String) throws {
    let store = makeStore()
    let values = SequencerValues<Int>()
    store.subscribe { values.append($0.rev) }
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
    switch barrier {
    case "state": _ = store.state
    case "snapshot": _ = store.snapshot
    case "memory": _ = store.memory
    case "patches": _ = store.patches(since: 0)
    case "submit": try store.dispatch(settingsCommand(["appearance": "dark"]))
    case "transact": try store.transact { _ in }
    case "queuedFromSyncCount": _ = store.queuedFromSyncCount
    default: _ = store.rev
    }
    #expect(values.all.first == 1)
  }

  @Test func refusedQueuedCommandReachesHandlerAndObserversAndDrainingContinues() {
    let handled = SequencerValues<String>()
    let observed = SequencerValues<String>()
    let store = Store(sequencedFailure: { command, error in handled.append("\(command.name):\(error)") })
    let token = store.observeSequencedFailures { command, error in observed.append("\(command.name):\(error)") }
    store.enqueueSequenced(Command("closeTab", []))
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
    store.sequence {}
    #expect(handled.all.count == 1)
    #expect(observed.all == handled.all)
    #expect(store.rev == 1)
    store.unsubscribe(token)
    store.enqueueSequenced(Command("closeTab", []))
    store.sequence {}
    #expect(handled.all.count == 2)
    #expect(observed.all.count == 1)
  }

  @Test func aRefusedSubmissionStillDrainsReportsAndHeldSyncReplaySurvives() throws {
    var config = StoreConfig()
    config.syncOrigins = true
    let store = Store(config: config)
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { $0.updateSettings(["appearance": "dark"], fromSync: true) }
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
    #expect(throws: StoreBusy.self) { try store.dispatch(Command("nextId", ["tab"]), origin: .sync) }
    #expect(store.state.settings.values["sidebarWidth"] == 210)
    #expect(store.queuedFromSyncCount == 1)
    try store.dispatch(Command("endTransaction"))
    #expect(store.queuedFromSyncCount == 0)
    #expect(store.state.settings.values["appearance"] == "dark")
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 220]))
    #expect(throws: CommandError.self) { try store.dispatch(Command("syncPinsApply", [])) }
    #expect(store.state.settings.values["sidebarWidth"] == 220)
  }

  @Test func queuedPinSettlementStillWaitsBehindAUserTransaction() throws {
    let store = makeStore()
    try store.dispatch(Command("beginTransaction"))
    store.enqueueSequenced(Command("settlePinChoices", ["default", [:]]))
    store.sequence {}
    #expect(store.queuedFromSyncCount == 1)
    try store.dispatch(Command("endTransaction"))
    #expect(store.queuedFromSyncCount == 0)
  }

  @Test func pinnedCommandsKeepTheirStandaloneValidationWhenQueued() {
    let errors = SequencerValues<String>()
    let store = Store(sequencedFailure: { command, error in errors.append("\(command.name):\(error)") })
    store.enqueueSequenced(Command("syncPinsApply", []))
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
    store.sequence {}
    #expect(errors.all.count == 1)
    #expect(errors.all.first?.hasPrefix("syncPinsApply:") == true)
    #expect(store.rev == 1)
  }

  @Test func listenerDispatchKeepsQueuedCommandsFIFOAndDeliverySerialAcrossThreads() throws {
    let store = makeStore()
    let commits = SequencerValues<Commit>()
    let errors = SequencerValues<String>()
    let delivery = Mutex((active: 0, maximum: 0))
    store.subscribe { commit in
      delivery.withLock {
        $0.active += 1
        $0.maximum = max($0.maximum, $0.active)
      }
      defer { delivery.withLock { $0.active -= 1 } }
      commits.append(commit)
      if commit.rev == 1 {
        store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
        store.enqueueSequenced(settingsCommand(["sidebarWidth": 220]))
        do { try store.dispatch(settingsCommand(["sidebarWidth": 230])) }
        catch { errors.append(String(describing: error)) }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
          do { try store.dispatch(settingsCommand(["sidebarWidth": 240])) }
          catch { errors.append(String(describing: error)) }
          done.signal()
        }
        #expect(done.wait(timeout: .now() + 3) == .success)
        #expect(commits.all.map(\.rev) == [1])
      }
    }
    try store.dispatch(settingsCommand(["sidebarWidth": 200]))
    #expect(errors.all.isEmpty)
    #expect(commits.all.map(\.rev) == [1, 2, 3, 4, 5])
    #expect(commits.all.map { $0.state.settings.values["sidebarWidth"] } == [200, 210, 220, 230, 240])
    #expect(delivery.withLock { $0.maximum } == 1)
  }

  @Test func nestedAndThrowingSequencesReleaseIngressBeforeDelivery() throws {
    let store = makeStore()
    let reads = SequencerValues<Int>()
    store.subscribe { _ in
      let done = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        reads.append(store.rev)
        done.signal()
      }
      #expect(done.wait(timeout: .now() + 3) == .success)
    }
    #expect(throws: CommandError.self) {
      try store.sequence {
        _ = try store.sequence { try store.dispatch(settingsCommand(["sidebarWidth": 210])) }
        #expect(reads.all.isEmpty)
        throw CommandError("body")
      }
    }
    #expect(reads.all == [1])
  }

  @Test func listenersCanHoldANewUserTransactionBeforeQueuedSyncReplays() throws {
    let store = syncingStore()
    let seen = SequencerValues<JSONValue?>()
    let errors = SequencerValues<String>()
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { $0.updateSettings(["appearance": "dark"], fromSync: true) }
    store.subscribe { commit in
      if commit.commands.contains(where: { $0.name == "endTransaction" }) && commit.rev == 1 {
        seen.append(store.state.settings.values["appearance"])
        do { try store.dispatch(Command("beginTransaction")) }
        catch { errors.append(String(describing: error)) }
      }
    }
    try store.dispatch([settingsCommand(["sidebarWidth": 210]), Command("endTransaction")])
    #expect(errors.all.isEmpty)
    #expect(seen.all.count == 1)
    #expect(seen.all.first != .some(.string("dark")))
    #expect(store.queuedFromSyncCount == 1)
    try store.dispatch(Command("endTransaction"))
    #expect(store.queuedFromSyncCount == 0)
    #expect(store.state.settings.values["appearance"] == "dark")
  }

  @Test func queuedTransactionEndReplaysWaitingSyncBeforeTheNextSubmission() throws {
    let store = syncingStore()
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { $0.updateSettings(["appearance": "dark"], fromSync: true) }
    store.enqueueSequenced(Command("endTransaction"))
    try store.dispatch(settingsCommand(["sidebarWidth": 210]), origin: .sync)
    #expect(store.queuedFromSyncCount == 0)
    #expect(store.state.settings.values["appearance"] == "dark")
    #expect(store.state.settings.values["sidebarWidth"] == 210)
  }

  @Test func queuedTransactionEndReplaysWaitingSyncBeforeTheNextQueuedSyncCommand() throws {
    let errors = SequencerValues<String>()
    var config = StoreConfig()
    config.syncOrigins = true
    let store = Store(config: config, sequencedFailure: { _, error in errors.append(String(describing: error)) })
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { $0.updateSettings(["appearance": "dark"], fromSync: true) }
    store.enqueueSequenced(Command("endTransaction"))
    store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]), origin: .sync)
    store.sequence {}
    #expect(errors.all.isEmpty)
    #expect(store.queuedFromSyncCount == 0)
    #expect(store.state.settings.values["appearance"] == "dark")
    #expect(store.state.settings.values["sidebarWidth"] == 210)
  }

  @Test func nestedTransactionEndReplaysWaitingSyncBeforeTheNextSubmission() throws {
    let store = syncingStore()
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { $0.updateSettings(["appearance": "dark"], fromSync: true) }
    try store.sequence {
      try store.dispatch(Command("endTransaction"))
      try store.dispatch(settingsCommand(["sidebarWidth": 210]), origin: .sync)
    }
    #expect(store.queuedFromSyncCount == 0)
    #expect(store.state.settings.values["appearance"] == "dark")
    #expect(store.state.settings.values["sidebarWidth"] == 210)
  }

  @Test func queuedTransactionCompletionCanHelpSyncWhileItsDeliveryOwnerWaits() throws {
    let store = syncingStore()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let errors = SequencerValues<String>()
    let commits = SequencerValues<Commit>()
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { $0.updateSettings(["appearance": "dark"], fromSync: true) }
    try store.transactWhenFree { $0.updateSettings(["searchEngine": "bing"], fromSync: true) }
    store.subscribe { commit in
      commits.append(commit)
      if commit.rev == 1 {
        entered.signal()
        #expect(release.wait(timeout: .now() + 5) == .success)
      }
    }
    Thread.detachNewThread {
      do { try store.dispatch(Command("endTransaction")) }
      catch { errors.append(String(describing: error)) }
      finished.signal()
    }
    defer { release.signal() }
    #expect(entered.wait(timeout: .now() + 5) == .success)
    store.enqueueSequenced(Command("endTransaction"))
    do { try store.dispatch(settingsCommand(["sidebarWidth": 210]), origin: .sync) }
    catch { errors.append(String(describing: error)) }
    #expect(errors.all.isEmpty)
    #expect(store.state.settings.values["searchEngine"] == "bing")
    #expect(store.state.settings.values["sidebarWidth"] == 210)
    #expect(commits.all.map(\.rev) == [1])
    release.signal()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(commits.all.map(\.rev) == [1, 2, 3])
  }

  @Test func waitingSyncReplayDoesNotDrainCommandsEnqueuedInsideTheSequenceBody() throws {
    let subject = Mutex<Store?>(nil)
    let enqueueDuringSubmission = Mutex(false)
    var config = StoreConfig()
    config.syncOrigins = true
    let store = Store(config: config, clock: {
      let enqueue = enqueueDuringSubmission.withLock { armed in
        let enqueue = armed
        armed = false
        return enqueue
      }
      if enqueue, let store = subject.withLock({ $0 }) {
        store.enqueueSequenced(settingsCommand(["sidebarWidth": 210]))
      }
      return 1_000
    })
    subject.withLock { $0 = store }
    defer { subject.withLock { $0 = nil } }
    let commits = SequencerValues<Commit>()
    store.subscribe { commits.append($0) }
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { $0.updateSettings(["appearance": "dark"], fromSync: true) }
    try store.sequence {
      enqueueDuringSubmission.withLock { $0 = true }
      try store.dispatch([settingsCommand(["sidebarWidth": 200]), Command("endTransaction")])
    }
    #expect(commits.all.map { $0.state.settings.values["sidebarWidth"] } == [200, 200])
    #expect(commits.all.map(\.origin) == [.native, .sync])
    #expect(commits.all.last?.state.settings.values["appearance"] == "dark")
    #expect(commits.all.allSatisfy { !$0.commands.contains(settingsCommand(["sidebarWidth": 210])) })
    store.sequence {}
    #expect(commits.all.map { $0.state.settings.values["sidebarWidth"] } == [200, 200, 210])
    #expect(store.queuedFromSyncCount == 0)
    #expect(store.state.settings.values["appearance"] == "dark")
  }
}
