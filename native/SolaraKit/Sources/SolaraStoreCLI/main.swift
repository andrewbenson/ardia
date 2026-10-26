import Foundation
import SolaraBridgeCore
import SolaraModel
import SolaraPersistence
import SolaraStore

let usage = """
  usage: solara-store session-oracle <data folder> --now <ms> --launch <id launch> [--counter <n>] [--nav-seq <n>] [--launch-backdrop <json>] [--via-db]
         solara-store import <data folder> [--now <ms>]
         solara-store launch <data folder> [--scope 1a|1b]
         solara-store serve [--launch <id launch>] [--hand-off immediately] [--data <data folder> --now <ms>]

  session-oracle loads <data folder>/session.json and downloads.json through the Swift importer (Importer.read:
  loadSession and hydrate) and prints what the shadow export would write, as canonical JSON plus the documents'
  own text, in the same shape as apps/browser/scripts/native/session-oracle.mjs. --via-db also writes the import
  into a scratch solara.sqlite and loads it back before printing. import reads a data folder the way the first native launch does and
  prints the counts and notes it would record. Both only read the folder. launch runs the app's launcher on the
  folder (it writes solara.sqlite and the .pre-native copies there, so give it a scratch copy) and prints the
  source, the recorded counts, the loaded state's counts and the notes. serve runs one in-memory store behind the
  bridge, one JSON request per line on stdin ({op: snapshot | dispatch | catchUp, commands, sinceRev, now}) and
  one response per line on stdout, so the JS replica can be tested against the real Swift store. With --data it
  opens that folder through the app's launcher and writer in the everything scope, and {op: flush} writes the rows
  and the shadow files.

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
case "serve":
  final class Clock: @unchecked Sendable { var now: Double = 0 }
  let clock = Clock()
  var config = StoreConfig()
  config.handOffPinsImmediately = option("--hand-off") == "immediately"
  let launchId = option("--launch") ?? "serve"
  clock.now = Double(option("--now") ?? "0") ?? 0
  let store: Store
  var writer: PersistenceWriter? = nil
  if let dir = option("--data") {
    let folder = DataFolder(url: URL(fileURLWithPath: dir))
    let context = LoadContext(env: OmniboxAddressing(), config: config, memory: StoreMemory(ids: IdSource(launch: launchId)), now: clock.now)
    do {
      let launch = try Launcher.open(folder, appVersion: "serve", now: Date(timeIntervalSince1970: clock.now / 1000), context: context, scope: .everything)
      store = Store(state: launch.state, memory: launch.memory, env: OmniboxAddressing(), config: config, checksInvariants: false, clock: { clock.now })
      writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, scope: .everything, clock: { clock.now })
    } catch {
      print(JSONValue.object(["error": .string("\(error)")]).text())
      exit(1)
    }
  } else {
    store = Store(memory: StoreMemory(ids: IdSource(launch: launchId)), env: OmniboxAddressing(), config: config, checksInvariants: false, clock: { clock.now })
  }
  let bridge = StoreBridge(store: store)
  setvbuf(stdout, nil, _IOFBF, 1 << 20)
  while let line = readLine(strippingNewline: true) {
    guard let request = try? JSONValue.parse(line) else {
      print(#"{"error":"bad request"}"#)
      fflush(stdout)
      continue
    }
    clock.now = request["now"]?.number ?? clock.now
    let sinceRev = request["sinceRev"]?.int ?? 0
    switch request["op"]?.string {
    case "snapshot": print(bridge.snapshotJSON())
    case "dispatch": print(bridge.dispatch(request["commands"]?.text() ?? "[]", sinceRev: sinceRev))
    case "catchUp": print(JSONValue.object(bridge.catchUp(sinceRev: sinceRev)).text())
    case "flush": print(JSONValue.object(["flushed": .bool(writer?.flush(timeout: 10) ?? false)]).text())
    default: print(#"{"error":"unknown op"}"#)
    }
    fflush(stdout)
  }
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
