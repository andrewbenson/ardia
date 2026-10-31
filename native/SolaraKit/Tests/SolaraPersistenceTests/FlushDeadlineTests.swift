import Foundation
import Synchronization
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct FlushDeadlineTests {
  @Test func quitFlushReturnsWithinItsTimeoutWhileAnotherThreadTransacts() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      _ = try? store.transact { _ in
        started.signal()
        Thread.sleep(forTimeInterval: 2)
      }
      finished.signal()
    }
    try #require(started.wait(timeout: .now() + 5) == .success)
    let start = Date()
    let result = writer.flush(timeout: 0.5)
    let elapsed = Date().timeIntervalSince(start)
    _ = finished.wait(timeout: .now() + 5)
    #expect(result == .timedOut)
    #expect(elapsed < 1.0)
  }

  @Test func anUnchangedInitialFlushDoesNotCreateAShadowFile() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let before = contents(folder.session)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(contents(folder.session) == before)
  }

  @Test func aFlushInsideASequenceBodyNeitherWaitsOnIngressNorDrainsTheQueue() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let result = store.sequence { () -> (FlushResult, TimeInterval) in
      store.enqueueSequenced(Command("updateSettings", [["sidebarWidth": 230]]))
      let start = Date()
      let saved = writer.flush(timeout: 2)
      return (saved, Date().timeIntervalSince(start))
    }
    #expect(result.0 == .saved)
    #expect(result.1 < 1)
    #expect(store.state.settings.values["sidebarWidth"] == 230)
  }
}
