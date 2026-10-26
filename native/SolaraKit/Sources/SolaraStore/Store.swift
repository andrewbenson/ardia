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
  public let commands: [Command]
  public let changes: ChangeSet
  public let patch: Patch
  public let effects: [Effect]
  public let result: JSONValue?
  public let durable: Bool
  public let state: BrowserState
}

public struct StoreMemory: Sendable, Equatable {
  public var endedPrivateDownloads: Set<String> = []
  public init() {}
}

public struct Transaction {
  public var state: BrowserState
  public var memory: StoreMemory
  public var ids: IdSource
  public let now: Double
  public var effects: [Effect] = []
  public var result: JSONValue? = nil

  public mutating func newId(_ prefix: String) -> String { ids.next(prefix) }
}

public final class Store: Sendable {
  public static let ringSize = 1024

  struct Core: ~Copyable {
    var state: BrowserState
    var memory: StoreMemory
    var ids: IdSource
    var rev: Int
    var ring: [Patch] = []
    var ringStart = 0
  }

  struct Delivery {
    var queue: [Commit] = []
    var draining = false
  }

  public typealias Listener = @Sendable (Commit) -> Void

  private let core: Mutex<Core>
  private let delivery = Mutex(Delivery())
  private let listeners = Mutex<[(id: Int, listener: Listener)]>([])
  private let nextListener = Atomic<Int>(0)
  private let clock: @Sendable () -> Double
  public let checksInvariants: Bool

  public init(
    state: BrowserState = BrowserState(),
    memory: StoreMemory = StoreMemory(),
    ids: IdSource? = nil,
    rev: Int = 0,
    checksInvariants: Bool = Store.debugBuild,
    clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }
  ) {
    self.clock = clock
    self.checksInvariants = checksInvariants
    core = Mutex(Core(state: state, memory: memory, ids: ids ?? IdSource.random(now: clock()), rev: rev))
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
  public var ids: IdSource { core.withLock { $0.ids } }
  public var memory: StoreMemory { core.withLock { $0.memory } }

  @discardableResult
  public func dispatch(_ command: Command, origin: Origin = .native) throws -> Commit {
    try dispatch([command], origin: origin)
  }

  @discardableResult
  public func dispatch(_ commands: [Command], origin: Origin = .native) throws -> Commit {
    let now = clock()
    let commit: Commit = try core.withLock { core in
      var tx = Transaction(state: core.state, memory: core.memory, ids: core.ids, now: now)
      for command in commands { try Reducer.apply(command, to: &tx) }
      try Settle.run(&tx)
      if checksInvariants { try Invariants.check(tx.state) }
      let changes = ChangeSet(from: core.state, to: tx.state)
      let changed = !changes.isEmpty
      let rev = changed ? core.rev + 1 : core.rev
      let patch = Patch(rev: rev, changes: changes, state: tx.state)
      if changed {
        core.state = tx.state
        core.rev = rev
        if core.ring.count < Store.ringSize {
          core.ring.append(patch)
        } else {
          core.ring[core.ringStart] = patch
          core.ringStart = (core.ringStart + 1) % Store.ringSize
        }
      }
      core.memory = tx.memory
      core.ids = tx.ids
      let commit = Commit(
        rev: rev, origin: origin, commands: commands, changes: changes, patch: patch, effects: tx.effects,
        result: tx.result, durable: commands.contains(where: \.isDurable), state: core.state)
      if changed || !tx.effects.isEmpty { delivery.withLock { $0.queue.append(commit) } }
      return commit
    }
    drain()
    return commit
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
