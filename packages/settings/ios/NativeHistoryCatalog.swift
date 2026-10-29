import ArdiaCore
import Foundation
import SolaraEngine
import SolaraUI

@MainActor
final class ArdiaHistoryClient: EngineClient {
  enum Failure: Error {
    case invalidReply
    case engine(String)
  }

  private var observing = false

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {
    guard !observing else { return }
    observing = true
    ArdiaCoreEngineBridge.observe("history.changed") { payload in
      nonisolated(unsafe) let payload = payload
      let deliver: @MainActor @Sendable () -> Void = {
        MainActor.assumeIsolated {
          guard let profile = payload["profile"] as? String else { return }
          let changes = payload["kind"] as? String == "batch" ? payload["changes"] as? [[String: Any]] ?? [] : [payload]
          for change in changes {
            guard let kind = change["kind"] as? String else { continue }
            switch kind {
            case "visit":
              guard let url = change["u"] as? String, let title = change["t"] as? String,
                let visits = change["n"] as? Int, let at = change["at"] as? Double else { continue }
              handler(.visit(profile: profile, url: url, title: title, visits: visits, at: at))
            case "modified":
              let rows = (change["rows"] as? [[String: Any]] ?? []).compactMap { row -> HistoryModifiedRow? in
                guard let url = row["u"] as? String, let title = row["t"] as? String,
                  let visits = row["n"] as? Int else { return nil }
                return HistoryModifiedRow(url: url, title: title, visits: visits)
              }
              handler(.modified(profile: profile, rows: rows))
            case "deleted":
              handler(.deleted(profile: profile, all: change["all"] as? Bool ?? false, urls: change["urls"] as? [String] ?? []))
            default:
              break
            }
          }
        }
      }
      if Thread.isMainThread { MainActor.assumeIsolated { deliver() } } else { DispatchQueue.main.async(execute: deliver) }
    }
  }

  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
    ArdiaCoreEngineBridge.observe("bookmarks.changed") { payload in
      nonisolated(unsafe) let payload = payload
      let deliver: @MainActor @Sendable () -> Void = {
        MainActor.assumeIsolated {
          if let profile = payload["profile"] as? String { handler(profile) }
        }
      }
      if Thread.isMainThread { MainActor.assumeIsolated { deliver() } } else { DispatchQueue.main.async(execute: deliver) }
    }
  }

  func watchBookmarks(engineProfile: String) async throws {
    _ = try await call("ac_bookmarks_watch", profile: engineProfile)
  }

  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree {
    let data = try await call("ac_bookmarks_tree", profile: engineProfile)
    return try JSONDecoder().decode(EngineBookmarkTree.self, from: data)
  }

  func watchHistory(engineProfile: String) async throws {
    _ = try await call("ac_history_watch", profile: engineProfile)
  }

  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] {
    let data = try await call("ac_history_query", profile: engineProfile, args: ["maxUrls": maxUrls, "maxVisits": maxVisits])
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rows = object["entries"] as? [[String: Any]] else { throw Failure.invalidReply }
    return try rows.map { row in
      guard let url = row["u"] as? String, let title = row["t"] as? String,
        let visits = row["n"] as? Int, let times = row["v"] as? [Double] else { throw Failure.invalidReply }
      return EngineHistoryRow(url: url, title: title, visits: visits, visitTimes: times)
    }
  }

  private func call(_ name: String, profile: String, args: [String: Int] = [:]) async throws -> Data {
    let body = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    return try await withCheckedThrowingContinuation { continuation in
      ArdiaCoreEngineBridge.call(name, profile: profile, args: body) { json in
        let data = Data(json.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          continuation.resume(throwing: Failure.invalidReply)
          return
        }
        if let error = object["error"] as? String {
          continuation.resume(throwing: Failure.engine(error))
        } else {
          continuation.resume(returning: data)
        }
      }
    }
  }
}

@MainActor
enum NativeHistoryCatalog {
  static let catalog = LibraryCatalog(client: ArdiaHistoryClient())

  static func start(engineProfiles: [String]) async {
    NewTabSources.shared.useHistoryCatalog(catalog)
    NewTabSources.shared.useBookmarkCatalog(catalog)
    await catalog.start(engineProfiles: engineProfiles)
  }

  static func bookmarkWriteComplete(engineProfile: String) async {
    await start(engineProfiles: [engineProfile])
    await catalog.reloadBookmarks(engineProfile: engineProfile)
  }

  static func bookmarksSnapshot(engineProfile: String) -> [String: Any] {
    let bookmarks = catalog.bookmarks(engineProfile: engineProfile)
    return ["count": bookmarks.urlCount, "ready": bookmarks.ready, "revision": bookmarks.revision]
  }

  static func snapshot(engineProfile: String) -> [String: Any] {
    let history = catalog.history(engineProfile: engineProfile)
    return [
      "count": history.entries.count,
      "ready": history.ready,
      "floor": history.floor.isFinite ? history.floor as Any : "-Infinity",
      "revision": history.revision,
    ]
  }
}
