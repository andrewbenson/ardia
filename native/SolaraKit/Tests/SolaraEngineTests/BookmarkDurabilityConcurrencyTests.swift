import Dispatch
import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkDurabilityConcurrencyTests {
  private func directory() throws -> URL {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("BookmarkConcurrencyScratch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    return path
  }

  private func document() -> JSONValue { BookmarkCoordinatorTests().document(["https://a.test", "https://b.test"]) }

  private func owner(_ directory: URL, operations: BookmarkPendingFileOperations = .live, provider: DurabilityStampProvider = .init()) -> BookmarkCoordinator {
    BookmarkCoordinator(profiles: ["p": "", "alias": ""], defaultProfile: "p", owningProfiles: ["": "p"], stampProviders: provider.providers, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory, fileOperations: operations))
  }

  private func rename(_ id: String, _ title: String) -> BookmarkMutation {
    .init(method: "updateBookmark", args: [.string(id), ["title": .string(title)]])
  }

  @Test func readersCompleteWhileDurableWriteIsHeldOpen() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = DurabilityWriteGate()
    let coordinator = owner(directory, operations: gate.operations)
    coordinator.seed(engine: "", document: document(), ready: false)
    let before = coordinator.desiredView(engine: "")
    let probe = DurabilityWorkProbe()
    let writerDone = DispatchSemaphore(value: 0)
    let readerDone = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      defer { writerDone.signal() }
      do { probe.accept("writer", try coordinator.submit(profile: "p", mutations: [.init(method: "removeBookmark", args: ["b0"])])) }
      catch { probe.fail(error) }
    }
    let entered = gate.entered.wait(timeout: .now() + 5)
    #expect(entered == .success)
    Thread.detachNewThread {
      probe.read(view: coordinator.desiredView(engine: ""), member: coordinator.membership(profile: "alias", url: "https://a.test"), stamp: coordinator.pendingEditStamp(profileId: "p", nodeId: "b0"))
      readerDone.signal()
    }
    let readerResult = readerDone.wait(timeout: .now() + 1)
    gate.release.signal()
    #expect(readerResult == .success)
    #expect(writerDone.wait(timeout: .now() + 5) == .success)
    if readerResult != .success { #expect(readerDone.wait(timeout: .now() + 5) == .success) }
    #expect(probe.errors.isEmpty)
    #expect(probe.readView == before)
    #expect(probe.readMember == true)
    #expect(probe.readStamp == nil)
    #expect(!coordinator.membership(profile: "p", url: "https://a.test"))
  }

  @Test func concurrentSubmitsInstallInOrderWithoutLosingEitherEdit() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = DurabilityWriteGate()
    let coordinator = owner(directory, operations: gate.operations)
    coordinator.seed(engine: "", document: document(), ready: false)
    let revision = coordinator.desiredView(engine: "").revision
    let probe = DurabilityWorkProbe()
    let firstDone = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let secondDone = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      defer { firstDone.signal() }
      do { probe.accept("first", try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b0", ["title": "First"]])])) }
      catch { probe.fail(error) }
    }
    #expect(gate.entered.wait(timeout: .now() + 5) == .success)
    Thread.detachNewThread {
      secondStarted.signal()
      defer { secondDone.signal() }
      do { probe.accept("second", try coordinator.submit(profile: "p", mutations: [.init(method: "updateBookmark", args: ["b1", ["title": "Second"]])])) }
      catch { probe.fail(error) }
    }
    #expect(secondStarted.wait(timeout: .now() + 5) == .success)
    let prematureSecond = secondDone.wait(timeout: .now() + 0.1)
    gate.release.signal()
    #expect(prematureSecond == .timedOut)
    #expect(firstDone.wait(timeout: .now() + 5) == .success)
    if prematureSecond != .success { #expect(secondDone.wait(timeout: .now() + 5) == .success) }
    #expect(probe.errors.isEmpty)
    let first = try #require(probe.receipt("first"))
    let second = try #require(probe.receipt("second"))
    #expect(first.view.revision == revision + 1)
    #expect(second.view.revision == revision + 2)
    #expect(first.view.document["nodes"]?["b1"]?["title"] == "Page")
    #expect(second.view.document["nodes"]?["b0"]?["title"] == "First")
    #expect(second.view.document["nodes"]?["b1"]?["title"] == "Second")
    let restored = owner(directory).desiredView(engine: "")
    #expect(restored.document == second.view.document)
    #expect(restored.revision == second.view.revision)
  }

  @Test func crashRelaunchObservesEveryJournaledStampBeforeFirstMint() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstProvider = DurabilityStampProvider()
    var first: BookmarkCoordinator? = owner(directory, provider: firstProvider)
    first!.seed(engine: "", document: document(), ready: false)
    try first!.submit(profile: "p", mutations: [rename("b0", "First stamped title")], requestID: "before-crash-1")
    try first!.submit(profile: "p", mutations: [rename("b0", "Renamed"), .init(method: "removeBookmark", args: ["b1"])], requestID: "before-crash-2")
    let accepted = first!.desiredView(engine: "")
    #expect(accepted.pendingStamps["b0"] != nil)
    #expect(accepted.pendingStamps["b1"] != nil)
    first = nil
    let provider = DurabilityStampProvider()
    let relaunched = owner(directory, provider: provider)
    #expect(provider.events.allSatisfy { $0.hasPrefix("observe:p:") })
    #expect(!relaunched.desiredView(engine: "").readyForSync)
    try relaunched.submit(profile: "p", mutations: [rename("b0", "After crash")])
    let events = provider.events
    let firstMint = try #require(events.firstIndex(where: { $0.hasPrefix("mint:") }))
    let observations = Array(events[..<firstMint])
    #expect(Set(observations) == [
      "observe:p:0000000000001-000000-device",
      "observe:p:0000000000002-000000-device",
      "observe:p:0000000000003-000000-device"
    ])
    for (_, stamp) in accepted.pendingStamps { #expect(observations.contains("observe:p:\(stamp.hlc)")) }
    #expect(events[firstMint] == "mint:p")
    #expect(relaunched.pendingEditStamp(profileId: "p", nodeId: "b0")?.hlc != accepted.pendingStamps["b0"]?.hlc)
  }

  @Test func unconfirmedEditSurvivesCrashRelaunch() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = DurabilityStampProvider()
    var first: BookmarkCoordinator? = owner(directory, provider: provider)
    first!.seed(engine: "", document: document(), ready: false)
    try first!.submit(profile: "p", mutations: [rename("b0", "Stamped")])
    #expect(first!.pendingEditStamp(profileId: "p", nodeId: "b0") != nil)
    provider.linked = false
    try first!.submit(profile: "p", mutations: [rename("b0", "Unconfirmed")])
    #expect(first!.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    #expect(first!.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
    first = nil
    let restored = owner(directory)
    #expect(restored.hasUnconfirmedEdit(profileId: "alias", nodeId: "b0"))
    #expect(restored.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
    #expect(restored.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Unconfirmed")
  }

  @Test func restampIsJournaledAndOnlyItsExactAckClearsUnconfirmedAfterRelaunch() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = DurabilityStampProvider()
    provider.linked = false
    var first: BookmarkCoordinator? = owner(directory, provider: provider)
    first!.seed(engine: "", document: document(), ready: false)
    try first!.submit(profile: "p", mutations: [rename("b0", "Unconfirmed")])
    provider.linked = true
    first!.restampUnconfirmed(profileId: "p")
    let stamp = try #require(first!.pendingEditStamp(profileId: "p", nodeId: "b0"))
    #expect(first!.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    first = nil
    var restored: BookmarkCoordinator? = owner(directory)
    #expect(restored!.pendingEditStamp(profileId: "p", nodeId: "b0") == stamp)
    #expect(restored!.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    restored!.ackPendingEditStamp(profileId: "p", nodeId: "b0", hlc: "wrong")
    #expect(restored!.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    restored!.supersedePendingEditStamp(profileId: "p", nodeId: "b0", remoteHlc: "9999999999999-999999-remote")
    #expect(restored!.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    restored!.restampUnconfirmed(profileId: "p")
    let finalStamp = try #require(restored!.pendingEditStamp(profileId: "p", nodeId: "b0"))
    restored!.ackPendingEditStamp(profileId: "p", nodeId: "b0", hlc: finalStamp.hlc)
    restored = nil
    let acknowledged = owner(directory)
    #expect(!acknowledged.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    #expect(acknowledged.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
  }

  @Test func failedRestampKeepsMemoryAndJournalUnchangedAcrossRelaunch() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = DurabilityStampProvider()
    provider.linked = false
    let failure = DurabilityWriteFailure()
    var operations = BookmarkPendingFileOperations.live
    let liveSync = operations.syncFile
    operations.syncFile = { url in
      if failure.enabled { throw DurabilityTestFailure.injected }
      try liveSync(url)
    }
    let coordinator = owner(directory, operations: operations, provider: provider)
    coordinator.seed(engine: "", document: document(), ready: false)
    try coordinator.submit(profile: "p", mutations: [rename("b0", "Unconfirmed")])
    let before = coordinator.desiredView(engine: "")
    let journal = directory.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = try Data(contentsOf: journal)
    provider.linked = true
    failure.enabled = true
    coordinator.restampUnconfirmed(profileId: "p")
    #expect(coordinator.desiredView(engine: "") == before)
    #expect(coordinator.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
    #expect(coordinator.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    #expect(try Data(contentsOf: journal) == bytes)
    let restored = owner(directory)
    #expect(restored.desiredView(engine: "") == before)
    #expect(restored.hasUnconfirmedEdit(profileId: "p", nodeId: "b0"))
    #expect(restored.pendingEditStamp(profileId: "p", nodeId: "b0") == nil)
  }
}

private enum DurabilityTestFailure: Error { case injected }

private final class DurabilityWriteFailure {
  var enabled = false
}

private final class DurabilityStampProvider {
  var linked = true
  private var tick = 0
  private(set) var events: [String] = []
  var providers: BookmarkStampProviders {
    .init(mintEditStamp: { profile in
      self.events.append("mint:\(profile)")
      guard self.linked else { return nil }
      self.tick += 1
      return BookmarkEditStamp(hlc: String(format: "%013d-000000-device", self.tick), origin: "device")
    }, observeEditStamp: { profile, hlc in
      self.events.append("observe:\(profile):\(hlc)")
      self.tick = max(self.tick, Int(hlc.prefix(13)) ?? 0)
    })
  }
}

private final class DurabilityWriteGate: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var held = false
  var operations: BookmarkPendingFileOperations {
    var operations = BookmarkPendingFileOperations.live
    let liveSync = operations.syncFile
    operations.syncFile = { url in
      self.lock.lock()
      let hold = !self.held
      self.held = true
      self.lock.unlock()
      if hold {
        self.entered.signal()
        guard self.release.wait(timeout: .now() + 10) == .success else { throw DurabilityTestFailure.injected }
      }
      try liveSync(url)
    }
    return operations
  }
}

private final class DurabilityWorkProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedReceipts: [String: BookmarkReceipt] = [:]
  private var storedErrors: [String] = []
  private var storedReadView: BookmarkDesiredView?
  private var storedReadMember: Bool?
  private var storedReadStamp: BookmarkEditStamp?
  var errors: [String] { lock.withLock { storedErrors } }
  var readView: BookmarkDesiredView? { lock.withLock { storedReadView } }
  var readMember: Bool? { lock.withLock { storedReadMember } }
  var readStamp: BookmarkEditStamp? { lock.withLock { storedReadStamp } }
  func accept(_ key: String, _ receipt: BookmarkReceipt) { lock.withLock { storedReceipts[key] = receipt } }
  func receipt(_ key: String) -> BookmarkReceipt? { lock.withLock { storedReceipts[key] } }
  func fail(_ error: any Error) { lock.withLock { storedErrors.append(String(describing: error)) } }
  func read(view: BookmarkDesiredView, member: Bool, stamp: BookmarkEditStamp?) {
    lock.withLock { storedReadView = view; storedReadMember = member; storedReadStamp = stamp }
  }
}

extension BookmarkDurabilityConcurrencyTests {
  @Test func readersDoNotWaitWhileALargeCheckpointIsBuilt() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", pendingStore: BookmarkPendingStore(directory: directory))
    coordinator.seed(engine: "", document: BookmarkCoordinatorTests().document((0..<20_000).map { "https://site\($0).test/" }), ready: false)
    let stop = DurabilityStopFlag()
    let longest = DurabilityLongestWait()
    let readerDone = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      while !stop.isSet {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = coordinator.desiredView(engine: "").revision
        longest.record(DispatchTime.now().uptimeNanoseconds - start)
      }
      readerDone.signal()
    }
    var submitTimes: [UInt64] = []
    for index in 0..<2 {
      let start = DispatchTime.now().uptimeNanoseconds
      try coordinator.submit(profile: "p", mutations: [rename("b\(index)", "Renamed \(index)")])
      submitTimes.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    stop.set()
    #expect(readerDone.wait(timeout: .now() + 10) == .success)
    let fastestSubmit = try #require(submitTimes.min())
    #expect(longest.value * 2 < fastestSubmit, "longest read \(longest.value / 1_000_000) ms, fastest submit \(fastestSubmit / 1_000_000) ms")
  }

  @Test func failureAfterRenameReportsSavedUnconfirmedAndRetryAfterRelaunchDedupes() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var operations = BookmarkPendingFileOperations.live
    let directorySyncs = DurabilityCounter()
    let liveSync = operations.syncDirectory
    operations.syncDirectory = { url in
      if directorySyncs.next() == 1 { throw BookmarkPendingStoreError.io("fsync journal directory", EIO) }
      try liveSync(url)
    }
    let coordinator = owner(directory, operations: operations)
    coordinator.seed(engine: "", document: document(), ready: false)
    let before = coordinator.desiredView(engine: "")
    let add = BookmarkMutation(method: "addBookmark", args: [["profileId": "p", "url": "https://r1.test", "title": "R1"]])
    #expect(throws: BookmarkPendingStoreError.savedUnconfirmed("fsync journal directory", EIO)) { try coordinator.submit(profile: "p", mutations: [add], requestID: "r1") }
    #expect(coordinator.desiredView(engine: "") == before)
    #expect(coordinator.recoveryNotice?.kind == .unavailableJournal)
    #expect(throws: BookmarkPendingStoreError.unavailable) { try coordinator.submit(profile: "p", mutations: [self.rename("b0", "Later")]) }
    let relaunched = owner(directory)
    let urls = { (owner: BookmarkCoordinator) in owner.desiredView(engine: "").document["nodes"]?.object?.values.compactMap { $0["url"]?.string }.filter { $0 == "https://r1.test" }.count ?? 0 }
    #expect(urls(relaunched) == 1)
    let retried = try relaunched.submit(profile: "p", mutations: [add], requestID: "r1")
    #expect(urls(relaunched) == 1)
    #expect(retried.results.count == 1)
  }
}

final class DurabilityStopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
  func set() { lock.lock(); value = true; lock.unlock() }
}

final class DurabilityLongestWait: @unchecked Sendable {
  private let lock = NSLock()
  private var longest: UInt64 = 0
  var value: UInt64 { lock.lock(); defer { lock.unlock() }; return longest }
  func record(_ nanoseconds: UInt64) { lock.lock(); longest = max(longest, nanoseconds); lock.unlock() }
}

final class DurabilityCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
