import Foundation
import SolaraModel
import SolaraStore

@MainActor
public final class HistoryHintsProvider {
  private let catalog: LibraryCatalog
  private let store: Store
  private var subscription: Int?
  private var streams: [String: Task<Void, Never>] = [:]
  private var retryTask: Task<Void, Never>?
  private var observedMapping: [String: String] = [:]
  private var started = false

  public init(catalog: LibraryCatalog, store: Store) {
    self.catalog = catalog
    self.store = store
  }

  isolated deinit {
    if let subscription { store.unsubscribe(subscription) }
    retryTask?.cancel()
    for task in streams.values { task.cancel() }
  }

  public func start() {
    guard !started else { return }
    started = true
    subscription = store.subscribe { [weak self] commit in
      guard !commit.changes.profiles.isEmpty else { return }
      Task { @MainActor [weak self] in
        guard let self, self.started, self.observedMapping != self.profileMapping() else { return }
        self.refresh()
      }
    }
    refresh()
  }

  public func stop() {
    started = false
    if let subscription { store.unsubscribe(subscription) }
    subscription = nil
    retryTask?.cancel()
    retryTask = nil
    for task in streams.values { task.cancel() }
    streams = [:]
  }

  public func refresh() {
    retryTask?.cancel()
    retryTask = nil
    let mapping = profileMapping()
    observedMapping = mapping
    let engines = Set(mapping.values)
    if started { observe(engines) }
    var hints = JSMap<[HistoryHint]>()
    for profile in mapping.keys.sorted() {
      let engine = mapping[profile]!
      let snapshot = catalog.history(engineProfile: engine)
      guard snapshot.ready else { continue }
      hints[profile] = snapshot.entries.map { HistoryHint(url: $0.url, title: $0.title, favicon: nil) }
    }
    publish(hints, mapping: mapping)
  }

  private func profileMapping() -> [String: String] {
    profileMapping(store.state)
  }

  private func profileMapping(_ state: BrowserState) -> [String: String] {
    Dictionary(uniqueKeysWithValues: state.profiles.keys.filter { !Ids.isIncognitoProfile($0) }.map { ($0, state.engineProfile($0)) })
  }

  private func publish(_ hints: JSMap<[HistoryHint]>, mapping: [String: String]) {
    guard store.state.caches.historyHints != hints else { return }
    do {
      try store.transact(origin: .native) { session in
        guard profileMapping(session.state) == mapping else { return }
        session.update { $0.caches.historyHints = hints }
      }
    } catch is StoreBusy {
      scheduleRetry()
    } catch {
      FileHandle.standardError.write(Data("HistoryHintsProvider: \(error)\n".utf8))
    }
  }

  private func scheduleRetry() {
    guard started, retryTask == nil else { return }
    retryTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
      guard let self, self.started else { return }
      self.retryTask = nil
      self.refresh()
    }
  }

  private func observe(_ engines: Set<String>) {
    for engine in Array(streams.keys) where !engines.contains(engine) {
      streams.removeValue(forKey: engine)?.cancel()
    }
    for engine in engines where streams[engine] == nil {
      let stream = catalog.observe(engineProfile: engine)
      let initial = catalog.history(engineProfile: engine)
      let catalog = catalog
      streams[engine] = Task { @MainActor [weak self] in
        await catalog.start(engineProfiles: [engine])
        var previous = initial
        for await snapshot in stream {
          guard !Task.isCancelled else { return }
          guard snapshot != previous else { continue }
          previous = snapshot
          guard let self, self.started else { return }
          self.refresh()
        }
      }
    }
  }
}
