import Foundation

enum ArdiaCoreHost { static var safeMode = false }
enum DocumentStore { static var safeMode: Bool { ArdiaCoreHost.safeMode } }
final class FileManager {
  static let `default` = FileManager()
  var outcome = "success"
  var trashed: [String] = []
  func fileExists(atPath path: String) -> Bool { outcome != "missing" }
  func trashItem(at url: URL, resultingItemURL: Any?) throws {
    trashed.append(url.path)
    if outcome == "failure" { throw NSError(domain: "fixture", code: 1) }
  }
}
struct Registration {}
var moveToTrash: ((String) -> Bool)?
func AsyncFunction(_ name: String, _ body: @escaping (String) -> Bool) -> Registration {
  precondition(name == "moveToTrash")
  moveToTrash = body
  return Registration()
}

__PRODUCTION__

var results: [[String: Any]] = []
for safe in [true, false] {
  ArdiaCoreHost.safeMode = safe
  for outcome in ["success", "missing", "failure"] {
    FileManager.default.outcome = outcome
    FileManager.default.trashed = []
    let result = moveToTrash!("/fixture/download.txt")
    results.append(["safe": safe, "outcome": outcome, "result": result, "trashed": FileManager.default.trashed])
  }
}
let data = try JSONSerialization.data(withJSONObject: results)
print(String(data: data, encoding: .utf8)!)
