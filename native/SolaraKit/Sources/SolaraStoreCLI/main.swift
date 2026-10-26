import Foundation
import SolaraModel
import SolaraPersistence
import SolaraStore

let arguments = CommandLine.arguments.dropFirst()
guard let verb = arguments.first else {
  FileHandle.standardError.write(Data("usage: solara-store import-settings <data-dir>\n".utf8))
  exit(2)
}
switch verb {
case "import-settings":
  guard let dir = arguments.dropFirst().first else { exit(2) }
  let result = Importer.read(DataFolder(url: URL(fileURLWithPath: dir)), carrying: nil)
  let state = Launcher.hydrated(result.persisted)
  print(JSONValue.object(["settings": state.settings.json]).canonical)
default:
  FileHandle.standardError.write(Data("unknown command \(verb)\n".utf8))
  exit(2)
}
