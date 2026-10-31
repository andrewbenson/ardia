import Foundation
import Synchronization
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct IngressListenerTests {
  @Test func flushFromAListenerOnTheCommittingThreadSaves() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let results = Mutex<[FlushResult]>([])
    let id = store.subscribe { commit in
      guard commit.commands.contains(where: { $0.name == "createWindow" }) else { return }
      let r = writer.flush(timeout: 1)
      results.withLock { $0.append(r) }
    }
    defer { store.unsubscribe(id) }
    _ = try store.dispatch(Command("createWindow", [["url": "https://repro.example/"]]))
    #expect(results.withLock { $0 } == [.saved])
  }

  @Test func offThreadReadDuringListenerDeliveryIsNotBlocked() throws {
    let store = Store()
    let waited = Mutex<Double>(0)
    let id = store.subscribe { commit in
      guard commit.commands.contains(where: { $0.name == "createWindow" }) else { return }
      let done = DispatchSemaphore(value: 0)
      Thread.detachNewThread { _ = store.rev; done.signal() }
      let ok = done.wait(timeout: .now() + 3) == .success
      waited.withLock { $0 = ok ? 0 : 1 }
    }
    defer { store.unsubscribe(id) }
    _ = try store.dispatch(Command("createWindow", [["url": "https://repro.example/"]]))
    #expect(waited.withLock { $0 } == 0)
  }

  @Test func backgroundPersistenceUsesCommittedStateWithoutEnteringIngress() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try store.dispatch(Command("updateSettings", [["sidebarWidth": 210]]))
    #expect(writer.flush(timeout: 5) == .saved)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      store.sequence {
        store.enqueueSequenced(Command("updateSettings", [["sidebarWidth": 220]]))
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      finished.signal()
    }
    defer { release.signal() }
    #expect(entered.wait(timeout: .now() + 5) == .success)
    let saved = DispatchSemaphore(value: 0)
    let results = Mutex<[FlushResult]>([])
    writer.markShadowDirty()
    writer.queue.async {
      let result = writer.writeEverythingDurably()
      results.withLock { $0.append(result) }
      saved.signal()
    }
    let completedWhileIngressWasHeld = saved.wait(timeout: .now() + 1) == .success
    release.signal()
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(completedWhileIngressWasHeld)
    writer.queue.sync {}
    #expect(results.withLock { $0 } == [.saved])
    #expect(try launch.database.load().settings?["sidebarWidth"] == 210)
    let shadow = try JSONValue.parse(Data(contentsOf: folder.session))
    #expect(shadow["settings"]?["sidebarWidth"] == 210)
    #expect(store.rev > 0)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(try launch.database.load().settings?["sidebarWidth"] == 220)
  }

  @Test func readsNeverDeliverAnotherThreadsListeners() throws {
    let store = Store()
    let readerDelivered = Atomic<Int>(0)
    let reading = Atomic<Bool>(true)
    let readerThread = Mutex<Thread?>(nil)
    let id = store.subscribe { _ in
      if readerThread.withLock({ $0 }) == Thread.current { readerDelivered.add(1, ordering: .relaxed) }
    }
    defer { store.unsubscribe(id) }
    let done = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let reads = Atomic<Int>(0)
    Thread.detachNewThread {
      readerThread.withLock { $0 = Thread.current }
      started.signal()
      while reading.load(ordering: .relaxed) {
        _ = store.state
        _ = store.rev
        reads.add(1, ordering: .relaxed)
      }
      done.signal()
    }
    #expect(started.wait(timeout: .now() + 5) == .success)
    for index in 0..<300 { _ = try store.dispatch(Command("updateSettings", [["sidebarWidth": .number(Double(200 + index % 50))]])) }
    reading.store(false, ordering: .relaxed)
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(reads.load(ordering: .relaxed) > 0)
    #expect(readerDelivered.load(ordering: .relaxed) == 0)
  }
}
