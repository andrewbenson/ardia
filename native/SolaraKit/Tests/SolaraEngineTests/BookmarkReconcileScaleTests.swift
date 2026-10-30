import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkReconcileScaleTests {
  private func flatFolder(_ ids: [String], engine: String = "") -> BookmarkFlat {
    let roots = BookmarkFlat.roots(engine)
    var records: [JSONValue] = [["id": .string(roots.bar), "kind": "folder", "parent": nil, "title": "Bar", "addedAt": 0, "children": JSONValue(ids)], ["id": .string(roots.other), "kind": "folder", "parent": nil, "title": "Other", "addedAt": 0, "children": []]]
    for id in ids { records.append(["id": .string(id), "kind": "url", "parent": .string(roots.bar), "title": .string("T\(id)"), "url": .string("https://\(id).test/"), "addedAt": 1]) }
    return BookmarkFlat(records: records)
  }

  @Test(arguments: ["swap", "delete", "drag"]) func fiveThousandBookmarkFolderDiffsQuickly(_ edit: String) {
    let ids = (0..<5000).map { "n\($0)" }
    let before = flatFolder(ids)
    var reordered = ids
    switch edit {
    case "swap": reordered.swapAt(10, 4000)
    case "delete": reordered.remove(at: 7)
    default: reordered.insert(reordered.remove(at: 4500), at: 3)
    }
    var after = flatFolder(reordered)
    var renamed = after.nodes["n20"]?.object ?? [:]
    renamed["title"] = "Renamed"
    after.nodes["n20"] = .object(renamed)
    let start = DispatchTime.now().uptimeNanoseconds
    let ops = BookmarkReconcile.operations(from: before, to: after, engine: "")
    let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    #expect(ops == Self.referenceOperations(from: before, to: after, engine: ""))
    #expect(elapsed < 250, "5000-bookmark \(edit) diff took \(elapsed) ms")
  }

  @Test func indexedDiffMatchesTheReferenceOnRandomEdits() {
    var generator = SplitMix(seed: 0x5eed)
    for round in 0..<3000 {
      let engine = round % 3 == 0 ? "e" : ""
      let roots = BookmarkFlat.roots(engine)
      let before = randomTree(&generator, engine: engine, roots: roots, prefix: "a")
      let after = mutate(before, &generator, roots: roots, round: round)
      #expect(BookmarkReconcile.operations(from: before, to: after, engine: engine) == Self.referenceOperations(from: before, to: after, engine: engine), "round \(round)")
    }
  }

  private func randomTree(_ generator: inout SplitMix, engine: String, roots: BookmarkRoots, prefix: String) -> BookmarkFlat {
    var records: [JSONValue] = []
    var children: [String: [String]] = [roots.bar: [], roots.other: []]
    var folders = [roots.bar, roots.other]
    var order: [String] = []
    var parents: [String: String] = [:]
    var kinds: [String: String] = [:]
    for index in 0..<Int(generator.next() % 40) {
      let id = "\(prefix)\(index)"
      let parent = folders[Int(generator.next() % UInt64(folders.count))]
      let folder = generator.next() % 4 == 0
      children[parent, default: []].append(id)
      parents[id] = parent
      kinds[id] = folder ? "folder" : "url"
      order.append(id)
      if folder { folders.append(id); children[id] = [] }
    }
    for root in [roots.bar, roots.other] { records.append(["id": .string(root), "kind": "folder", "parent": nil, "title": "R", "addedAt": 0, "children": JSONValue(children[root] ?? [])]) }
    for id in order {
      var record: JSONObject = ["id": .string(id), "kind": .string(kinds[id]!), "parent": .string(parents[id]!), "title": .string("t\(id)"), "addedAt": 1]
      if kinds[id] == "folder" { record["children"] = JSONValue(children[id] ?? []) } else { record["url"] = .string("https://\(id).test/") }
      records.append(.object(record))
    }
    return BookmarkFlat(records: records)
  }

  private func mutate(_ tree: BookmarkFlat, _ generator: inout SplitMix, roots: BookmarkRoots, round: Int) -> BookmarkFlat {
    var next = tree
    let folders = next.children.keys
    let movable = next.order.filter { next.nodes[$0]?["parent"]?.isNull == false }
    for step in 0..<Int(generator.next() % 6) {
      switch generator.next() % 5 {
      case 0 where !movable.isEmpty:
        let id = movable[Int(generator.next() % UInt64(movable.count))]
        for folder in next.children.keys { next.children[folder] = next.children[folder]?.filter { !BookmarkReconcile.same($0, id) } }
      case 1 where !folders.isEmpty:
        let folder = folders[Int(generator.next() % UInt64(folders.count))]
        if var list = next.children[folder], list.count > 1 {
          list.swapAt(Int(generator.next() % UInt64(list.count)), Int(generator.next() % UInt64(list.count)))
          next.children[folder] = list
        }
      case 2 where !movable.isEmpty && !folders.isEmpty:
        let id = movable[Int(generator.next() % UInt64(movable.count))]
        let target = folders[Int(generator.next() % UInt64(folders.count))]
        guard !BookmarkReconcile.same(id, target) else { break }
        for folder in next.children.keys { next.children[folder] = next.children[folder]?.filter { !BookmarkReconcile.same($0, id) } }
        var list = next.children[target] ?? []
        list.insert(id, at: Int(generator.next() % UInt64(list.count + 1)))
        next.children[target] = list
        var node = next.nodes[id]?.object ?? [:]
        node["parent"] = .string(target)
        next.nodes[id] = .object(node)
      case 3 where !movable.isEmpty:
        let id = movable[Int(generator.next() % UInt64(movable.count))]
        var node = next.nodes[id]?.object ?? [:]
        node["title"] = .string("changed \(round) \(step)")
        next.nodes[id] = .object(node)
      default:
        let id = "b\(round)-\(step)"
        let target = [roots.bar, roots.other][Int(generator.next() % 2)]
        next.nodes[id] = ["kind": "url", "parent": .string(target), "title": "new", "url": .string("https://\(id).test/"), "addedAt": 2]
        next.order.append(id)
        var list = next.children[target] ?? []
        list.insert(id, at: Int(generator.next() % UInt64(list.count + 1)))
        if generator.next() % 7 == 0, let first = list.first { list.append(first) }
        next.children[target] = list
      }
    }
    if generator.next() % 9 == 0, let folder = folders.first { next.children[folder] = (next.children[folder] ?? []) + ["missing-\(round)"] }
    return next
  }

  static func referenceOperations(from: BookmarkFlat, to: BookmarkFlat, engine: String) -> [JSONValue] {
    let roots = BookmarkFlat.roots(engine)
    var parents = from.nodes.mapValues { $0["parent"] ?? .null }
    var kids = from.children
    var ops: [JSONValue] = []
    var queue = [roots.bar, roots.other]
    var cursor = 0
    func opParent(_ id: String) -> String { BookmarkReconcile.same(id, roots.bar) ? "bar" : BookmarkReconcile.same(id, roots.other) ? "other" : id }
    while cursor < queue.count {
      let folder = queue[cursor]
      cursor += 1
      if kids[folder] == nil { kids[folder] = [] }
      for (index, id) in (to.children[folder] ?? []).enumerated() {
        guard let node = to.nodes[id] else { continue }
        let was = from.nodes[id]
        if parents[id] == nil {
          var op: JSONObject = ["op": "add", "id": .string(id), "k": node["kind"] == "url" ? "u" : "f", "t": node["title"] ?? ""]
          if let url = node["url"] { op["u"] = url }
          op["a"] = node["addedAt"] ?? 0
          if node["key"]?.truthy == true { op["key"] = node["key"] }
          op["parent"] = .string(opParent(folder))
          op["index"] = JSONValue(index)
          ops.append(.object(op))
          var list = kids[folder] ?? []
          list.insert(id, at: min(index, list.count))
          kids[folder] = list
          parents[id] = .string(folder)
          if node["kind"] == "folder" { kids[id] = [] }
        } else {
          if parents[id] != .string(folder) || (kids[folder] ?? []).firstIndex(where: { BookmarkReconcile.same($0, id) }) != index {
            if let parent = parents[id]?.string, var old = kids[parent] {
              BookmarkReconcile.removeSplice(&old, id)
              kids[parent] = old
            }
            var list = kids[folder] ?? []
            list.insert(id, at: min(index, list.count))
            kids[folder] = list
            parents[id] = .string(folder)
            ops.append(["op": "move", "id": .string(id), "parent": .string(opParent(folder)), "index": JSONValue(index)])
          }
          if let was, was["title"] != node["title"] || (node["url"] != nil && was["url"] != node["url"]) {
            var op: JSONObject = ["op": "update", "id": .string(id), "t": node["title"] ?? ""]
            if let url = node["url"] { op["u"] = url }
            ops.append(.object(op))
          }
        }
        if node["kind"] == "folder" { queue.append(id) }
      }
    }
    for id in from.order {
      guard to.nodes[id] == nil, from.nodes[id]?["parent"]?.isNull == false else { continue }
      var under = false
      var at = parents[id]?.string
      var visited = Set<JSKey>()
      while let parent = at, visited.insert(JSKey(parent)).inserted {
        if to.nodes[parent] == nil { under = true }
        at = parents[parent]?.string
      }
      if !under { ops.append(["op": "remove", "id": .string(id)]) }
    }
    return ops
  }

}

struct SplitMix {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E3779B97F4A7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
  }
}
