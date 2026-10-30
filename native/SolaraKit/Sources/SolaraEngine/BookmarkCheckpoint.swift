import Foundation
import SolaraModel

struct BookmarkStoredRequest {
  let payload: JSONValue
  let receipt: BookmarkReceipt
}

struct BookmarkCheckpointInput {
  let views: JSMap<BookmarkDesiredView>
  let bases: JSMap<BookmarkFlat>
  let owners: JSMap<String>
  let requestID: String?
  let payload: JSONValue
  let receipt: BookmarkReceipt?
  let conflicts: [JSONValue]?
}

struct BookmarkCheckpoint {
  let payload: JSONValue
  let requests: JSMap<BookmarkStoredRequest>
  let conflicts: [JSONValue]
  let legacyPendingEngines: Set<JSKey>
  let owners: JSMap<String>
}

final class BookmarkDurability {
  let store: BookmarkPendingStore?
  var notice: BookmarkRecoveryNotice?
  var writable = true
  var restoredViews: JSMap<BookmarkDesiredView> = [:]
  var restoredBases: JSMap<BookmarkFlat> = [:]
  var owners: JSMap<String> = [:]
  var requests: JSMap<BookmarkStoredRequest> = [:]
  var conflicts: [JSONValue] = []
  var legacyPendingEngines = Set<JSKey>()

  init(store: BookmarkPendingStore?) {
    self.store = store
    guard let store else { return }
    let loaded = store.load()
    notice = loaded.recoveryNotice
    writable = loaded.writable
    guard let payload = loaded.payload else { return }
    do {
      guard payload["kind"] == "bookmarkCoordinator",
        let engines = payload["engines"]?.array,
        let receipts = payload["requests"]?.array,
        let conflicts = payload["conflicts"]?.array,
        let legacy = payload["legacyPendingEngines"]?.array,
        legacy.allSatisfy({ $0.string != nil }) else { throw BookmarkPendingStoreError.invalidEnvelope }
      var views: JSMap<BookmarkDesiredView> = [:]
      var bases: JSMap<BookmarkFlat> = [:]
      var owners: JSMap<String> = [:]
      var requests: JSMap<BookmarkStoredRequest> = [:]
      for entry in engines {
        let view = try Self.decodeView(entry["view"] ?? .null)
        guard views[view.engine] == nil, let records = entry["base"]?.array,
          let owner = entry["ownerProfile"]?.string else { throw BookmarkPendingStoreError.invalidEnvelope }
        try Self.validateRecords(records, engine: view.engine)
        views[view.engine] = view
        bases[view.engine] = BookmarkFlat(records: records)
        owners[view.engine] = owner
      }
      for entry in receipts {
        guard let id = entry["id"]?.string, requests[id] == nil, let request = entry["payload"],
          let results = entry["results"]?.array else { throw BookmarkPendingStoreError.invalidEnvelope }
        let view = try Self.decodeView(entry["view"] ?? .null)
        requests[id] = BookmarkStoredRequest(payload: request, receipt: BookmarkReceipt(view: view, results: results))
      }
      restoredViews = views
      restoredBases = bases
      self.owners = owners
      self.requests = requests
      self.conflicts = conflicts
      legacyPendingEngines = Set(legacy.compactMap(\.string).map(JSKey.init))
    } catch {
      let recovered = store.recoverUnreadable(reason: "Invalid bookmark checkpoint: \(error)")
      notice = recovered.recoveryNotice
      writable = recovered.writable
    }
  }

  func receipt(requestID: String?, payload: JSONValue) throws -> BookmarkReceipt? {
    guard let requestID, let stored = requests[requestID] else { return nil }
    guard stored.payload == payload else { throw BookmarkCoordinatorError.conflictingRequest }
    return stored.receipt
  }

  func prepare(_ input: BookmarkCheckpointInput) throws -> BookmarkCheckpoint {
    try prepare(views: input.views, bases: input.bases, owners: input.owners, requestID: input.requestID, payload: input.payload, receipt: input.receipt, conflicts: input.conflicts)
  }

  func prepare(views: JSMap<BookmarkDesiredView>, bases: JSMap<BookmarkFlat>, owners: JSMap<String>, requestID: String? = nil, payload: JSONValue = .null, receipt: BookmarkReceipt? = nil, conflicts: [JSONValue]? = nil, legacyPendingEngines: Set<JSKey>? = nil) throws -> BookmarkCheckpoint {
    guard writable else { throw BookmarkPendingStoreError.unavailable }
    var nextRequests = requests
    if let requestID, let receipt { nextRequests[requestID] = BookmarkStoredRequest(payload: payload, receipt: receipt) }
    let nextConflicts = conflicts ?? self.conflicts
    let nextLegacy = legacyPendingEngines ?? self.legacyPendingEngines
    let checkpoint: JSONValue = [
      "kind": "bookmarkCoordinator",
      "engines": .array(views.map { engine, view in
        ["ownerProfile": .string(owners[engine] ?? self.owners[engine] ?? engine), "view": Self.encodeView(view), "base": .array(bases[engine]?.records ?? [])]
      }),
      "requests": .array(nextRequests.map { id, request in
        ["id": .string(id), "payload": request.payload, "view": Self.encodeView(request.receipt.view), "results": .array(request.receipt.results)]
      }),
      "conflicts": .array(nextConflicts),
      "legacyPendingEngines": .array(nextLegacy.sorted { jsKeyPrecedes($0.text, $1.text) }.map { .string($0.text) })
    ]
    if store != nil {
      for (_, view) in views { try Self.validateDocument(view.document, engine: view.engine) }
      for (engine, base) in bases { try Self.validateRecords(base.records, engine: engine) }
      guard try JSONValue.parse(checkpoint.text()) == checkpoint else { throw BookmarkPendingStoreError.invalidEnvelope }
    }
    return BookmarkCheckpoint(payload: checkpoint, requests: nextRequests, conflicts: nextConflicts, legacyPendingEngines: nextLegacy, owners: owners)
  }

  func install(_ checkpoint: BookmarkCheckpoint) {
    requests = checkpoint.requests
    conflicts = checkpoint.conflicts
    legacyPendingEngines = checkpoint.legacyPendingEngines
    owners = checkpoint.owners
  }

  func recordWriteFailure(_ error: Error) {
    if case BookmarkPendingStoreError.savedUnconfirmed = error {
      writable = false
      notice = BookmarkRecoveryNotice(kind: .unavailableJournal, message: "A bookmark change may have been saved but could not be confirmed. Bookmark changes are paused until Solara restarts.", preservedPath: store?.journalURL.path)
    } else {
      notice = BookmarkRecoveryNotice(kind: .unavailableJournal, message: "Bookmark changes could not be saved. The previous view was kept.", preservedPath: store?.journalURL.path)
    }
  }

  static func encodeView(_ view: BookmarkDesiredView) -> JSONValue {
    ["engine": .string(view.engine), "document": view.document, "revision": .string(String(view.revision)), "hasView": .bool(view.hasView), "failedPushes": JSONValue(view.failedPushes), "retryNotBeforeMs": view.retryNotBeforeMs.map(JSONValue.number) ?? .null, "requiresRead": .bool(view.requiresRead), "inFlightTarget": view.inFlightTarget ?? .null, "structuralBreak": view.structuralBreak.map { JSONValue($0) } ?? .null,
     "unconfirmedEdits": .array(view.unconfirmedEdits.map(\.text).sorted(by: jsKeyPrecedes).map(JSONValue.string)),
     "stamps": .array(view.pendingStamps.map { id, stamp in ["id": .string(id), "hlc": .string(stamp.hlc), "origin": .string(stamp.origin)] })]
  }

  private static func decodeView(_ value: JSONValue) throws -> BookmarkDesiredView {
    guard let engine = value["engine"]?.string, let document = value["document"],
      let revisionText = value["revision"]?.string, let revision = UInt64(revisionText),
      let hasView = value["hasView"]?.bool, let stamps = value["stamps"]?.array,
      let structuralBreak = value["structuralBreak"], structuralBreak.isNull || structuralBreak.int != nil else { throw BookmarkPendingStoreError.invalidEnvelope }
    try validateDocument(document, engine: engine)
    var pending: JSMap<BookmarkEditStamp> = [:]
    for stamp in stamps {
      guard let id = stamp["id"]?.string, pending[id] == nil,
        let hlc = stamp["hlc"]?.string, let origin = stamp["origin"]?.string else { throw BookmarkPendingStoreError.invalidEnvelope }
      pending[id] = BookmarkEditStamp(hlc: hlc, origin: origin)
    }
    let unconfirmed: Set<JSKey>
    if let value = value["unconfirmedEdits"] {
      guard let ids = value.array, ids.allSatisfy({ $0.string != nil }),
        Set(ids.compactMap(\.string).map(JSKey.init)).count == ids.count else { throw BookmarkPendingStoreError.invalidEnvelope }
      unconfirmed = Set(ids.compactMap(\.string).map(JSKey.init))
    } else { unconfirmed = [] }
    let failures = value["failedPushes"] ?? 0
    let deadline = value["retryNotBeforeMs"] ?? .null
    let requiresRead = value["requiresRead"] ?? false
    guard let failureCount = failures.int, (0...64).contains(failureCount),
      deadline.isNull || deadline.number?.isFinite == true, let needsRead = requiresRead.bool else { throw BookmarkPendingStoreError.invalidEnvelope }
    let target = value["inFlightTarget"].flatMap { value -> JSONValue? in value.isNull ? Optional<JSONValue>.none : Optional.some(value) }
    if let target { try validateDocument(target, engine: engine) }
    return BookmarkDesiredView(engine: engine, document: document, revision: revision, hasView: hasView, readyForSync: false, structuralBreak: structuralBreak.int, failedPushes: failureCount, retryNotBeforeMs: deadline.number, requiresRead: needsRead, inFlightTarget: target, pendingStamps: pending, unconfirmedEdits: unconfirmed)
  }

  func validateAcceptance(_ document: JSONValue, engine: String) throws {
    if store != nil { try Self.validateDocument(document, engine: engine) }
  }

  private static func validateDocument(_ document: JSONValue, engine: String) throws {
    guard let nodes = document["nodes"]?.object, let roots = document["roots"]?.object else { throw BookmarkPendingStoreError.invalidEnvelope }
    for (id, node) in nodes {
      guard BookmarkReconcile.same(node["id"]?.string, id), node["title"]?.string != nil,
        node["addedAt"]?.number?.isFinite == true, let parent = node["parentId"], parent.isNull || parent.string != nil,
        node["kind"] == "folder" || node["kind"] == "url" else { throw BookmarkPendingStoreError.invalidEnvelope }
      if let parent = parent.string, nodes[parent]?["kind"] != "folder" { throw BookmarkPendingStoreError.invalidEnvelope }
      if node["kind"] == "folder" {
        guard let children = node["children"]?.array,
          children.allSatisfy({ child in child.string.map { nodes[$0] != nil && BookmarkReconcile.same(nodes[$0]?["parentId"]?.string, id) } == true }),
          Set(children.compactMap(\.string).map(JSKey.init)).count == children.count else { throw BookmarkPendingStoreError.invalidEnvelope }
      } else if node["url"]?.string == nil { throw BookmarkPendingStoreError.invalidEnvelope }
    }
    for (id, _) in nodes {
      var seen = Set<JSKey>()
      var cursor: String? = id
      while let next = cursor {
        guard seen.insert(JSKey(next)).inserted else { throw BookmarkPendingStoreError.invalidEnvelope }
        cursor = nodes[next]?["parentId"]?.string
      }
    }
    let expected = BookmarkFlat.roots(engine)
    for (_, root) in roots {
      guard let bar = root["bar"]?.string, let other = root["other"]?.string,
        BookmarkReconcile.same(bar, expected.bar), BookmarkReconcile.same(other, expected.other),
        nodes[bar]?["kind"] == "folder", nodes[other]?["kind"] == "folder",
        nodes[bar]?["parentId"]?.isNull == true, nodes[other]?["parentId"]?.isNull == true else { throw BookmarkPendingStoreError.invalidEnvelope }
    }
    var reached = Set<JSKey>()
    var queue = nodes.isEmpty ? [] : [expected.bar, expected.other]
    var cursor = 0
    while cursor < queue.count {
      let id = queue[cursor]
      cursor += 1
      guard let node = nodes[id], reached.insert(JSKey(id)).inserted else { throw BookmarkPendingStoreError.invalidEnvelope }
      queue.append(contentsOf: node["children"]?.array?.compactMap(\.string) ?? [])
    }
    guard reached.count == nodes.count else { throw BookmarkPendingStoreError.invalidEnvelope }
  }

  private static func validateRecords(_ records: [JSONValue], engine: String) throws {
    var ids = Set<JSKey>()
    for record in records {
      guard let id = record["id"]?.string, ids.insert(JSKey(id)).inserted,
        let parent = record["parent"], parent.isNull || parent.string != nil,
        record["title"]?.string != nil, record["addedAt"]?.number != nil,
        record["kind"] == "folder" || record["kind"] == "url" else { throw BookmarkPendingStoreError.invalidEnvelope }
      if record["kind"] == "folder" {
        guard let children = record["children"]?.array, children.allSatisfy({ $0.string != nil }) else { throw BookmarkPendingStoreError.invalidEnvelope }
      } else if record["url"]?.string == nil { throw BookmarkPendingStoreError.invalidEnvelope }
    }
    try validateDocument(BookmarkFlat(records: records).document(profiles: ["owner"]), engine: engine)
    for record in records {
      if let parent = record["parent"]?.string, !ids.contains(JSKey(parent)) { throw BookmarkPendingStoreError.invalidEnvelope }
      if let children = record["children"]?.array, children.contains(where: { !ids.contains(JSKey($0.string!)) }) { throw BookmarkPendingStoreError.invalidEnvelope }
    }
  }
}
