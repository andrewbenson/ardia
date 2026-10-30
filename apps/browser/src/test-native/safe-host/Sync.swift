import Foundation

enum ArdiaCoreHost { static var safeMode = false }
struct Exception: Error { let name: String; let description: String }
final class KeyState {
  var reads = 0
  var keys: Int? { reads += 1; return 7 }
}
final class SyncVault {
  static var calls = 0
  init(folder: URL, keys: Int) {
    Self.calls += 1
    try! Data("vault opened".utf8).write(to: folder.appendingPathComponent("marker"))
  }
}
final class Probe {
  private let state = KeyState()
  __PRODUCTION__
  func run(_ folder: String) -> [String: Any] {
    var problem = ""
    do { _ = try vault(folder) } catch let error as Exception { problem = error.name } catch { problem = "unexpected" }
    return ["error": problem, "keyReads": state.reads, "vaultCalls": SyncVault.calls]
  }
}
var results: [[String: Any]] = []
let folder = ProcessInfo.processInfo.environment["TMPDIR"]!
let marker = URL(fileURLWithPath: folder).appendingPathComponent("marker")
for safe in [true, false] {
  ArdiaCoreHost.safeMode = safe
  SyncVault.calls = 0
  try Data("preserved".utf8).write(to: marker)
  var result = Probe().run(folder)
  result["safe"] = safe
  result["marker"] = String(data: try Data(contentsOf: marker), encoding: .utf8)!
  results.append(result)
}
let data = try JSONSerialization.data(withJSONObject: results)
print(String(data: data, encoding: .utf8)!)
