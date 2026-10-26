import Foundation
import SolaraModel
import SolaraStore
import Synchronization
import Testing

struct ReplayCase: Sendable, CustomTestStringConvertible {
  let file: String
  let index: Int
  let json: JSONValue
  var testDescription: String { "\(file) #\(index): \(json["test"]?.string ?? "") \(json["command"]?["name"]?.string ?? "")" }
}

enum ReplayCases {
  static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Cases")

  static func load(phase: String, only: String? = ProcessInfo.processInfo.environment["REPLAY_ONLY"]) -> [ReplayCase] {
    guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
    return files.filter { $0.lastPathComponent.hasPrefix("\(phase)__") && ($0.pathExtension == "json" || $0.lastPathComponent.hasSuffix(".json.deflate")) }
      .filter { only == nil || $0.lastPathComponent.contains(only!) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .flatMap { url -> [ReplayCase] in
        guard var data = try? Data(contentsOf: url) else { return [] }
        if url.pathExtension == "deflate" {
          guard let inflated = try? (data as NSData).decompressed(using: .zlib) as Data else { return [] }
          data = inflated
        }
        guard let document = try? JSONValue.parse(data), let cases = document["cases"]?.array else { return [] }
        let name = url.lastPathComponent.replacingOccurrences(of: ".json.deflate", with: "").replacingOccurrences(of: ".json", with: "")
        var last: JSONObject? = nil
        return cases.enumerated().map { index, raw in
          var json = raw.object ?? [:]
          if let delta = json["beforeDelta"]?.object, let base = last {
            json["before"] = .object(applyDelta(delta, to: base))
            json.removeValue(forKey: "beforeDelta")
          }
          if let delta = json["afterDelta"]?.object, let before = json["before"]?.object {
            let after = applyDelta(delta, to: before)
            json["after"] = .object(after)
            json.removeValue(forKey: "afterDelta")
          }
          last = json["after"]?.object
          return ReplayCase(file: name, index: index, json: .object(json))
        }
      }
  }

  static func applyDelta(_ delta: JSONObject, to base: JSONObject) -> JSONObject {
    var out = base
    for (key, change) in delta {
      if change["$absent"] != nil {
        out.removeValue(forKey: key)
      } else if let table = change["$table"]?.object {
        var current = out[key]?.object ?? [:]
        for id in table["remove"]?.array?.compactMap(\.string) ?? [] { current.removeValue(forKey: id) }
        for (id, value) in table["set"]?.object ?? [:] { current[id] = value }
        if let order = table["order"]?.array?.compactMap(\.string) {
          var reordered = JSONObject()
          for id in order { if let value = current[id] { reordered[id] = value } }
          current = reordered
        }
        out[key] = .object(current)
      } else {
        out[key] = change
      }
    }
    return out
  }
}

final class RecordedWeb: WebAddressing, @unchecked Sendable {
  let urls: [String: ParsedURL?]
  let resolves: [String: String]
  let prefix: String?
  let missed = Mutex<[String]>([])

  init(_ json: JSONValue?) {
    var urls: [String: ParsedURL?] = [:]
    for (input, parsed) in json?["urls"]?.object ?? [:] {
      urls[input] = parsed.isNull
        ? .some(nil)
        : ParsedURL(protocol: parsed["protocol"]?.string ?? "", host: parsed["host"]?.string ?? "", hostname: parsed["hostname"]?.string ?? "")
    }
    self.urls = urls
    var resolves: [String: String] = [:]
    for entry in json?["resolve"]?.array ?? [] {
      let parts = entry.array ?? []
      if parts.count == 3, let input = parts[0].string, let prefix = parts[1].string, let out = parts[2].string { resolves["\(input)\u{0}\(prefix)"] = out }
    }
    self.resolves = resolves
    prefix = json?["prefix"]?.string
  }

  func resolveInput(_ input: String, searchUrlPrefix: String) -> String {
    if let out = resolves["\(input)\u{0}\(searchUrlPrefix)"] { return out }
    missed.withLock { $0.append("resolveInput(\(input))") }
    return input
  }

  func searchUrlPrefix(_ settings: Settings) -> String { prefix ?? "https://www.google.com/search?q=%s" }

  func parseURL(_ url: String) -> ParsedURL? {
    if let known = urls[url] { return known }
    missed.withLock { $0.append("URL(\(url))") }
    return PlainWebAddressing().parseURL(url)
  }
}

func firstDifference(_ a: JSONValue, _ b: JSONValue, path: String = "") -> String? {
  switch (a, b) {
  case (.object(let x), .object(let y)):
    for key in Set(x.keys).union(y.keys).sorted() {
      guard let l = x[key] else { return "\(path).\(key): missing in swift, js has \(y[key]!.text().prefix(300))" }
      guard let r = y[key] else { return "\(path).\(key): swift has \(l.text().prefix(300)), missing in js" }
      if let d = firstDifference(l, r, path: "\(path).\(key)") { return d }
    }
    return nil
  case (.array(let x), .array(let y)):
    for i in 0..<min(x.count, y.count) { if let d = firstDifference(x[i], y[i], path: "\(path)[\(i)]") { return d } }
    return x.count == y.count ? nil : "\(path): swift has \(x.count) items, js has \(y.count)"
  default:
    return a == b ? nil : "\(path): swift \(a.text().prefix(300)) vs js \(b.text().prefix(300))"
  }
}

func replayConfig(_ json: JSONValue?) -> StoreConfig {
  var config = StoreConfig()
  config.handOffPinsImmediately = json?["handOffPinsImmediately"]?.bool ?? true
  if let names = json?["listeners"]?.array?.compactMap(\.string) { config.listeners = names.compactMap(SettleListener.init(rawValue:)) }
  return config
}

func replayOnce(_ json: JSONValue) throws -> (JSONValue, JSONValue?, [String]) {
  let web = RecordedWeb(json["web"])
  let now = json["now"]?.number ?? 0
  let store = Store(
    state: try BrowserState(stateJSON: json["before"]?.object ?? [:]), memory: StoreMemory(replayJSON: json["memory"]?.object ?? [:]), env: web,
    config: replayConfig(json["config"]), checksInvariants: true, clock: { now })
  let command = json["command"]!
  let commands = command["name"] == "$batch" ? try (command["commands"]?.array ?? []).map(Command.init(json:)) : [try Command(json: command)]
  let commit = try store.dispatch(commands, origin: .bridge)
  return (.object(store.state.stateJSON), commit.result, web.missed.withLock { $0 })
}

@Suite struct Phase1bReplay {
  static let cases = ReplayCases.load(phase: "1b")

  @Test func casesWereRecorded() {
    #expect(Self.cases.count > 100)
  }

  @Test func replaysEveryCase() throws {
    var passed: [String: Int] = [:]
    var failed: [String: Int] = [:]
    var skipped = 0
    var reports: [String] = []
    for replay in Self.cases {
      let json = replay.json
      if json["lossy"] != nil || json["foreign"] != nil || json["precheck"] != nil {
        skipped += 1
        continue
      }
      let name = json["command"]?["name"]?.string ?? "?"
      if ProcessInfo.processInfo.environment["REPLAY_TRACE"] != nil { print("case \(replay.testDescription)") }
      do {
        let (state, result, missed) = try replayOnce(json)
        var problem = firstDifference(state, json["after"]!)
        if problem == nil, let expected = json["result"], !(expected.isNull && result == nil) {
          let got = result ?? .null
          if got.canonical != expected.canonical { problem = "result: swift \(got.text().prefix(300)) vs js \(expected.text().prefix(300))" }
        }
        if problem == nil, !missed.isEmpty { problem = "web lookups missed: \(missed.prefix(3))" }
        if let problem {
          failed[name, default: 0] += 1
          if reports.count < 40 { reports.append("\(replay.testDescription)\n    \(problem)") }
        } else {
          passed[name, default: 0] += 1
        }
      } catch {
        failed[name, default: 0] += 1
        if reports.count < 40 { reports.append("\(replay.testDescription)\n    threw \(error)") }
      }
    }
    let total = passed.values.reduce(0, +)
    let bad = failed.values.reduce(0, +)
    var summary = "1b replay: \(total) passed, \(bad) failed, \(skipped) skipped\n"
    for name in Set(passed.keys).union(failed.keys).sorted() {
      summary += "  \(name): \(passed[name] ?? 0) ok, \(failed[name] ?? 0) failed\n"
    }
    try? summary.appending(reports.joined(separator: "\n")).write(
      to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "solara-replay-1b.txt"), atomically: true, encoding: .utf8)
    print(summary)
    for report in reports.prefix(15) { print(report) }
    #expect(bad == 0)
  }
}
