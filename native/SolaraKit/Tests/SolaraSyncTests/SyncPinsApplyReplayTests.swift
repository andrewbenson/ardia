import Foundation
import SolaraModel
import SolaraStore
import Testing

@Suite struct SyncPinsApplyReplayTests {
  let kinds = ["pinnedAdapter": "pins", "pinnedRowsAdapter": "rows", "pinnedOrderAdapter": "order", "groupLooksAdapter": "looks", "pinnedHomesAdapter": "homes", "tileFoldersAdapter": "tileFolders"]

  func replay(_ json: JSONObject, redesign: Bool) throws -> String? {
    guard let name = json["adapter"]?["name"]?.string, let kind = kinds[name.components(separatedBy: ":").last ?? name], json["call"] == "apply", json["lossy"] == nil else { return nil }
    let now = json["now"]?.number ?? 0
    var config = StoreConfig()
    config.syncOrigins = redesign
    config.handOffPinsImmediately = json["config"]?["handOffPinsImmediately"]?.bool ?? true
    if let listeners = json["config"]?["listeners"]?.array?.compactMap(\.string) { config.listeners = listeners.compactMap(SettleListener.init(rawValue:)) }
    let store = Store(state: try BrowserState(stateJSON: json["before"]?.object ?? [:]), memory: StoreMemory(replayJSON: json["memory"]?.object ?? [:]), env: RecordedURLs(json["web"]), config: config, clock: { now })
    var base = JSONObject()
    var known: [JSONValue] = []
    for lookup in json["lookups"]?.array ?? [] {
      guard let parts = lookup.array, parts.count >= 2, let key = parts[1].string else { continue }
      if parts[0] == "base", parts.count > 2 { base[key] = parts[2] }
      if parts[0] == "recordKnown", parts.count > 2, parts[2].truthy { known.append(.string(key)) }
    }
    let payload: JSONValue = [
      "kind": .string(kind), "visible": json["visible"] ?? [], "changed": json["changed"] ?? [], "base": .object(base), "known": .array(known),
      "now": json["records"]?["now"] ?? .number(now), "horizon": json["records"]?["horizon"] ?? 0,
    ]
    let command = try Command(json: Command("syncPinsApply", [json["adapter"]?["args"]?.array?.first ?? "default", payload]).json)
    let result = try store.dispatch(command, origin: .sync, fromSync: true).result
    let expected = json["result"] ?? .null
    let wanted = expected["written"] ?? (expected.isNull ? .bool(true) : expected)
    if result != wanted { return "result swift \(result?.text() ?? "nil") vs TS \(wanted.text())" }
    if let difference = adapterDifference(.object(store.state.stateJSON), json["after"] ?? .null) { return difference }
    return name.hasPrefix("legacy") ? nil : memoryDifference(store.memory, json["memoryAfter"])
  }

  @Test(arguments: [false, true]) func pinnedGoldenAdapterAppliesUseTheCommandDecoder(_ redesign: Bool) throws {
    let cases = AdapterCases.load().filter { $0.file == "adapters__sync__pinned" && $0.json["call"] == "apply" && $0.json["lossy"] == nil }
    #expect(cases.count > 30)
    for (_, json) in cases {
      let problem = try replay(json, redesign: redesign)
      #expect(problem == nil, "\(json["test"]?.string ?? ""): \(problem ?? "")")
    }
  }

  @Test(arguments: [false, true]) func shippedPinnedFixturesReplayThroughTheNativeApply(_ redesign: Bool) throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Cases/SyncPinsApply/Legacy")
    var counts: [String: Int] = [:]
    var historicalCases = 0
    for version in ["legacy38", "legacy40"] {
      let file = folder.appending(path: "\(version).json.deflate")
      let data = try (Data(contentsOf: file) as NSData).decompressed(using: .zlib) as Data
      let cases = try JSONValue.parse(data)["cases"]?.array ?? []
      for value in cases {
        let json = value.object ?? [:]
        counts[version, default: 0] += 1
        var original = json["after"]?.object ?? [:]
        var tabs = original["tabs"]?.object ?? [:]
        let differences = json["historicalDifferences"]?.array ?? []
        if !differences.isEmpty {
          historicalCases += 1
          #expect(version == "legacy38")
        }
        for difference in differences {
          let path = difference["path"]?.string?.components(separatedBy: ".") ?? []
          #expect(path.count == 3 && path.first == "tabs" && path.last == "pinnedUrl")
          guard path.count == 3 else { continue }
          var tab = tabs[path[1]]?.object ?? [:]
          #expect(tab["pinnedUrl"] == difference["current"])
          tab["pinnedUrl"] = difference["legacy"]
          tabs[path[1]] = .object(tab)
        }
        original["tabs"] = .object(tabs)
        #expect(JSONValue.object(original) == json["legacyAfter"])
        #expect(json["legacyResult"] == json["result"])
        let problem = try replay(json, redesign: redesign)
        #expect(problem == nil, "\(version) \(json["test"]?.string ?? ""): \(problem ?? "")")
      }
    }
    #expect(counts["legacy38"] == 8)
    #expect(counts["legacy40"] == 3)
    #expect(historicalCases == 5)
  }

  @Test(arguments: [false, true]) func recordedPinAppliesMatchTypeScriptUnderBothNativeConfigurations(_ redesign: Bool) throws {
    let folder = ProcessInfo.processInfo.environment["PIN_APPLY_DIR"].map { URL(fileURLWithPath: $0) }
      ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Cases/SyncPinsApply")
    let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.lastPathComponent.hasSuffix(".json.deflate") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    #expect(!files.isEmpty)
    let expectedRegressions: Set<String> = [
      "a pin waiting for a group that never arrives stands alone once the wait is over, even on an idle Mac",
      "a page change publishes as in 0.2.38: a member navigated in a window behind another",
      "a page change publishes as in 0.2.38: a page copied to a new mirror whose source window closes",
      "a page change publishes as in 0.2.38: a third window copied from a copy another window's page matches",
      "a page change publishes as in 0.2.38: a new group's mirror navigated before its first sync",
      "a page change publishes as in 0.2.38: a member navigated and unpinned, then re-pinned into a group elsewhere",
      "a page change publishes as in 0.2.38: a tile navigated and synced, then moved into a pinned group",
      "a page change publishes as in 0.2.38: a mirror copy navigated in front",
      "known residual: two Macs with a pin loaded at different pages keep sending their pages",
      "a Mac that unpinned a group keeps it, its name, style and members, when the other Mac restyles the pinned group",
      "known conflict: a page change on a member while the other Mac unpins its group",
      "known residual: a log delivered after the 90-day hold brings a deleted pin back",
      "known residual: a Mac joining from a snapshot during a gap holds tombstones only 45 days",
      "known residual: a log that never arrives keeps its gap and the logs after it",
      "a row and tiles in a folder pinned on one Mac arrive on the other as a row and in that folder",
      "unpinning a row and a tile in a folder deletes their marks in the same batch as their pins",
      "a pin another Mac published under the app's old name arrives with today's",
      "a pinned group tab's home reaches the other Mac in the pull that brings the tab, and a new home follows",
      "a Mac on the previous version keeps the homes it can't read, and its unpin deletes the home on the others",
      "a tile moved into a pinned group on another Mac takes the home chosen there, and keeps it",
      "a pinned group set to None reaches the other Macs as None, while its pin:g: record keeps a colour older Macs know",
      "a None group's copy in a second window stays None through a rename from another Mac",
    ]
    let expectedSchedules: Set<String> = [
      "{\"startRow\":true,\"opA\":\"unpinX\",\"opB\":\"repinX\",\"schedule\":\"A then B\"}",
      "{\"startRow\":true,\"opA\":\"moveXIntoG\",\"opB\":\"unpinG\",\"schedule\":\"B's log delayed\"}",
      "{\"startRow\":true,\"opA\":\"createHMoveX\",\"opB\":\"renameX\",\"schedule\":\"A's first log 44 days late, C joins from a snapshot meanwhile\"}",
      "{\"startRow\":false,\"opA\":\"repinX\",\"opB\":\"xTile\",\"schedule\":\"both, A syncs first\"}",
      "{\"startRow\":false,\"opA\":\"styleG\",\"opB\":\"navM\",\"schedule\":\"both, with an older Mac\"}",
      "{\"startRow\":false,\"opA\":\"workRoundTrip\",\"opB\":\"workTile\",\"schedule\":\"A's first log delayed\"}",
    ]
    var checked = 0
    var failures = 0
    var seenKinds = Set<String>()
    var regressions = Set<String>()
    var schedules = Set<String>()
    var legacy = Set<String>()
    for (index, file) in files.enumerated() {
      let data = try (Data(contentsOf: file) as NSData).decompressed(using: .zlib) as Data
      let document = try JSONValue.parse(data)
      var last: JSONObject? = nil
      for raw in document["cases"]?.array ?? [] {
        var json = raw.object ?? [:]
        if let delta = json["beforeDelta"]?.object, let last { json["before"] = .object(AdapterCases.applyDelta(delta, to: last)) }
        if let delta = json["afterDelta"]?.object, let before = json["before"]?.object { json["after"] = .object(AdapterCases.applyDelta(delta, to: before)) }
        last = json["after"]?.object
        guard json["lossy"] == nil, json["call"] == "apply", kinds[(json["adapter"]?["name"]?.string ?? "").components(separatedBy: ":").last ?? ""] != nil else { continue }
        let name = json["adapter"]?["name"]?.string ?? ""
        if let kind = kinds[name.components(separatedBy: ":").last ?? ""] { seenKinds.insert(kind) }
        let test = json["test"]?.string ?? ""
        if expectedRegressions.contains(test) { regressions.insert(test) }
        if let label = test.components(separatedBy: " | ").last, expectedSchedules.contains(label) { schedules.insert(label) }
        if file.path.contains("/Legacy/") { legacy.insert(file.deletingPathExtension().deletingPathExtension().lastPathComponent) }
        checked += 1
        if let problem = try replay(json, redesign: redesign) {
          failures += 1
          if failures <= 8 { Issue.record("\(file.lastPathComponent) \(json["test"]?.string ?? ""): \(problem)") }
        }
      }
      if index % 25 == 0 { FileHandle.standardError.write(Data("syncPinsApply redesign=\(redesign): chunk \(index + 1)/\(files.count), \(checked) calls checked\n".utf8)) }
    }
    print("syncPinsApply replay redesign=\(redesign): \(checked) calls, \(failures) failures")
    #expect(seenKinds == Set(kinds.values))
    #expect(regressions == expectedRegressions)
    #expect(schedules == expectedSchedules)
    #expect(legacy == ["legacy38", "legacy40"])
    if ProcessInfo.processInfo.environment["PIN_APPLY_DIR"] == nil { #expect(checked == 177) }
    #expect(failures == 0)
  }
}
