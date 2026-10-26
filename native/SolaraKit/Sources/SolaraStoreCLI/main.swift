import Foundation
import SolaraModel
import SolaraPersistence
import SolaraStore

let usage = """
  usage: solara-store session-oracle <data folder> --now <ms> --launch <id launch> [--counter <n>] [--nav-seq <n>] [--launch-backdrop <json>]
         solara-store import-settings <data folder>

  session-oracle loads <data folder>/session.json and downloads.json through the Swift importer (loadSession and
  hydrate) and prints what the shadow export would write, as canonical JSON, in the same shape as
  apps/browser/scripts/native/session-oracle.mjs. The folder is only read.

  """

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
  guard let at = arguments.firstIndex(of: name), at + 1 < arguments.count else { return nil }
  let value = arguments[at + 1]
  arguments.removeSubrange(at...(at + 1))
  return value
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
  guard let dir = arguments.first else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
  }
  let folder = URL(fileURLWithPath: dir)
  func read(_ name: String) -> JSONValue? {
    guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
    return try? JSONValue.parse(data)
  }
  var memory = StoreMemory(ids: IdSource(launch: launch, counter: counter))
  memory.navSeq = navSeq
  var base = BrowserState()
  base.caches.launchBackdrop = backdrop
  let session = Session(state: base, memory: memory, env: PlainWebAddressing(), config: StoreConfig(), now: now)
  var state = session.loadSession(read("session.json"), downloads: read("downloads.json"))
  state.caches.launchBackdrop = backdrop
  let document = session.sessionDocument(state)
  let output: JSONValue = [
    "memory": ["launch": .string(launch), "counter": JSONValue(counter), "navSeq": JSONValue(navSeq), "now": .number(now)],
    "launchBackdrop": backdrop,
    "session": document.json(),
    "downloads": ["version": 2, "downloads": .array(state.downloads.filter { !$0.isPrivate }.map { .object($0.persisted().json) })],
  ]
  print(output.canonical)
case "import-settings":
  guard let dir = arguments.first else { exit(2) }
  let result = Importer.read(DataFolder(url: URL(fileURLWithPath: dir)), carrying: nil)
  let state = Launcher.hydrated(result.persisted)
  print(JSONValue.object(["settings": state.settings.json]).canonical)
default:
  FileHandle.standardError.write(Data("unknown command \(verb)\n\(usage)".utf8))
  exit(2)
}
