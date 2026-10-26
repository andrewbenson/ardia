import Foundation
import SolaraModel
import SolaraStore
import Testing

@Suite(.serialized) struct DispatchCost {
  @Test(arguments: ["all", "none", "noMirror", "onlyMirror"]) func dispatchOnTheTwoHundredTabSeed(_ variant: String) throws {
    let seed = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/sessions/perf-seed/session.json")
    let session = Session(state: BrowserState(), memory: StoreMemory(ids: IdSource(launch: "perf")), env: PlainWebAddressing(), config: StoreConfig(), now: 1)
    let state = session.loadSession(try JSONValue.parse(Data(contentsOf: seed)), downloads: nil)
    var config = StoreConfig()
    switch variant {
    case "none": config.listeners = []
    case "noMirror": config.listeners = config.listeners.filter { $0 != .mirror }
    case "onlyMirror": config.listeners = [.mirror]
    default: break
    }
    let store = Store(state: state, memory: session.memory, config: config, checksInvariants: false)
    let window = state.windowOrder[0]
    let tabs = state.windows[window]!.tabIds
    var samples: [Double] = []
    let rounds = variant == "all" ? Int(ProcessInfo.processInfo.environment["PERF_ROUNDS"] ?? "400") ?? 400 : 400
    for i in 0..<rounds {
      let command: Command
      switch i % 4 {
      case 0: command = Command("activate", [.string(tabs[(i * 7) % tabs.count])])
      case 1: command = Command("updateTab", [.string(tabs[(i * 3) % tabs.count]), ["title": .string("t\(i)")]])
      case 2: command = Command("newTab", [.string(window), ["url": .string("https://x.example/\(i)"), "background": true]])
      default: command = Command("closeTab", [.string(store.state.windows[window]!.tabIds.last!)])
      }
      let start = DispatchTime.now().uptimeNanoseconds
      try store.dispatch(command)
      samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    samples.sort()
    let p50 = samples[samples.count / 2]
    let p99 = samples[samples.count * 99 / 100]
    print("dispatch [\(variant)] on \(tabs.count) tabs: p50 \(p50) ms, p99 \(p99) ms, max \(samples.last!) ms")
  }
}
