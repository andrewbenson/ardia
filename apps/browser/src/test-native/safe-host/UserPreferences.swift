import Foundation

enum SolaraCoreHost {
  static var safeMode = false
}

enum CliTool {
  static var installs = 0
  static var product = "Solara"
  static var appVersion = "1.0"
  static func installedVersion() -> String? { "0.9" }
  static func install(onLine: @escaping @Sendable (String) -> Void, done: @escaping @Sendable ([String: Any]) -> Void) {
    installs += 1
  }
}

enum DocumentStore {
  static var json: String?
  static var writes = 0
  static func read(_ name: String) -> String? { json }
  static func write(_ name: String, _ value: String) throws {
    writes += 1
    json = value
  }
}

@MainActor
final class NativeCliControl {
  static let shared = NativeCliControl()
  static let document = "solara-cli.json"
  var binPath: String?
  var error: String?
  var running: [([String: Any]) -> Void] = []
  var installing: String?
  var installedVersion: String?
  var step: String?
  __PRODUCTION__

  func runUpgrade() { upgradeIfBehind() }
  func complete() {
    if installing != nil {
      installed(["ok": true, "appVersion": "1.0", "version": "1.0", "binPath": "/fixture/bin/solara", "lines": [String]()])
    }
  }
}

var results: [[String: Any]] = []
MainActor.assumeIsolated {
  for safe in [true, false] {
    SolaraCoreHost.safeMode = safe
    for reason in ["settings", "upgrade", "startup"] {
      CliTool.installs = 0
      DocumentStore.json = nil
      DocumentStore.writes = 0
      let control = NativeCliControl()
      var reply: [String: Any] = [:]
      if reason == "startup" { control.runUpgrade() }
      else { control.install(reason: reason) { reply = $0 } }
      control.complete()
      let saved = DocumentStore.json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? [:]
      results.append(["safe": safe, "reason": reason, "installs": CliTool.installs, "reply": reply, "writes": DocumentStore.writes, "saved": saved])
    }
  }
}
let output = try JSONSerialization.data(withJSONObject: results)
print(String(decoding: output, as: UTF8.self))
