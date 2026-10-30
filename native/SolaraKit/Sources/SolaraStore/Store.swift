import Foundation
import SolaraModel
import Synchronization

public enum Origin: Sendable, Hashable {
  case bridge
  case engine
  case sync
  case native
  case load
}

public struct Commit: Sendable {
  public let rev: Int
  public let origin: Origin
  public let fromSync: Bool
  public let commands: [Command]
  public let changes: ChangeSet
  public let patch: Patch
  public let effects: [Effect]
  public let result: JSONValue?
  public let durable: Bool
  public let state: BrowserState
}

public struct StoreBusy: Error, CustomStringConvertible {
  public var description: String { "a user transaction is open, so a sync apply has to retry from fresh state" }
}

public struct StorePersistenceRefused: Error, CustomStringConvertible {
  public let description: String
}

typealias QueuedSyncApply = @Sendable (Session) throws -> Void

public final class Store: Sendable {
  public static let ringSize = 1024

  struct Core: ~Copyable {
    var state: BrowserState
    var memory: StoreMemory
    var rev: Int
    var ring: [Patch] = []
    var ringStart = 0
    var held: Session? = nil
    var heldSince: Double = 0
    var heldFromSync = false
    var queuedFromSync: [QueuedSyncApply] = []
    var replaying = false

    mutating func record(_ patch: Patch, state next: BrowserState) {
      state = next
      rev = patch.rev
      if ring.count < Store.ringSize {
        ring.append(patch)
      } else {
        ring[ringStart] = patch
        ringStart = (ringStart + 1) % Store.ringSize
      }
    }
  }

  public static let heldTransactionLimit: Double = 10_000

  struct Delivery {
    var queue: [Commit] = []
    var draining = false
  }

  public typealias Listener = @Sendable (Commit) -> Void

  private let core: Mutex<Core>
  private let delivery = Mutex(Delivery())
  private let listeners = Mutex<[(id: Int, listener: Listener)]>([])
  private let nextListener = Atomic<Int>(0)
  private let syncOriginsOn: Atomic<Bool>
  private let clock: @Sendable () -> Double
  public let env: WebAddressing
  public let config: StoreConfig
  public let checksInvariants: Bool
  public let invariantHandler: @Sendable ([String], [Command]) -> Void
  private let onPersistenceRefusal: @Sendable (String) -> Void

  public init(
    state: BrowserState = BrowserState(),
    memory: StoreMemory? = nil,
    rev: Int = 0,
    env: WebAddressing = PlainWebAddressing(),
    config: StoreConfig = StoreConfig(),
    checksInvariants: Bool = Store.debugBuild,
    invariantHandler: @escaping @Sendable ([String], [Command]) -> Void = Store.logInvariants,
    onPersistenceRefusal: @escaping @Sendable (String) -> Void = { _ in },
    clock: @escaping @Sendable () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }
  ) {
    self.invariantHandler = invariantHandler
    self.onPersistenceRefusal = onPersistenceRefusal
    self.clock = clock
    self.env = env
    self.config = config
    syncOriginsOn = Atomic(config.syncOrigins)
    self.checksInvariants = checksInvariants
    let memory = memory ?? StoreMemory(ids: IdSource.random(now: clock()))
    core = Mutex(Core(state: state, memory: memory, rev: rev))
  }

  public static let logInvariants: @Sendable ([String], [Command]) -> Void = { found, commands in
    let names = commands.map(\.name).joined(separator: ", ")
    FileHandle.standardError.write(Data("SolaraStore invariants after \(names): \(found.joined(separator: "; "))\n".utf8))
  }

  public static var debugBuild: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  public var rev: Int { core.withLock { $0.rev } }
  public var state: BrowserState { core.withLock { $0.state } }
  public var snapshot: (rev: Int, state: BrowserState) { core.withLock { ($0.rev, $0.state) } }
  public var memory: StoreMemory { core.withLock { $0.memory } }

  @discardableResult
  public func dispatch(_ command: Command, origin: Origin = .native, fromSync: Bool = false) throws -> Commit {
    try dispatch([command], origin: origin, fromSync: fromSync)
  }

  @discardableResult
  public func dispatch(_ commands: [Command], origin: Origin = .native, fromSync: Bool = false) throws -> Commit {
    let pinned = commands.contains { $0.name == "syncPinsApply" || $0.name == "settlePinChoices" }
    if pinned && commands.count != 1 { throw CommandError("pinned sync commands must be dispatched alone") }
    if let command = commands.first, command.name == "settlePinChoices" {
      let settled = try SettledPinChoices(command.args)
      return try transact(commands: commands, origin: origin, durable: false, fromSync: true, waiting: { settled.apply($0) }, replaying: false) {
        settled.apply($0)
      }!
    }
    if let command = commands.first, command.name == "syncPinsApply" { _ = try SyncPinsApplyRequest(command.args) }
    return try transact(commands: commands, origin: origin, durable: commands.contains(where: \.isDurable), fromSync: fromSync, waiting: nil, replaying: false) { session in
      if commands.count == 1 {
        try session.apply(commands[0])
      } else {
        try session.transaction {
          for command in commands {
            session.now = clock()
            try session.apply(command)
          }
        }
      }
    }!
  }

  public var syncOrigins: Bool { syncOriginsOn.load(ordering: .relaxed) }

  public func useSyncOrigins(_ on: Bool) { syncOriginsOn.store(on, ordering: .relaxed) }

  static func closesSyncWindow(_ commands: [Command]) -> Bool {
    !commands.isEmpty && commands.allSatisfy { $0.name == "endFromSync" }
  }

  public var queuedFromSyncCount: Int { core.withLock { $0.queuedFromSync.count } }

  private func runQueuedFromSync() {
    let replayer = core.withLock { core -> Bool in
      if core.replaying || core.queuedFromSync.isEmpty { return false }
      core.replaying = true
      return true
    }
    guard replayer else { return }
    while let next = core.withLock({ core -> QueuedSyncApply? in
      guard core.held == nil || core.heldFromSync else { return nil }
      return core.queuedFromSync.first
    }) {
      do {
        if try transact(commands: [], origin: .sync, durable: false, fromSync: true, waiting: nil, replaying: true, next) == nil { break }
      } catch {
        FileHandle.standardError.write(Data("SolaraStore: a queued sync session failed: \(error)\n".utf8))
      }
    }
    let again = core.withLock { core -> Bool in
      core.replaying = false
      return !core.queuedFromSync.isEmpty && (core.held == nil || core.heldFromSync)
    }
    if again { runQueuedFromSync() }
  }

  @discardableResult
  public func transact(commands: [Command] = [], origin: Origin = .native, durable: Bool = false, fromSync: Bool = false, _ body: (Session) throws -> Void) throws -> Commit {
    try transact(commands: commands, origin: origin, durable: durable, fromSync: fromSync, waiting: nil, replaying: false, body)!
  }

  public func transactWhenFree(_ body: @escaping @Sendable (Session) throws -> Void) throws {
    _ = try transact(commands: [], origin: .sync, durable: false, fromSync: true, waiting: body, replaying: false, body)
  }

  private func transact(
    commands: [Command], origin: Origin, durable: Bool, fromSync: Bool, waiting: QueuedSyncApply?, replaying: Bool, _ body: (Session) throws -> Void
  ) throws -> Commit? {
    do {
      return try transactPersisting(commands: commands, origin: origin, durable: durable, fromSync: fromSync, waiting: waiting, replaying: replaying, body)
    } catch let refusal as StorePersistenceRefused {
      onPersistenceRefusal(refusal.description)
      throw refusal
    }
  }

  private func transactPersisting(
    commands: [Command], origin: Origin, durable: Bool, fromSync: Bool, waiting: QueuedSyncApply?, replaying: Bool, _ body: (Session) throws -> Void
  ) throws -> Commit? {
    let now = clock()
    let tags = syncOrigins
    let pinned = commands.contains { $0.name == "syncPinsApply" || $0.name == "settlePinChoices" }
    let syncRequest = fromSync || origin == .sync || pinned
    let isolated = (tags && syncRequest) || pinned || waiting != nil || replaying
    let fromSync = tags && syncRequest
    defer {
      drain()
      runQueuedFromSync()
    }
    let commit: Commit? = try core.withLock { core -> Commit? in
      if tags || isolated, let held = core.held, core.heldFromSync != isolated, now - core.heldSince > Store.heldTransactionLimit {
        let heldFromSync = core.heldFromSync
        held.resume(state: core.state, memory: core.memory, now: now)
        held.closeTransactions()
        core.held = nil
        let (_, patch) = try settle(
          from: core.state, rev: core.rev, settled: true, held, origin: heldFromSync ? .sync : .native, fromSync: tags && heldFromSync, tags: tags, commands: [], durable: false)
        if let patch { core.record(patch, state: held.state) }
        core.memory = held.memory
      }
      let heldByUser = core.held != nil && !core.heldFromSync
      if replaying {
        if heldByUser { return nil }
        core.queuedFromSync.removeFirst()
      } else if isolated && (heldByUser || !core.queuedFromSync.isEmpty) && !Self.closesSyncWindow(commands) {
        guard let waiting else { throw StoreBusy() }
        core.queuedFromSync.append(waiting)
        let patch = Patch(rev: core.rev, changes: ChangeSet(), state: core.state)
        return Commit(
          rev: core.rev, origin: origin, fromSync: fromSync, commands: commands, changes: ChangeSet(), patch: patch, effects: [],
          result: commands.first?.name == "settlePinChoices" ? .bool(true) : nil, durable: false,
          state: core.state)
      }
      let session: Session
      if let held = core.held {
        held.resume(state: core.state, memory: core.memory, now: now)
        if now - core.heldSince > Store.heldTransactionLimit { held.closeTransactions() }
        session = held
      } else {
        session = Session(state: core.state, memory: core.memory, env: env, config: config, now: now)
      }
      let checkpoint = config.persistenceRefusal == nil ? nil : (
        state: session.state, memory: session.memory, depth: session.depth, heard: session.heard,
        effects: session.effects, result: session.result, mirroring: session.mirroring, itemSerial: session.itemSerial)
      if replaying {
        session.memory.fromSyncDepth += 1
        defer { session.memory.fromSyncDepth -= 1 }
        try body(session)
      } else {
        try body(session)
      }
      if let reason = config.persistenceRefusal, let checkpoint {
        let before = checkpoint.state.downloads.filter { !$0.isPrivate }.map { $0.persisted() }
        let after = session.state.downloads.filter { !$0.isPrivate }.map { $0.persisted() }
        if session.state.settings != checkpoint.state.settings || after != before {
          session.resume(state: checkpoint.state, memory: checkpoint.memory, now: now)
          session.depth = checkpoint.depth
          session.heard = checkpoint.heard
          session.effects = checkpoint.effects
          session.result = checkpoint.result
          session.mirroring = checkpoint.mirroring
          session.itemSerial = checkpoint.itemSerial
          throw StorePersistenceRefused(description: reason)
        }
      }
      if session.depth > 0 && core.held == nil {
        core.heldSince = now
        core.heldFromSync = isolated
      }
      core.held = session.depth > 0 ? session : nil
      let (commit, patch) = try settle(
        from: core.state, rev: core.rev, settled: core.held == nil, session, origin: origin, fromSync: fromSync, tags: tags, commands: commands, durable: durable)
      if let patch { core.record(patch, state: session.state) }
      core.memory = session.memory
      return commit
    }
    return commit
  }

  private func settle(
    from before: BrowserState, rev current: Int, settled: Bool, _ session: Session, origin: Origin, fromSync: Bool, tags: Bool, commands: [Command], durable: Bool
  ) throws -> (Commit, Patch?) {
    if checksInvariants && settled {
      try Invariants.check(session.state)
      let found = Invariants.violations(session.state)
      if !found.isEmpty { invariantHandler(found, commands) }
    }
    let changes = ChangeSet(from: before, to: session.state)
    let changed = !changes.isEmpty
    let rev = changed ? current + 1 : current
    var patch = Patch(rev: rev, changes: changes, state: session.state)
    patch.fromBridge = tags && origin == .bridge
    patch.fromSync = fromSync
    var seen = Set<Effect>()
    let effects = session.effects.filter { seen.insert($0).inserted }
    let commit = Commit(
      rev: rev, origin: origin, fromSync: fromSync, commands: commands, changes: changes, patch: patch, effects: effects,
      result: session.result, durable: durable, state: changed ? session.state : before)
    if changed || !effects.isEmpty { delivery.withLock { $0.queue.append(commit) } }
    return (commit, changed ? patch : nil)
  }

  public func patches(since rev: Int) -> [Patch]? {
    core.withLock { core in
      if rev >= core.rev { return [] }
      let ordered = Array(core.ring[core.ringStart...] + core.ring[..<core.ringStart])
      guard let first = ordered.first, first.rev <= rev + 1 else { return nil }
      return ordered.filter { $0.rev > rev }
    }
  }

  @discardableResult
  public func subscribe(_ listener: @escaping Listener) -> Int {
    let id = nextListener.add(1, ordering: .relaxed).newValue
    listeners.withLock { $0.append((id, listener)) }
    return id
  }

  public func unsubscribe(_ id: Int) {
    listeners.withLock { $0.removeAll { $0.id == id } }
  }

  private func drain() {
    let owner = delivery.withLock { delivery -> Bool in
      if delivery.draining || delivery.queue.isEmpty { return false }
      delivery.draining = true
      return true
    }
    guard owner else { return }
    while let commit = delivery.withLock({ delivery -> Commit? in
      if delivery.queue.isEmpty {
        delivery.draining = false
        return nil
      }
      return delivery.queue.removeFirst()
    }) {
      for (_, listener) in listeners.withLock({ $0 }) { listener(commit) }
    }
  }
}

public struct InvariantViolation: Error, CustomStringConvertible {
  public let description: String
}

public enum Invariants {
  public static func violations(_ s: BrowserState) -> [String] {
    var out: [String] = []
    var seenIds = Set<String>()
    for id in s.profiles.keys + s.windows.keys + s.tabs.keys + s.groups.keys + s.splits.keys where !seenIds.insert(id).inserted {
      out.append("id \(id) is used twice")
    }
    var placed: [String: String] = [:]
    let peekTabs = Set(s.peeks.values.map(\.tabId))
    for w in s.windows.values {
      var mine = Set<String>()
      for id in w.tabIds {
        if !mine.insert(id).inserted { out.append("window \(w.id) lists \(id) twice") }
        guard let t = s.tabs[id] else {
          out.append("window \(w.id) lists missing tab \(id)")
          continue
        }
        if t.windowId != w.id { out.append("window \(w.id) lists \(id) of window \(t.windowId)") }
        placed[id] = w.id
      }
      if pinnedFirst(w.tabIds, s.tabs, s.groups) != w.tabIds { out.append("window \(w.id) is not pinned first") }
      for (profileId, active) in w.activeTabIds {
        guard let t = s.tabs[active], t.windowId == w.id, t.profileId == profileId else {
          out.append("window \(w.id) shows \(active) for \(profileId)")
          continue
        }
      }
      if !w.tabIds.isEmpty && w.activeTabIds[w.profileId] == nil && w.tabIds.contains(where: { s.tabs[$0]?.profileId == w.profileId }) {
        out.append("window \(w.id) shows no tab for its profile")
      }
    }
    for t in s.tabs.values where placed[t.id] == nil && !peekTabs.contains(t.id) { out.append("tab \(t.id) is in no window") }
    for g in s.groups.values {
      if g.tabIds.isEmpty { out.append("group \(g.id) is empty") }
      guard let w = s.windows[g.windowId] else {
        out.append("group \(g.id) is in no window")
        continue
      }
      let spots = g.tabIds.compactMap { w.tabIds.firstIndex(of: $0) }
      if spots.count != g.tabIds.count { out.append("group \(g.id) holds tabs outside its window") }
      if let low = spots.min(), let high = spots.max(), high - low + 1 != spots.count { out.append("group \(g.id) is not contiguous") }
      if let parent = g.parentId {
        if let p = s.groups[parent] {
          if !g.tabIds.allSatisfy({ p.tabIds.contains($0) }) { out.append("group \(g.id) sits outside its parent") }
        } else {
          out.append("group \(g.id) has a missing parent")
        }
      }
    }
    var paneOf: [String: String] = [:]
    for v in s.splits.values {
      if v.tabIds.count < 2 || v.tabIds.count > Splits.maxPanes { out.append("split \(v.id) has \(v.tabIds.count) panes") }
      for id in v.tabIds {
        if let other = paneOf[id] { out.append("tab \(id) is in splits \(other) and \(v.id)") }
        paneOf[id] = v.id
      }
    }
    let members = s.pinnedGroupMemberSet()
    for t in s.tabs.values {
      if t.tileFolder != nil && t.pinSection != .tile { out.append("tab \(t.id) has a folder but is not a tile") }
      let housed = t.pinned || members.contains(t.id)
      if housed != (t.pinnedUrl != nil && !(t.pinnedUrl ?? "").isEmpty) && !(housed && t.url.isEmpty) {
        out.append("tab \(t.id) pinnedUrl does not match its place")
      }
    }
    return out
  }

  public static func check(_ state: BrowserState) throws {
    var seen = Set<String>()
    for download in state.downloads where !seen.insert(download.id).inserted {
      throw InvariantViolation(description: "download \(download.id) is listed twice")
    }
  }
}
