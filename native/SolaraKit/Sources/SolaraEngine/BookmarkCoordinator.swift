import Foundation
import SolaraModel

public struct BookmarkMutation: Equatable, Sendable {
  public var method: String
  public var args: [JSONValue]
  public init(method: String, args: [JSONValue]) { self.method = method; self.args = args }
}

public enum BookmarkCoordinatorError: Error, Equatable {
  case conflictingRequest
  case staleRevision
  case invalidProfileScope
  case unknownMutation(String)
}

public struct BookmarkEditStamp: Equatable, Sendable {
  public let hlc: String
  public let origin: String
  public init(hlc: String, origin: String) { self.hlc = hlc; self.origin = origin }
  public static func == (lhs: Self, rhs: Self) -> Bool { JSKey(lhs.hlc) == JSKey(rhs.hlc) && JSKey(lhs.origin) == JSKey(rhs.origin) }
}

public struct BookmarkStampProviders {
  public var mintEditStamp: (String) -> BookmarkEditStamp?
  public var observeEditStamp: (String, String) -> Void
  public init(mintEditStamp: @escaping (String) -> BookmarkEditStamp? = { _ in nil }, observeEditStamp: @escaping (String, String) -> Void = { _, _ in }) {
    self.mintEditStamp = mintEditStamp
    self.observeEditStamp = observeEditStamp
  }
}

public struct BookmarkDesiredView: Equatable, Sendable {
  public var engine: String
  public var document: JSONValue
  public var revision: UInt64 = 0
  public var hasView = false
  public var readyForSync = false
  public var structuralBreak: Int?
  public var pendingStamps: JSMap<BookmarkEditStamp> = [:]
  public var unconfirmedEdits: Set<JSKey> = []
  public static func == (lhs: Self, rhs: Self) -> Bool {
    JSKey(lhs.engine) == JSKey(rhs.engine) && lhs.document == rhs.document && lhs.revision == rhs.revision && lhs.hasView == rhs.hasView && lhs.readyForSync == rhs.readyForSync && lhs.structuralBreak == rhs.structuralBreak && lhs.pendingStamps == rhs.pendingStamps && lhs.unconfirmedEdits == rhs.unconfirmedEdits
  }
}

public struct BookmarkMembershipSnapshot: Equatable, Sendable {
  public let engine: String
  public let revision: UInt64
  public let hasView: Bool
  public let readyForSync: Bool
  public let nodeIDsByURL: JSMap<[String]>
  public var urls: Set<JSKey> { Set(nodeIDsByURL.keys.filter { !$0.isEmpty }.map(JSKey.init)) }
  public func contains(_ url: String) -> Bool { !url.isEmpty && nodeIDsByURL[url] != nil }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    JSKey(lhs.engine) == JSKey(rhs.engine) && lhs.revision == rhs.revision && lhs.hasView == rhs.hasView && lhs.readyForSync == rhs.readyForSync && lhs.nodeIDsByURL.mapValues(JSONValue.init) == rhs.nodeIDsByURL.mapValues(JSONValue.init)
  }
}

public struct BookmarkReceipt: Equatable, Sendable {
  public let view: BookmarkDesiredView
  public let results: [JSONValue]
}

public final class BookmarkCoordinator: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private let writerLock = NSLock()
  private var profiles: JSMap<String>
  private var defaultProfile: String
  private let owningProfiles: JSMap<String>
  private let makeID: () -> String
  private let now: () -> Double
  private let stampProviders: BookmarkStampProviders
  private let stampsEnabled: Bool
  private let log: (String) -> Void
  private var runningStampProvider = false
  private var views: JSMap<BookmarkDesiredView> = [:]
  private var bases: JSMap<BookmarkFlat> = [:]
  private let durability: BookmarkDurability
  private var streams: [UUID: (JSKey, BookmarkMembershipObserver)] = [:]

  public init(profiles: JSMap<String>, defaultProfile: String, owningProfiles: JSMap<String> = [:], makeID: @escaping () -> String = { UUID().uuidString.lowercased() }, now: @escaping () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }, stampProviders: BookmarkStampProviders = .init(), stampsEnabled: Bool = false, pendingStore: BookmarkPendingStore? = nil, launchInput: BookmarkLaunchInput = .init(), log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
    self.profiles = profiles
    self.defaultProfile = defaultProfile
    self.owningProfiles = owningProfiles
    self.makeID = makeID
    self.now = now
    self.stampProviders = stampProviders
    self.stampsEnabled = stampsEnabled
    self.log = log
    durability = BookmarkDurability(store: pendingStore)
    durability.legacyPendingEngines.formUnion(launchInput.legacyPendingEngines)
    for (engine, document) in launchInput.documents {
      views[engine] = BookmarkDesiredView(engine: engine, document: document, hasView: true)
      bases[engine] = BookmarkFlat(document: document, engine: engine)
    }
    for (engine, restored) in durability.restoredViews {
      views[engine] = restored
      bases[engine] = durability.restoredBases[engine]
    }
    locked {
      guard stampsEnabled else { return }
      var observed: JSMap<Set<JSKey>> = [:]
      func observe(_ view: BookmarkDesiredView) {
        let owner = durability.owners[view.engine] ?? ownerProfile(view.engine)
        for (_, stamp) in view.pendingStamps {
          var seen = observed[owner] ?? []
          guard seen.insert(JSKey(stamp.hlc)).inserted else { continue }
          observed[owner] = seen
          runStampProvider { stampProviders.observeEditStamp(owner, stamp.hlc) }
        }
      }
      for (_, view) in views { observe(view) }
      for (_, request) in durability.requests { observe(request.receipt.view) }
    }
  }

  public var recoveryNotice: BookmarkRecoveryNotice? { locked { durability.notice } }
  public func dismissRecoveryNotice() { locked { durability.notice = nil } }
  public var recoveryConflicts: [JSONValue] { locked { durability.conflicts } }

  private func owners(for views: JSMap<BookmarkDesiredView>) -> JSMap<String> {
    views.mapValues { durability.owners[$0.engine] ?? ownerProfile($0.engine) }
  }

  private func checkpoint(views: JSMap<BookmarkDesiredView>, bases: JSMap<BookmarkFlat>, requestID: String? = nil, payload: JSONValue = .null, receipt: BookmarkReceipt? = nil, conflicts: [JSONValue]? = nil) -> BookmarkCheckpointInput {
    BookmarkCheckpointInput(views: views, bases: bases, owners: owners(for: views), requestID: requestID, payload: payload, receipt: receipt, conflicts: conflicts)
  }

  private func refuseStampProviderReentry() { locked {} }

  private func writing<T>(_ body: () throws -> T) rethrows -> T {
    refuseStampProviderReentry()
    writerLock.lock()
    defer { writerLock.unlock() }
    return try body()
  }

  private func transact<T>(_ prepare: () throws -> (BookmarkCheckpointInput?, () -> T)) throws -> T {
    try writing {
      let (input, install) = try locked(prepare)
      let checkpoint = try input.map { try durability.prepare($0) }
      do {
        if let checkpoint { try durability.store?.write(checkpoint.payload) }
      } catch {
        locked { durability.recordWriteFailure(error) }
        throw error
      }
      return locked {
        if let checkpoint { durability.install(checkpoint) }
        return install()
      }
    }
  }

  deinit { for stream in streams.values { stream.1.finish() } }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    precondition(!runningStampProvider, "Stamp providers run under the bookmark coordinator lock: they must not call back into the coordinator, do disk I/O, or block on sync")
    return try body()
  }

  private func runStampProvider<T>(_ body: () -> T) -> T {
    runningStampProvider = true
    defer { runningStampProvider = false }
    return body()
  }

  public func engine(profile: String, originalProfile: String? = nil) -> String {
    locked {
      var regular = originalProfile ?? profile
      if regular.hasPrefix("incognito:") {
        regular = regular.firstIndex(of: "@").map { String(regular[regular.index(after: $0)...]) } ?? "default"
      }
      return profiles[regular] ?? profiles[defaultProfile] ?? ""
    }
  }

  public func remap(profiles: JSMap<String>, defaultProfile: String) {
    writing { locked { self.profiles = profiles; self.defaultProfile = defaultProfile } }
  }

  private func aliases(_ engine: String) -> [String] { profiles.filter { BookmarkReconcile.same($1, engine) }.keys }
  private func ownerProfile(_ engine: String) -> String {
    if let owner = owningProfiles[engine] { return owner }
    let conventional = engine.isEmpty ? "default" : engine
    if BookmarkReconcile.same(profiles[conventional], engine) { return conventional }
    return aliases(engine).first ?? conventional
  }

  public func desiredView(engine: String) -> BookmarkDesiredView {
    locked { views[engine] ?? BookmarkDesiredView(engine: engine, document: ["nodes": [:], "roots": [:]]) }
  }

  public func desiredView(profile: String) -> BookmarkDesiredView { desiredView(engine: engine(profile: profile)) }

  func seed(engine: String, document: JSONValue, ready: Bool) {
    let notification = writing {
      locked { () -> (BookmarkMembershipSnapshot, [BookmarkMembershipObserver]) in
        var view = desiredView(engine: engine)
        view.document = document
        view.hasView = true
        view.readyForSync = ready
        view.revision += 1
        views[engine] = view
        bases[engine] = BookmarkFlat(document: document, engine: engine)
        return notifications(engine)
      }
    }
    deliver(notification)
  }

  private func snapshot(_ view: BookmarkDesiredView) -> BookmarkMembershipSnapshot {
    let flat = BookmarkFlat(document: view.document, engine: view.engine)
    var index: JSMap<[String]> = [:]
    for id in flat.order {
      if flat.nodes[id]?["kind"] == "url", let url = flat.nodes[id]?["url"]?.string {
        index[url] = (index[url] ?? []) + [id]
      }
    }
    return BookmarkMembershipSnapshot(engine: view.engine, revision: view.revision, hasView: view.hasView, readyForSync: view.readyForSync, nodeIDsByURL: index)
  }

  public var membershipSnapshot: BookmarkMembershipSnapshot { locked { snapshot(desiredView(engine: engine(profile: defaultProfile))) } }
  public func membershipSnapshot(engine: String) -> BookmarkMembershipSnapshot { locked { snapshot(desiredView(engine: engine)) } }
  public func membership(profile: String, originalProfile: String? = nil, url: String) -> Bool {
    membershipSnapshot(engine: engine(profile: profile, originalProfile: originalProfile)).contains(url)
  }

  public func membershipSnapshots() -> AsyncStream<BookmarkMembershipSnapshot> {
    let selected = locked { engine(profile: defaultProfile) }
    return membershipSnapshots(engine: selected)
  }
  public func membershipSnapshots(engine: String) -> AsyncStream<BookmarkMembershipSnapshot> {
    let pair = AsyncStream<BookmarkMembershipSnapshot>.makeStream()
    let token = UUID()
    let observer = BookmarkMembershipObserver(pair.continuation)
    let initial = locked {
      streams[token] = (JSKey(engine), observer)
      return snapshot(desiredView(engine: engine))
    }
    pair.continuation.onTermination = { [weak self] _ in self?.removeStream(token) }
    observer.yield(initial)
    return pair.stream
  }

  private func removeStream(_ token: UUID) { locked { _ = streams.removeValue(forKey: token) } }
  private func notifications(_ engine: String) -> (BookmarkMembershipSnapshot, [BookmarkMembershipObserver]) {
    (snapshot(desiredView(engine: engine)), streams.values.filter { $0.0 == JSKey(engine) }.map { $0.1 })
  }
  private func deliver(_ notification: (BookmarkMembershipSnapshot, [BookmarkMembershipObserver])) {
    for stream in notification.1 { stream.yield(notification.0) }
  }

  public func pendingEditStamp(profileId: String, nodeId: String) -> BookmarkEditStamp? {
    locked { stampsEnabled ? views[engine(profile: profileId)]?.pendingStamps[nodeId] : nil }
  }

  public func hasUnconfirmedEdit(profileId: String, nodeId: String) -> Bool {
    locked { stampsEnabled && views[engine(profile: profileId)]?.unconfirmedEdits.contains(JSKey(nodeId)) == true }
  }

  @discardableResult
  public func ackPendingEditStamp(profileId: String, nodeId: String, hlc: String) -> Bool {
    clearPendingEditStamp(profileId: profileId, nodeId: nodeId, acknowledged: true) { JSKey($0.hlc) == JSKey(hlc) }
  }

  @discardableResult
  public func supersedePendingEditStamp(profileId: String, nodeId: String, remoteHlc: String) -> Bool {
    clearPendingEditStamp(profileId: profileId, nodeId: nodeId) { jsKeyPrecedes($0.hlc, remoteHlc) }
  }

  private func clearPendingEditStamp(profileId: String, nodeId: String, acknowledged: Bool = false, matches: (BookmarkEditStamp) -> Bool) -> Bool {
    do {
      return try transact {
        guard stampsEnabled else { return (nil, { true }) }
        let engine = engine(profile: profileId)
        guard var view = views[engine], let stamp = view.pendingStamps[nodeId], matches(stamp) else { return (nil, { true }) }
        view.pendingStamps.removeValue(forKey: nodeId)
        if acknowledged { view.unconfirmedEdits.remove(JSKey(nodeId)) }
        var next = views
        next[engine] = view
        let checkpoint = checkpoint(views: next, bases: bases)
        return (checkpoint, { self.views = next; return true })
      }
    } catch { return false }
  }

  @discardableResult
  public func restampUnconfirmed(profileId: String) -> Bool {
    do {
      return try transact {
        guard stampsEnabled else { return (nil, { true }) }
        let engine = engine(profile: profileId)
        guard var view = views[engine] else { return (nil, { true }) }
        let owner = ownerProfile(engine)
        let waiting = view.unconfirmedEdits.filter { view.pendingStamps[$0.text] == nil }.map(\.text).sorted(by: jsKeyPrecedes)
        var changed = false
        for id in waiting {
          guard let stamp = runStampProvider({ stampProviders.mintEditStamp(owner) }) else { break }
          view.pendingStamps[id] = stamp
          changed = true
        }
        guard changed else { return (nil, { true }) }
        var next = views
        next[engine] = view
        let checkpoint = checkpoint(views: next, bases: bases)
        return (checkpoint, { self.views = next; return true })
      }
    } catch { return false }
  }

  @discardableResult
  public func replayPendingStamps(profileId: String, stamps: JSMap<BookmarkEditStamp>) -> Bool {
    do {
      return try transact {
        guard stampsEnabled else { return (nil, { true }) }
        let engine = engine(profile: profileId)
        var view = desiredView(engine: engine)
        guard !view.readyForSync else {
          log("Bookmark stamp replay for \(profileId) refused: \(stamps.count) stamps arrived after bookmarks were ready for sync")
          return (nil, { false })
        }
        let owner = ownerProfile(engine)
        for (_, stamp) in stamps { runStampProvider { stampProviders.observeEditStamp(owner, stamp.hlc) } }
        for (id, stamp) in stamps where view.pendingStamps[id].map({ jsKeyPrecedes($0.hlc, stamp.hlc) }) ?? true { view.pendingStamps[id] = stamp }
        var next = views
        next[engine] = view
        let checkpoint = checkpoint(views: next, bases: bases)
        return (checkpoint, { self.views = next; return true })
      }
    } catch { return false }
  }

  @discardableResult
  public func submit(profile: String, mutations: [BookmarkMutation], fromSync: Bool = false, requestID: String? = nil) throws -> BookmarkReceipt {
    let result = try transact { () throws -> (BookmarkCheckpointInput?, () -> (BookmarkReceipt, (BookmarkMembershipSnapshot, [BookmarkMembershipObserver]))) in
      let engine = engine(profile: profile)
      let payload: JSONValue = ["kind": "submit", "profile": .string(profile), "engine": .string(engine), "fromSync": .bool(fromSync), "mutations": .array(mutations.map { ["method": .string($0.method), "args": .array($0.args)] })]
      if let receipt = try durability.receipt(requestID: requestID, payload: payload) { return (nil, { (receipt, (self.snapshot(self.desiredView(engine: engine)), [])) }) }
      guard durability.writable else { throw BookmarkPendingStoreError.unavailable }
      var view = desiredView(engine: engine)
      let before = view.document
      for mutation in mutations {
        let target: String?
        switch mutation.method {
        case "addBookmark", "addBookmarkFolder": target = mutation.args.first?["profileId"]?.string
        case "addBookmarkTree", "toggleBookmark": target = mutation.args.first?.string
        default: target = nil
        }
        if let target, !BookmarkReconcile.same(self.engine(profile: target), engine) { throw BookmarkCoordinatorError.invalidProfileScope }
      }
      var reducer = BookmarkReducer(document: before, engine: engine, makeID: makeID, now: now)
      let results = try mutations.map { try reducer.apply($0) }
      view.document = reducer.document
      try durability.validateAcceptance(view.document, engine: engine)
      if view.document != before {
        view.revision += 1
        view.hasView = true
        if stampsEnabled && !fromSync {
          let oldNodes = before["nodes"]?.object ?? [:]
          let newNodes = view.document["nodes"]?.object ?? [:]
          var changed = Set<JSKey>()
          var orderedChanges: [String] = []
          func touch(_ id: String) {
            guard changed.insert(JSKey(id)).inserted else { return }
            orderedChanges.append(id)
          }
          for id in oldNodes.keys + newNodes.keys {
            let old = oldNodes[id]
            let new = newNodes[id]
            var oldFields = old?.object
            var newFields = new?.object
            oldFields?.removeValue(forKey: "children")
            newFields?.removeValue(forKey: "children")
            if oldFields != newFields { touch(id) }
          }
          let delta = BookmarkReconcile.operations(from: BookmarkFlat(document: before, engine: engine), to: BookmarkFlat(document: view.document, engine: engine), engine: engine)
          for operation in delta { if let id = operation["id"]?.string { touch(id) } }
          for id in orderedChanges {
            let node = newNodes[id] ?? oldNodes[id]
            guard node?["parentId"]?.string != nil else { continue }
            if let stamp = runStampProvider({ stampProviders.mintEditStamp(ownerProfile(engine)) }) {
              view.pendingStamps[id] = stamp
            } else {
              view.pendingStamps.removeValue(forKey: id)
              view.unconfirmedEdits.insert(JSKey(id))
            }
          }
        }
      }
      let receipt = BookmarkReceipt(view: view, results: results)
      var next = views
      next[engine] = view
      let checkpoint = checkpoint(views: next, bases: bases, requestID: requestID, payload: payload, receipt: receipt)
      return (checkpoint, {
        self.views = next
        return (receipt, self.notifications(engine))
      })
    }
    deliver(result.1)
    return result.0
  }

  @discardableResult
  public func replaceDocument(engine: String, document: JSONValue, expectedRevision: UInt64, requestID: String? = nil) throws -> BookmarkReceipt {
    let result = try transact { () throws -> (BookmarkCheckpointInput?, () -> (BookmarkReceipt, (BookmarkMembershipSnapshot, [BookmarkMembershipObserver]))) in
      let payload: JSONValue = ["kind": "replace", "engine": .string(engine), "document": document, "expectedRevision": .string(String(expectedRevision))]
      if let receipt = try durability.receipt(requestID: requestID, payload: payload) { return (nil, { (receipt, (self.snapshot(self.desiredView(engine: engine)), [])) }) }
      guard durability.writable else { throw BookmarkPendingStoreError.unavailable }
      var view = desiredView(engine: engine)
      guard view.revision == expectedRevision else { throw BookmarkCoordinatorError.staleRevision }
      try durability.validateAcceptance(document, engine: engine)
      if view.document != document { view.document = document; view.revision += 1; view.hasView = true }
      let receipt = BookmarkReceipt(view: view, results: [])
      var next = views
      next[engine] = view
      let checkpoint = checkpoint(views: next, bases: bases, requestID: requestID, payload: payload, receipt: receipt)
      return (checkpoint, {
        self.views = next
        return (receipt, self.notifications(engine))
      })
    }
    deliver(result.1)
    return result.0
  }

  @discardableResult
  public func completeRead(engine: String, document: JSONValue, capturedRevision: UInt64) -> Bool {
    let result: (BookmarkMembershipSnapshot, [BookmarkMembershipObserver])
    do {
      result = try transact { () throws -> (BookmarkCheckpointInput?, () -> (BookmarkMembershipSnapshot, [BookmarkMembershipObserver])) in
        var view = desiredView(engine: engine)
        let fetched = BookmarkFlat(document: document, engine: engine)
        let base = bases[engine] ?? BookmarkFlat(records: [])
        let delta = BookmarkReconcile.operations(from: base, to: BookmarkFlat(document: view.document, engine: engine), engine: engine)
        let replay = BookmarkReconcile.replay(fetched, operations: delta, engine: engine)
        let merged = replay.tree.document(profiles: aliases(engine), preserving: view.document)
        var conflicts = durability.conflicts
        if let offset = replay.structuralBreak {
          let conflict: JSONValue = ["engine": .string(engine), "revision": .string(String(view.revision)), "base": .array(base.records), "desired": view.document, "operations": .array(delta), "structuralBreak": JSONValue(offset)]
          if !conflicts.contains(conflict) { conflicts.append(conflict) }
        }
        let ready = !durability.legacyPendingEngines.contains(JSKey(engine))
        if view.document != merged || view.readyForSync != ready || view.structuralBreak != replay.structuralBreak {
          view.document = merged
          view.hasView = true
          view.readyForSync = ready
          view.structuralBreak = replay.structuralBreak
          view.revision += 1
        }
        var nextViews = views
        var nextBases = bases
        nextViews[engine] = view
        nextBases[engine] = fetched
        let checkpoint = durability.writable ? checkpoint(views: nextViews, bases: nextBases, conflicts: conflicts) : nil
        return (checkpoint, {
          self.views = nextViews
          self.bases = nextBases
          return self.notifications(engine)
        })
      }
    } catch { return false }
    deliver(result)
    return true
  }

}

private struct BookmarkReducer {
  var document: JSONValue
  let engine: String
  let makeID: () -> String
  let now: () -> Double
  var nodes: JSONObject { document["nodes"]?.object ?? [:] }

  mutating func setNodes(_ nodes: JSONObject) { var value = document.object ?? [:]; value["nodes"] = .object(nodes); document = .object(value) }
  func subtree(_ ids: [String]) -> [String] {
    var out: [String] = []
    var visited = Set<JSKey>()
    func walk(_ id: String) {
      guard let node = nodes[id], visited.insert(JSKey(id)).inserted else { return }
      defer { visited.remove(JSKey(id)) }
      out.append(id)
      if node["kind"] == "folder" { for child in node["children"]?.array?.compactMap(\.string) ?? [] { walk(child) } }
    }
    for id in ids { walk(id) }
    return out
  }
  func ancestors(_ id: String) -> [String] {
    var out: [String] = []
    var parent = nodes[id]?["parentId"]?.string
    for _ in 0..<64 {
      guard let id = parent, nodes[id]?["kind"] == "folder" else { break }
      out.append(id)
      parent = nodes[id]?["parentId"]?.string
    }
    return out
  }
  mutating func ensureRoots(_ profile: String) -> BookmarkRoots {
    if let bar = document["roots"]?[profile]?["bar"]?.string, let other = document["roots"]?[profile]?["other"]?.string { return BookmarkRoots(bar: bar, other: other) }
    let roots = BookmarkFlat.roots(engine)
    var next = nodes
    for (id, title) in [(roots.bar, "Bookmarks Bar"), (roots.other, "Other Bookmarks")] where next[id] == nil {
      next[id] = ["kind": "folder", "id": .string(id), "parentId": nil, "title": .string(title), "children": [], "addedAt": 0]
    }
    setNodes(next)
    var values = document.object ?? [:]
    var map = document["roots"]?.object ?? [:]
    map[profile] = ["bar": .string(roots.bar), "other": .string(roots.other)]
    values["roots"] = .object(map)
    document = .object(values)
    return roots
  }
  mutating func insert(_ node: JSONValue, parent: String, index: Double?) {
    guard nodes[parent]?["kind"] == "folder", let id = node["id"]?.string else { return }
    var next = nodes
    var folder = next[parent]?.object ?? [:]
    var children = (folder["children"]?.array?.compactMap(\.string) ?? []).filter { !BookmarkReconcile.same($0, id) }
    children.insert(id, at: BookmarkReconcile.spliceIndex(index, count: children.count))
    folder["children"] = JSONValue(children)
    var value = node.object ?? [:]
    value["parentId"] = .string(parent)
    next[id] = .object(value)
    next[parent] = .object(folder)
    setNodes(next)
  }
  mutating func remove(_ ids: [String]) {
    let gone = Set(subtree(ids).map(JSKey.init))
    var next = nodes.filter { id, _ in !gone.contains(JSKey(id)) }
    for (id, node) in next where node["kind"] == "folder" {
      var folder = node.object ?? [:]
      let children = node["children"]?.array?.compactMap(\.string) ?? []
      if children.contains(where: { gone.contains(JSKey($0)) }) {
        folder["children"] = JSONValue(children.filter { !gone.contains(JSKey($0)) })
        next[id] = .object(folder)
      }
    }
    setNodes(next)
  }
  mutating func apply(_ mutation: BookmarkMutation) throws -> JSONValue {
    let args = mutation.args
    func arg(_ index: Int) -> JSONValue { index < args.count ? args[index] : .null }
    switch mutation.method {
    case "addBookmark", "addBookmarkFolder":
      let options = arg(0)
      let profile = options["profileId"]?.string ?? ""
      let roots = ensureRoots(profile)
      let id = makeID()
      let parent = options["parentId"]?.string ?? roots.bar
      var node: JSONObject = ["kind": mutation.method == "addBookmark" ? "url" : "folder", "id": .string(id), "parentId": .string(parent), "title": options["title"] ?? "", "addedAt": .number(now())]
      if mutation.method == "addBookmark" { node["url"] = options["url"] ?? ""; node["favicon"] = options["favicon"] ?? .null }
      else { node["children"] = [] }
      insert(.object(node), parent: parent, index: options["index"]?.number)
      return .string(id)
    case "updateBookmark":
      guard let id = arg(0).string, var node = nodes[id]?.object else { return .null }
      let patch = arg(1).object ?? [:]
      for (key, value) in patch where node["kind"] == "url" || key == "title" { node[key] = value }
      var next = nodes
      next[id] = .object(node)
      setNodes(next)
      return .null
    case "moveBookmark":
      guard let id = arg(0).string, let parent = arg(1).string, let node = nodes[id], let oldParent = node["parentId"]?.string, !subtree([id]).contains(where: { BookmarkReconcile.same($0, parent) }) else { return .null }
      var next = nodes
      if var folder = next[oldParent]?.object, folder["kind"] == "folder" {
        folder["children"] = JSONValue((folder["children"]?.array?.compactMap(\.string) ?? []).filter { !BookmarkReconcile.same($0, id) })
        next[oldParent] = .object(folder)
        setNodes(next)
      }
      insert(node, parent: parent, index: arg(2).number)
      return .null
    case "removeBookmark":
      if let id = arg(0).string, nodes[id]?["parentId"]?.string != nil { remove([id]) }
      return .null
    case "toggleBookmark":
      let profile = arg(0).string ?? ""
      let page = arg(1)
      let url = page["url"]?.string ?? ""
      guard !url.isEmpty else { return false }
      let roots = document["roots"]?[profile]
      let ids = subtree([roots?["bar"]?.string, roots?["other"]?.string].compactMap { $0 }).filter { nodes[$0]?["kind"] == "url" && nodes[$0]?["url"] == .string(url) }
      if !ids.isEmpty { remove(ids); return false }
      _ = try apply(BookmarkMutation(method: "addBookmark", args: [["profileId": .string(profile), "url": .string(url), "title": page["title"] ?? "", "favicon": page["favicon"] ?? .null]]))
      return true
    case "addBookmarkTree":
      let roots = ensureRoots(arg(0).string ?? "")
      let target = arg(2).string.flatMap { nodes[$0]?["kind"] == "folder" ? $0 : nil } ?? roots.bar
      var next = nodes
      func build(_ draft: JSONValue, parent: String) -> String {
        let id = makeID()
        var node: JSONObject = ["id": .string(id), "parentId": .string(parent), "title": draft["title"] ?? "", "addedAt": draft["addedAt"].flatMap { $0.isNull ? nil : $0 } ?? .number(now())]
        if draft["url"] != nil && draft["children"]?.truthy != true {
          node["kind"] = "url"; node["url"] = draft["url"]; node["favicon"] = .null
          next[id] = .object(node)
        } else {
          node["kind"] = "folder"; node["children"] = []
          next[id] = .object(node)
          node["children"] = JSONValue((draft["children"]?.array ?? []).map { build($0, parent: id) })
          next[id] = .object(node)
        }
        return id
      }
      let ids = (arg(1).array ?? []).map { build($0, parent: target) }
      var folder = next[target]?.object ?? [:]
      var children = folder["children"]?.array?.compactMap(\.string) ?? []
      children.insert(contentsOf: ids, at: BookmarkReconcile.spliceIndex(arg(3).number, count: children.count))
      folder["children"] = JSONValue(children)
      next[target] = .object(folder)
      setNodes(next)
      return JSONValue(ids)
    case "removeBookmarks":
      let removable = (arg(0).array?.compactMap(\.string) ?? []).filter { nodes[$0]?["parentId"]?.truthy == true }
      let set = Set(removable.map(JSKey.init))
      let tops = removable.filter { !ancestors($0).contains(where: { set.contains(JSKey($0)) }) }
      let places: [JSONValue] = tops.map { id in
        let parent = nodes[id]?["parentId"]?.string ?? ""
        let index = nodes[parent]?["kind"] == "folder" ? nodes[parent]?["children"]?.array?.firstIndex(of: .string(id)) ?? -1 : 0
        return ["id": .string(id), "parentId": .string(parent), "index": JSONValue(index)]
      }
      let removed = subtree(tops).compactMap { nodes[$0] }
      if !tops.isEmpty { remove(tops) }
      return ["nodes": .array(removed), "places": .array(places)]
    case "restoreBookmarks":
      var next = nodes
      for node in arg(0)["nodes"]?.array ?? [] { if let id = node["id"]?.string { next[id] = node } }
      let places = (arg(0)["places"]?.array ?? []).enumerated().sorted { a, b in
        let av = a.element["index"]?.number ?? 0
        let bv = b.element["index"]?.number ?? 0
        return av == bv ? a.offset < b.offset : av < bv
      }.map(\.element)
      for place in places {
        guard let parent = place["parentId"]?.string, let id = place["id"]?.string else { continue }
        guard var folder = next[parent]?.object, folder["kind"] == "folder" else { next.removeValue(forKey: id); continue }
        var children = (folder["children"]?.array?.compactMap(\.string) ?? []).filter { !BookmarkReconcile.same($0, id) }
        children.insert(id, at: BookmarkReconcile.spliceIndex(place["index"]?.number, count: children.count))
        folder["children"] = JSONValue(children)
        next[parent] = .object(folder)
      }
      setNodes(next)
      return .null
    default: throw BookmarkCoordinatorError.unknownMutation(mutation.method)
    }
  }
}

private final class BookmarkMembershipObserver {
  private let lock = NSLock()
  private let continuation: AsyncStream<BookmarkMembershipSnapshot>.Continuation
  private var revision: UInt64?

  init(_ continuation: AsyncStream<BookmarkMembershipSnapshot>.Continuation) { self.continuation = continuation }

  func yield(_ snapshot: BookmarkMembershipSnapshot) {
    lock.lock()
    defer { lock.unlock() }
    if let revision, snapshot.revision <= revision { return }
    revision = snapshot.revision
    continuation.yield(snapshot)
  }

  func finish() { continuation.finish() }
}
