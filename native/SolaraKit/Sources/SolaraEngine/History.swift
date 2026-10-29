import Foundation
import Observation

public struct EngineHistoryRow: Sendable, Equatable {
  public var url: String
  public var title: String
  public var visits: Int
  public var visitTimes: [Double]

  public init(url: String, title: String, visits: Int, visitTimes: [Double]) {
    self.url = url
    self.title = title
    self.visits = visits
    self.visitTimes = visitTimes
  }
}

public struct HistoryModifiedRow: Sendable, Equatable {
  public var url: String
  public var title: String
  public var visits: Int

  public init(url: String, title: String, visits: Int) {
    self.url = url
    self.title = title
    self.visits = visits
  }
}

public enum HistoryChange: Sendable, Equatable {
  case visit(profile: String, url: String, title: String, visits: Int, at: Double)
  case modified(profile: String, rows: [HistoryModifiedRow])
  case deleted(profile: String, all: Bool, urls: [String])

  public var profile: String {
    switch self {
    case .visit(let profile, _, _, _, _), .modified(let profile, _), .deleted(let profile, _, _): profile
    }
  }
}

public struct HistoryEntry: Sendable, Equatable {
  public var url: String
  public var title: String
  public var visits: Int
  public var lastVisit: Double
  public var visitTimes: [Double]
  public var visitCount: Int { visits }

  public init(url: String, title: String, visits: Int, lastVisit: Double, visitTimes: [Double]) {
    self.url = url
    self.title = title
    self.visits = visits
    self.lastVisit = lastVisit
    self.visitTimes = visitTimes
  }
}

public struct HistorySnapshot: Sendable, Equatable {
  public var entries: [HistoryEntry]
  public var floor: Double
  public var ready: Bool
  public var revision: Int

  public init(entries: [HistoryEntry] = [], floor: Double = -.infinity, ready: Bool = false, revision: Int = 0) {
    self.entries = entries
    self.floor = floor
    self.ready = ready
    self.revision = revision
  }
}

@MainActor
public protocol EngineClient: AnyObject {
  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void)
  func watchHistory(engineProfile: String) async throws
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow]
  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void)
  func watchBookmarks(engineProfile: String) async throws
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree
  func storedFavicon(page: String, engineProfile: String) async throws -> Data?
  func fetchFavicon(source: String, engineProfile: String) async -> Data?
  func bundledFavicon(page: String, dark: Bool) async -> Data?
  func storeFavicon(page: String, source: String, data: Data, engineProfile: String) async throws
}

@MainActor
final class HistoryLibrary {
  static let maxURLs = 5_000
  static let maxVisitTimes = 50

  let engineProfile: String
  private let client: any EngineClient
  private let publish: @MainActor (HistorySnapshot) -> Void
  private(set) var snapshot = HistorySnapshot()
  private var loading = false
  private var again = false
  private var queued: [HistoryChange] = []

  init(engineProfile: String, client: any EngineClient, publish: @escaping @MainActor (HistorySnapshot) -> Void) {
    self.engineProfile = engineProfile
    self.client = client
    self.publish = publish
  }

  func reload() async {
    if loading {
      again = true
      return
    }
    loading = true
    defer { loading = false }
    repeat {
      again = false
      queued = []
      do {
        try await client.watchHistory(engineProfile: engineProfile)
        let rows = try await client.queryHistory(engineProfile: engineProfile, maxUrls: Self.maxURLs, maxVisits: Self.maxVisitTimes)
        let read = Array(rows.prefix(Self.maxURLs))
        let floor = read.count >= Self.maxURLs ? read.map { $0.visitTimes.last ?? 0 }.min() ?? -.infinity : -.infinity
        var entries = read.filter { Self.shown($0.url) }.map {
          let times = Array($0.visitTimes.suffix(Self.maxVisitTimes))
          return HistoryEntry(url: $0.url, title: $0.title, visits: $0.visits, lastVisit: times.last ?? 0, visitTimes: times)
        }.sorted { $0.lastVisit > $1.lastVisit }
        for change in queued {
          if case .deleted(_, true, _) = change { again = true }
          else { entries = Self.applying(change, to: entries) }
        }
        update(entries: entries, floor: floor, ready: true)
      } catch {
        break
      }
    } while again
  }

  func receiveDuringLoad(_ change: HistoryChange) -> Bool {
    guard loading else { return false }
    queued.append(change)
    return true
  }

  func apply(_ changes: [HistoryChange]) -> Bool {
    var entries = snapshot.entries
    var reload = false
    for change in changes {
      if case .deleted(_, true, _) = change { reload = true }
      else if case .modified(_, let rows) = change, Self.addsUnknown(rows, to: entries) { reload = true }
      else { entries = Self.applying(change, to: entries) }
    }
    update(entries: entries, floor: nil, ready: snapshot.ready)
    return reload
  }

  private func update(entries: [HistoryEntry], floor: Double?, ready: Bool) {
    let nextFloor = max(snapshot.floor, floor ?? -.infinity, entries.count >= Self.maxURLs ? entries.last?.lastVisit ?? -.infinity : -.infinity)
    guard entries != snapshot.entries || nextFloor != snapshot.floor || ready != snapshot.ready else { return }
    snapshot = HistorySnapshot(entries: entries, floor: nextFloor, ready: ready, revision: snapshot.revision + 1)
    publish(snapshot)
  }

  private static func addsUnknown(_ rows: [HistoryModifiedRow], to entries: [HistoryEntry]) -> Bool {
    let known = Set(entries.map(\.url))
    return rows.contains { shown($0.url) && !known.contains($0.url) }
  }

  private static func shown(_ url: String) -> Bool {
    let prefix = url.lowercased()
    return prefix.hasPrefix("http:") || prefix.hasPrefix("https:") || prefix.hasPrefix("file:")
  }

  private static func applying(_ change: HistoryChange, to entries: [HistoryEntry]) -> [HistoryEntry] {
    switch change {
    case .visit(_, let url, let title, let visits, let at):
      guard shown(url) else { return entries }
      var next = entries
      let old = next.firstIndex { $0.url == url }.map { next.remove(at: $0) }
      if let old, old.visitTimes.contains(at) { return entries }
      let times = Array(((old?.visitTimes ?? []) + [at]).sorted().suffix(maxVisitTimes))
      let entry = HistoryEntry(url: url, title: title.isEmpty ? old?.title ?? "" : title, visits: max(visits, 1), lastVisit: times.last ?? at, visitTimes: times)
      let index = next.firstIndex { $0.lastVisit <= entry.lastVisit } ?? next.endIndex
      next.insert(entry, at: index)
      return Array(next.prefix(maxURLs))
    case .modified(_, let rows):
      var next = entries
      var byURL: [String: HistoryModifiedRow] = [:]
      for row in rows { byURL[row.url] = row }
      for row in byURL.values {
        guard let index = entries.firstIndex(where: { $0.url == row.url }) else { continue }
        let old = entries[index]
        if (row.title == old.title || row.title.isEmpty) && row.visits == old.visits { continue }
        next[index].title = row.title.isEmpty ? old.title : row.title
        next[index].visits = row.visits
      }
      return next
    case .deleted(_, _, let urls):
      let gone = Set(urls)
      return entries.filter { !gone.contains($0.url) }
    }
  }
}

@MainActor
@Observable
public final class LibraryCatalog {
  public private(set) var histories: [String: HistorySnapshot] = [:]
  public private(set) var bookmarkSnapshots: [String: BookmarkSnapshot] = [:]
  @ObservationIgnored private let client: any EngineClient
  @ObservationIgnored public private(set) var favicons: FaviconLibrary?
  @ObservationIgnored private var libraries: [String: HistoryLibrary] = [:]
  @ObservationIgnored private var bookmarkLibraries: [String: BookmarkLibrary] = [:]
  @ObservationIgnored private var bookmarkObservers: [String: [UUID: AsyncStream<BookmarkSnapshot>.Continuation]] = [:]
  @ObservationIgnored private var pending: [HistoryChange] = []
  @ObservationIgnored private var flushScheduled = false
  @ObservationIgnored private var observing = false
  @ObservationIgnored private var observers: [String: [UUID: AsyncStream<HistorySnapshot>.Continuation]] = [:]

  public init(client: any EngineClient) {
    self.client = client
    favicons = FaviconLibrary(client: client)
  }

  public func history(engineProfile: String) -> HistorySnapshot { histories[engineProfile] ?? HistorySnapshot() }

  public func bookmarks(engineProfile: String) -> BookmarkSnapshot { bookmarkSnapshots[engineProfile] ?? BookmarkSnapshot() }

  public func observeBookmarks(engineProfile: String) -> AsyncStream<BookmarkSnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<BookmarkSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    bookmarkObservers[engineProfile, default: [:]][id] = continuation
    continuation.yield(bookmarks(engineProfile: engineProfile))
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.bookmarkObservers[engineProfile]?[id] = nil }
    }
    return stream
  }

  public func observe(engineProfile: String) -> AsyncStream<HistorySnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<HistorySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    observers[engineProfile, default: [:]][id] = continuation
    continuation.yield(history(engineProfile: engineProfile))
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.observers[engineProfile]?[id] = nil }
    }
    return stream
  }

  public func start(engineProfiles: [String]) async {
    if !observing {
      observing = true
      client.observeHistory { [weak self] change in self?.receive(change) }
      client.observeBookmarks { [weak self] profile in self?.bookmarkChanged(engineProfile: profile) }
    }
    for profile in Set(engineProfiles).sorted() where !profile.hasPrefix("incognito:") {
      if libraries[profile] == nil {
        libraries[profile] = HistoryLibrary(engineProfile: profile, client: client) { [weak self] snapshot in
          self?.histories[profile] = snapshot
          if let continuations = self?.observers[profile]?.values {
            for continuation in continuations { continuation.yield(snapshot) }
          }
        }
      }
      if libraries[profile]?.snapshot.ready != true { await libraries[profile]?.reload() }
      if bookmarkLibraries[profile] == nil {
        bookmarkLibraries[profile] = BookmarkLibrary(engineProfile: profile, client: client) { [weak self] snapshot in
          self?.bookmarkSnapshots[profile] = snapshot
          if let continuations = self?.bookmarkObservers[profile]?.values {
            for continuation in continuations { continuation.yield(snapshot) }
          }
        }
      }
      if bookmarkLibraries[profile]?.snapshot.ready != true { await bookmarkLibraries[profile]?.reload() }
    }
  }

  public func reloadBookmarks(engineProfile: String) async {
    await bookmarkLibraries[engineProfile]?.reload()
  }

  private func bookmarkChanged(engineProfile: String) {
    guard let library = bookmarkLibraries[engineProfile] else { return }
    Task { await library.reload() }
  }

  public func reload(engineProfile: String) async {
    await libraries[engineProfile]?.reload()
  }

  private func receive(_ change: HistoryChange) {
    switch change {
    case .deleted(_, let all, let urls): favicons?.invalidate(engineProfile: change.profile, pages: all ? nil : urls)
    case .visit(_, let url, _, _, _): favicons?.forgetMisses(engineProfile: change.profile, pages: [url])
    case .modified(_, let rows): favicons?.forgetMisses(engineProfile: change.profile, pages: rows.map(\.url))
    }
    guard let library = libraries[change.profile] else { return }
    if library.receiveDuringLoad(change) { return }
    pending.append(change)
    if !flushScheduled {
      flushScheduled = true
      Task { await self.flushPending() }
    }
  }

  public func flushPending() async {
    let changes = pending
    pending = []
    flushScheduled = false
    var byProfile: [String: [HistoryChange]] = [:]
    for change in changes { byProfile[change.profile, default: []].append(change) }
    for (profile, batch) in byProfile {
      guard let library = libraries[profile] else { continue }
      if library.apply(batch) { await library.reload() }
    }
  }

}
