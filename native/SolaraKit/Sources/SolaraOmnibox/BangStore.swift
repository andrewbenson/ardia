import Foundation
import CoreFoundation
import Observation

public struct BangFetchReply: Sendable {
  public let status: Int
  public let body: String?
  public let etag: String?
  public let contentType: String?

  public init(status: Int, body: String? = nil, etag: String? = nil, contentType: String? = nil) {
    self.status = status
    self.body = body
    self.etag = etag
    self.contentType = contentType
  }
}

public struct BangRefresh: Sendable, Equatable {
  public enum Status: Sendable, Equatable {
    case http(Int)
    case skipped
    case failed
  }

  public enum Result: Sendable, Equatable {
    case updated
    case unchanged
    case failed
    case fresh
  }

  public let at: Double
  public let status: Status
  public let result: Result
}

@MainActor
@Observable
public final class BangStore {
  public enum Source: Sendable {
    case bundled
    case stored
    case fetched
  }

  public typealias Fetch = @Sendable (String?) async throws -> BangFetchReply
  public typealias ReadDocument = (String) -> String?
  public typealias WriteDocument = (String, String) throws -> Void
  public typealias SaveDocument = (String, String) async throws -> Void

  public static let refreshEvery: Double = 86_400_000
  public static let listDocument = "bangs.txt"
  public static let stateDocument = "bangs-state.json"
  public static let endpoint = URL(string: "https://services.helium.imput.net/bangs.json")!

  @ObservationIgnored private let readDocument: ReadDocument
  @ObservationIgnored private let writeDocument: WriteDocument
  @ObservationIgnored private let saveDocument: SaveDocument
  @ObservationIgnored private let fetch: Fetch
  @ObservationIgnored private let now: @MainActor () -> Double
  @ObservationIgnored private var pending: Task<BangRefresh, Never>?
  @ObservationIgnored private var once: Task<BangRefresh, Never>?
  @ObservationIgnored private var attemptedAt: Double?
  @ObservationIgnored private var loaded: (any BangTable)?
  public private(set) var source: Source?
  public private(set) var etag: String?
  public private(set) var revision = 0
  public private(set) var refreshes: [BangRefresh] = []
  public private(set) var checkedAt: Double?

  public init(directory: URL? = nil, endpoint: URL = BangStore.endpoint,
    now: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 * 1000 },
    fetch: Fetch? = nil, readDocument: ReadDocument? = nil, writeDocument: WriteDocument? = nil,
    saveDocument: SaveDocument? = nil) {
    let root = directory ?? Self.documentDirectory()
    let read: ReadDocument = readDocument ?? { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
    let write: WriteDocument = writeDocument ?? { name, contents in
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    self.readDocument = read
    self.writeDocument = write
    self.saveDocument = saveDocument ?? { name, contents in try write(name, contents) }
    self.fetch = fetch ?? { try await BangURLSession.fetch(endpoint: endpoint, etag: $0) }
    self.now = now
    if let text = read(Self.stateDocument), let data = text.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let number = value["checkedAt"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      checkedAt = number.doubleValue
    }
  }

  public var table: any BangTable { load() }

  public func tableForUse() -> any BangTable { load() }

  @discardableResult public func load() -> any BangTable {
    if let loaded { return loaded }
    if let stored = readBangDocument(readDocument(Self.listDocument)) {
      loaded = stored.table
      etag = stored.etag
      source = .stored
    } else {
      loaded = BundledBangs.table
      source = .bundled
    }
    revision += 1
    return loaded!
  }

  public func refreshOnce() async -> BangRefresh {
    if let once { return await once.value }
    let task = Task { await self.refresh() }
    once = task
    return await task.value
  }

  public func refresh() async -> BangRefresh {
    if let pending { return await pending.value }
    let at = now()
    if let checked = attemptedAt ?? checkedAt, at >= checked && at - checked < Self.refreshEvery {
      return record(at, .skipped, .fresh)
    }
    attemptedAt = at
    let task = Task { await self.performRefresh(at) }
    pending = task
    let result = await task.value
    pending = nil
    return result
  }

  private func performRefresh(_ at: Double) async -> BangRefresh {
    _ = load()
    let requestEtag = source == .bundled ? BundledBangs.etag : etag
    checkedAt = at
    if let data = try? JSONSerialization.data(withJSONObject: ["checkedAt": at], options: [.fragmentsAllowed]),
      let text = String(data: data, encoding: .utf8) {
      try? writeDocument(Self.stateDocument, text)
    }
    do {
      let reply = try await fetch(requestEtag)
      if reply.status == 304 { return record(at, .http(304), .unchanged) }
      guard reply.status == 200, let body = reply.body, !body.isEmpty,
        reply.contentType?.range(of: "json", options: .caseInsensitive) != nil,
        let slim = slimBangs(body), let next = checkedBangTable(slim) else {
        return record(at, .http(reply.status), .failed)
      }
      try await saveDocument(Self.listDocument, bangDocument(etag: reply.etag, slim: slim))
      etag = reply.etag
      loaded = next
      source = .fetched
      revision += 1
      return record(at, .http(200), .updated)
    } catch {
      return record(at, .failed, .failed)
    }
  }

  private func record(_ at: Double, _ status: BangRefresh.Status, _ result: BangRefresh.Result) -> BangRefresh {
    let entry = BangRefresh(at: at, status: status, result: result)
    refreshes.append(entry)
    return entry
  }

  private static func documentDirectory() -> URL {
    if let dataDir = ProcessInfo.processInfo.environment["ARDIA_DATA_DIR"], !dataDir.isEmpty {
      return URL(fileURLWithPath: dataDir, isDirectory: true)
    }
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Ardia", isDirectory: true)
  }
}
