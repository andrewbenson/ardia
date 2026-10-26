import Foundation
import SolaraModel
import SolaraStore
import Testing

struct ReplayCase: Sendable, CustomTestStringConvertible {
  let file: String
  let index: Int
  let json: JSONValue
  var testDescription: String { "\(file) #\(index): \(json["test"]?.string ?? "") \(json["command"]?["name"]?.string ?? "")" }
}

enum ReplayCases {
  static func load(phase: String) -> [ReplayCase] {
    guard let folder = Bundle.module.url(forResource: "Cases", withExtension: nil),
      let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    else { return [] }
    return files.filter { $0.lastPathComponent.hasPrefix("\(phase)__") && $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .flatMap { url -> [ReplayCase] in
        guard let document = try? JSONValue.parse(Data(contentsOf: url)), let cases = document["cases"]?.array else { return [] }
        return cases.enumerated().map { ReplayCase(file: url.deletingPathExtension().lastPathComponent, index: $0.offset, json: $0.element) }
      }
  }
}

func phase1aState(_ json: JSONValue?) -> BrowserState {
  BrowserState(
    settings: Settings(values: json?["settings"]?.object ?? Settings.defaults.values),
    downloads: (json?["downloads"]?.array ?? []).compactMap { $0.object.map(Download.init) })
}

func phase1aProjection(_ state: BrowserState) -> JSONValue {
  ["settings": state.settings.json, "downloads": .array(state.downloads.map { .object($0.json) })]
}

@Suite struct Phase1aReplay {
  static let cases = ReplayCases.load(phase: "1a")

  @Test func casesWereRecorded() {
    #expect(Self.cases.count > 100)
  }

  @Test(arguments: cases) func replays(_ replay: ReplayCase) throws {
    let json = replay.json
    if json["lossy"] != nil { return }
    let command = json["command"]!
    let expected = json["after"]!
    if command["name"] == "hydrate" {
      let profileOrder = json["profileOrder"]?.array?.compactMap(\.string) ?? []
      let settings = Settings.hydrated(from: command["args"]?.array?.first?["settings"]).repairingDefaultProfile(profileOrder: profileOrder)
      #expect(settings.json.canonical == expected["settings"]!.canonical)
      return
    }
    var memory = StoreMemory()
    memory.endedPrivateDownloads = Set(json["memory"]?["endedPrivateDownloads"]?.array?.compactMap(\.string) ?? [])
    let ids = IdSource(launch: json["ids"]?["launch"]?.string ?? "x", counter: json["ids"]?["counter"]?.int ?? 0)
    let now = json["now"]?.number ?? 0
    let store = Store(state: phase1aState(json["before"]), memory: memory, ids: ids, checksInvariants: true, clock: { now })
    try store.dispatch(Command(json: command), origin: .bridge)
    #expect(phase1aProjection(store.state).canonical == expected.canonical)
  }
}
