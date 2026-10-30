import Foundation
import CoreFoundation

enum DocumentStore {
  static var safeMode = false
}

enum ShellModule {
  static var root = FileManager.default.temporaryDirectory.appendingPathComponent("scripts-fixture")
  static func documentURL(_ name: String) throws -> URL { root.appendingPathComponent(name) }
}

extension Bundle {
  var productName: String { "Solara" }
}

__PRODUCTION__

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
var results: [[String: Any]] = []
for safe in [true, false] {
  DocumentStore.safeMode = safe
  ShellModule.root = root.appendingPathComponent(safe ? "safe" : "normal")
  try FileManager.default.createDirectory(at: ShellModule.root, withIntermediateDirectories: true)
  let folder = ShellModule.root.appendingPathComponent("Scripts")
  UserScripts.shared.start()
  UserScripts.work.sync {}
  let read = UserScripts.shared.read()
  let createdByReadOrWatch = FileManager.default.fileExists(atPath: folder.path)
  UserScripts.shared.stop()
  UserScripts.work.sync {}
  var refusal = ""
  do { try UserScripts.shared.writeStatus("new") }
  catch { refusal = error.localizedDescription }
  let createdByStatus = FileManager.default.fileExists(atPath: folder.appendingPathComponent("status.json").path)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let status = folder.appendingPathComponent("status.json")
  try Data("original".utf8).write(to: status)
  do { try UserScripts.shared.writeStatus("replacement") }
  catch { refusal = error.localizedDescription }
  results.append(["safe": safe, "createdByReadOrWatch": createdByReadOrWatch, "createdByStatus": createdByStatus,
    "status": try String(contentsOf: status, encoding: .utf8), "refusal": refusal, "read": read])
}
print(String(decoding: try JSONSerialization.data(withJSONObject: results), as: UTF8.self))
