import Foundation
import Testing

@testable import SolaraOmnibox

@Suite struct OmniboxBench {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_BENCH"] != nil))
  func keystrokeCost() throws {
    let path = ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_BENCH"]!
    let rounds = Int(ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_BENCH_ROUNDS"] ?? "") ?? 300
    let seed = try ParsedJSON(parsing: Data(contentsOf: URL(fileURLWithPath: path)))
    let now = seed["now"]!.double
    let history = seed["history"]!.items.map { HistoryRow(url: $0["url"]!.str, title: $0["title"]!.str, favicon: $0["favicon"]!.optionalString, visits: $0["visits"]!.double, lastVisit: $0["lastVisit"]!.double) }
    let tabs = seed["tabs"]!.items.map { TabRow(id: $0["id"]!.str, url: $0["url"]!.str, title: $0["title"]!.str, favicon: $0["favicon"]!.optionalString) }
    let bookmarks = seed["bookmarks"]!.items.map { BookmarkRow(url: $0["url"]!.str, title: $0["title"]!.str, favicon: $0["favicon"]!.optionalString) }
    let actions = ActionIndex(seed["actions"]!.items.map { CommandAction(id: $0["id"]!.str, title: $0["title"]!.str, keywords: $0["keywords"]?.items.map(\.str), icon: $0["icon"]?.string, hint: $0["hint"]?.string) })
    let sources = ScopeSources(engines: builtInEngines, hosts: seed["hosts"]!.items.map(\.str))
    let clock = ContinuousClock()

    var start = clock.now
    let index = SuggestionIndex(history: history, bookmarks: bookmarks)
    index.prepare()
    let prepare = clock.now - start
    print("swift: prepare (cold) \(prepare); \(history.count) history, \(bookmarks.count) bookmarks, \(tabs.count) tabs")
    let options = SuggestOptions(now: now, actions: actions)
    func keystroke(_ q: String) -> SuggestionResult {
      _ = findScope(q, sources)
      return index.suggest(q, tabs: tabs, options: options)
    }
    let micros = { (d: Duration) in Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12 }
    for q in ["github.com/net", "react native perf"] {
      let prefixes = (1...q.count).map { String(q.prefix($0)) }
      for _ in 0..<5 { for p in prefixes { _ = keystroke(p) } }
      var samples: [Double] = []
      for _ in 0..<rounds {
        for p in prefixes {
          start = clock.now
          _ = keystroke(p)
          samples.append(micros(clock.now - start))
        }
      }
      samples.sort()
      let mean = samples.reduce(0, +) / Double(samples.count)
      let median = samples[samples.count / 2]
      let p95 = samples[min(samples.count - 1, Int(0.95 * Double(samples.count)))]
      print("swift \"\(q)\": mean \(Int(mean)) µs, median \(Int(median)) µs, p95 \(Int(p95)) µs per key")
    }
    var m = Mismatches()
    for case let (q, want) in seed["expect"].map({ if case .object(let pairs) = $0 { pairs } else { [] } }) ?? [] {
      m.check("bench \(q)", json(buildSuggestions(q, SuggestionSource(tabs: tabs, history: history, bookmarks: bookmarks), options)), want)
      m.check("bench index \(q)", json(keystroke(q)), want)
    }
    #expect(m.compared > 0 && m.total == 0, "\(m.report)")
  }
}
