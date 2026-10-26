import Foundation
import SolaraModel
import SolaraPersistence
import SolaraStore

let usage = """
  usage: solara-store session-oracle <data folder> --now <ms> --launch <id launch> [--counter <n>] [--nav-seq <n>] [--launch-backdrop <json>] [--via-db]
         solara-store import <data folder> [--now <ms>]
         solara-store launch <data folder> [--scope 1a|1b]

  session-oracle loads <data folder>/session.json and downloads.json through the Swift importer (Importer.read:
  loadSession and hydrate) and prints what the shadow export would write, as canonical JSON plus the documents'
  own text, in the same shape as apps/browser/scripts/native/session-oracle.mjs. --via-db also writes the import
  into a scratch solara.sqlite and loads it back before printing. import reads a data folder the way the first native launch does and
  prints the counts and notes it would record. Both only read the folder. launch runs the app's launcher on the
  folder (it writes solara.sqlite and the .pre-native copies there, so give it a scratch copy) and prints the
  source, the recorded counts, the loaded state's counts and the notes.

  """

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
  guard let at = arguments.firstIndex(of: name), at + 1 < arguments.count else { return nil }
  let value = arguments[at + 1]
  arguments.removeSubrange(at...(at + 1))
  return value
}

@MainActor func flag(_ name: String) -> Bool {
  guard let at = arguments.firstIndex(of: name) else { return false }
  arguments.remove(at: at)
  return true
}

func roundTripThroughDatabase(_ result: ImportResult, memory: StoreMemory, now: Double) throws -> BrowserState {
  let scratch = FileManager.default.temporaryDirectory.appending(path: "solara-oracle-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: scratch) }
  let url = scratch.appending(path: "solara.sqlite")
  try SolaraDatabase.create(at: url, writing: result.persisted, meta: result.meta)
  let database = try SolaraDatabase(url: url)
  defer { try? database.close() }
  let persisted = try database.load()
  let loader = Session(state: BrowserState(), memory: memory, env: PlainWebAddressing(), config: StoreConfig(), now: now)
  return loader.loadSession(persisted.sessionJSON(), downloads: persisted.downloadsJSON)
}

guard let verb = arguments.first else {
  FileHandle.standardError.write(Data(usage.utf8))
  exit(2)
}
arguments.removeFirst()

switch verb {
case "session-oracle":
  let now = Double(option("--now") ?? "0") ?? 0
  let launch = option("--launch") ?? "x"
  let counter = Int(option("--counter") ?? "0") ?? 0
  let navSeq = Int(option("--nav-seq") ?? "0") ?? 0
  let backdrop = option("--launch-backdrop").flatMap { try? JSONValue.parse($0) } ?? .null
  let viaDatabase = flag("--via-db")
  guard let dir = arguments.first else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
  }
  let folder = DataFolder(url: URL(fileURLWithPath: dir))
  var memory = StoreMemory(ids: IdSource(launch: launch, counter: counter))
  memory.navSeq = navSeq
  let result = Importer.read(folder, carrying: nil, context: LoadContext(memory: memory, now: now))
  var state = result.state
  if viaDatabase {
    do {
      state = try roundTripThroughDatabase(result, memory: result.memory, now: now)
    } catch {
      FileHandle.standardError.write(Data("the database round trip failed: \(error)\n".utf8))
      exit(1)
    }
  }
  state.caches.launchBackdrop = backdrop
  let loader = Session(state: state, memory: result.memory, env: PlainWebAddressing(), config: StoreConfig(), now: now)
  let document = loader.sessionDocument(state)
  let downloads = ShadowExport.downloadsDocument(state)
  let output: JSONValue = [
    "memory": ["launch": .string(launch), "counter": JSONValue(counter), "navSeq": JSONValue(navSeq), "now": .number(now)],
    "memoryAfter": ["counter": JSONValue(result.memory.ids.counter), "navSeq": JSONValue(result.memory.navSeq)],
    "launchBackdrop": backdrop,
    "launchBackdropText": .string(backdrop.text()),
    "session": document.json(),
    "sessionText": .string(document.json().text()),
    "downloads": downloads,
    "downloadsText": .string(downloads.text()),
  ]
  print(output.canonical)
case "launch":
  guard let dir = arguments.first else { exit(2) }
  let scope: PersistenceScope = option("--scope") == "1a" ? .settingsAndDownloads : .everything
  let folder = DataFolder(url: URL(fileURLWithPath: dir))
  do {
    let launch = try Launcher.open(folder, appVersion: "cli", context: LoadContext(memory: StoreMemory(ids: IdSource(launch: "cli")), now: Date().timeIntervalSince1970 * 1000), scope: scope)
    var meta = JSONObject()
    for key in ["workspace", "source_session_sha256"] + ["profiles", "windows", "tabs", "groups", "splits", "closedTabs", "closedWindows", "closedGroups", "deletedGroups", "cleanedTabs", "parkedPins"].flatMap({ ["count_\($0)_before", "count_\($0)_after"] }) + ["count_settings", "count_downloads"] {
      if let value = try launch.database.meta(key) { meta[key] = .string(value) }
    }
    let source: String
    switch launch.report.source {
    case .database: source = "database"
    case .imported(let reason): source = "imported: \(reason)"
    }
    let state: JSONValue = ["windows": JSONValue(launch.state.windows.count), "tabs": JSONValue(launch.state.tabs.count), "groups": JSONValue(launch.state.groups.count), "profiles": JSONValue(launch.state.profiles.count)]
    print(JSONValue.object(["source": .string(source), "meta": .object(meta), "state": state, "notes": JSONValue(launch.report.notes), "movedAside": JSONValue(launch.report.movedAside)]).text())
    try launch.database.close()
  } catch {
    print(JSONValue.object(["error": .string("\(error)")]).text())
    exit(1)
  }
case "import":
  guard let dir = arguments.first else { exit(2) }
  let now = Double(option("--now") ?? "0") ?? 0
  let result = Importer.read(
    DataFolder(url: URL(fileURLWithPath: dir)), carrying: nil, context: LoadContext(memory: StoreMemory(ids: IdSource(launch: "cli")), now: now))
  print(JSONValue.object(["meta": .object(JSONObject(result.meta.sorted { $0.key < $1.key }.map { ($0.key, JSONValue.string($0.value)) })), "notes": JSONValue(result.notes)]).text())
default:
  FileHandle.standardError.write(Data("unknown command \(verb)\n\(usage)".utf8))
  exit(2)
}
