import CryptoKit
import Foundation
import Testing

@testable import SolaraOmnibox

@Suite struct OmniboxBench {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_BENCH"] != nil))
  func keystrokeCost() throws {
    let path = ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_BENCH"]!
    let roundsText = ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_BENCH_ROUNDS"] ?? "300"
    let rounds = try #require(Int(roundsText), "SOLARA_OMNIBOX_BENCH_ROUNDS must be a positive integer")
    try #require(rounds > 0, "SOLARA_OMNIBOX_BENCH_ROUNDS must be a positive integer")
    let seedBytes = try Data(contentsOf: URL(fileURLWithPath: path))
    let seed = try ParsedJSON(parsing: seedBytes)
    let now = try #require(seed["now"]?.double)
    try #require(now.isFinite, "seed needs a finite fixed now")
    for key in ["history", "tabs", "bookmarks", "actions", "hosts"] {
      try #require(seed[key]?.array != nil, "seed needs \(key)")
    }
    let history = seed["history"]!.items.map { HistoryRow(url: $0["url"]!.str, title: $0["title"]!.str, favicon: $0["favicon"]!.optionalString, visits: $0["visits"]!.double, lastVisit: $0["lastVisit"]!.double) }
    let tabs = seed["tabs"]!.items.map { TabRow(id: $0["id"]!.str, url: $0["url"]!.str, title: $0["title"]!.str, favicon: $0["favicon"]!.optionalString) }
    let bookmarks = seed["bookmarks"]!.items.map { BookmarkRow(url: $0["url"]!.str, title: $0["title"]!.str, favicon: $0["favicon"]!.optionalString) }
    let actions = ActionIndex(seed["actions"]!.items.map { CommandAction(id: $0["id"]!.str, title: $0["title"]!.str, keywords: $0["keywords"]?.items.map(\.str), icon: $0["icon"]?.string, hint: $0["hint"]?.string) })
    let hosts = seed["hosts"]!.items.map(\.str)
    let sources = ScopeSources(engines: builtInEngines, hosts: hosts)
    let clock = ContinuousClock()
    let micros = { (d: Duration) in Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12 }
    let integer = { (value: Double) in String(format: "%.0f", value) }
    let quoted = { (value: String) in String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }
    func summary(_ label: String, _ samples: [Double]) {
      let sorted = samples.sorted()
      let mean = sorted.reduce(0, +) / Double(sorted.count)
      let median = sorted[sorted.count / 2]
      let p95 = sorted[min(sorted.count - 1, Int(0.95 * Double(sorted.count)))]
      print("\(label): n \(sorted.count), mean \(integer(mean)) µs, median \(integer(median)) µs, p95 \(integer(p95)) µs per key")
    }

    var start = clock.now
    let index = SuggestionIndex(history: history, bookmarks: bookmarks)
    index.prepare()
    let prepare = micros(clock.now - start) / 1000
    print("swift: prepare (cold) \(String(format: "%.1f", prepare)) ms; \(history.count) history, \(bookmarks.count) bookmarks, \(tabs.count) tabs, \(hosts.count) hosts")
    print("seed sha256 \(SHA256.hash(data: seedBytes).map { String(format: "%02x", $0) }.joined()); rounds \(rounds); warmups 5")
    let options = SuggestOptions(now: now, actions: actions)
    func keystroke(_ q: String) -> SuggestionResult {
      _ = findScope(q, sources)
      return index.suggest(q, tabs: tabs, options: options)
    }
    let targets = ["github.com/net", "react native perf"]
    var m = Mismatches()
    for q in targets {
      for i in 1...q.count {
        let prefix = String(q.prefix(i))
        let want = try #require(seed["expect"]?[prefix], "seed is missing Node answer for \(prefix)")
        m.check("bench \(prefix)", json(buildSuggestions(prefix, SuggestionSource(tabs: tabs, history: history, bookmarks: bookmarks), options)), want)
        m.check("bench index \(prefix)", json(keystroke(prefix)), want)
      }
    }
    try #require(m.compared > 0 && m.total == 0, "\(m.report)")
    var overall: [Double] = []
    for q in targets {
      let prefixes = (1...q.count).map { String(q.prefix($0)) }
      for _ in 0..<5 { for p in prefixes { _ = keystroke(p) } }
      var samples: [Double] = []
      var perKey = Array(repeating: [Double](), count: prefixes.count)
      for _ in 0..<rounds {
        for (i, p) in prefixes.enumerated() {
          start = clock.now
          _ = keystroke(p)
          let elapsed = micros(clock.now - start)
          samples.append(elapsed)
          perKey[i].append(elapsed)
        }
      }
      overall.append(contentsOf: samples)
      summary(quoted(q), samples)
      for (i, values) in perKey.enumerated() { summary("  \(quoted(prefixes[i]))", values) }
    }
    summary("overall", overall)
  }
}
