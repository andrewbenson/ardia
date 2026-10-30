import Foundation

enum NSApplication {
  static let willTerminateNotification = Notification.Name("fixture.quit")
}

extension Bundle {
  var productName: String { "Fixture" }
}

enum ShellModule {
  static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("documents")
  static func documentURL(_ name: String) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent((name as NSString).lastPathComponent)
  }
}

__PRODUCTION__

var results: [[String: Any]] = []
for safe in [true, false] {
  DocumentStore.safeMode = safe
  for name in ["live.json", "session.json", "bookmarks-cache.json", "bangs.txt", "onboarding.json", "release-notes.json", "ardia-cli.json", "sync-state-local.nns"] {
    let before = "existing \(name)"
    let after = "changed \(name)"
    let url = try ShellModule.documentURL(name)
    try before.write(to: url, atomically: true, encoding: .utf8)
    var callbacks = 0
    var failure = ""
    var threw = false
    do {
      try DocumentStore.write(name, after) { error in
        callbacks += 1
        failure = error?.localizedDescription ?? ""
      }
    } catch {
      threw = true
      failure = error.localizedDescription
    }
    let flushed = DocumentStore.flush()
    let saved = try String(contentsOf: url, encoding: .utf8)
    DocumentStore.safeMode = false
    let nextLaunch = DocumentStore.read(name) ?? ""
    DocumentStore.safeMode = safe
    var removalRefused = false
    do { try DocumentStore.remove(name) } catch { removalRefused = true }
    _ = DocumentStore.flush()
    results.append(["safe": safe, "name": name, "callbacks": callbacks, "failure": failure, "threw": threw,
      "flushed": flushed, "saved": saved, "nextLaunch": nextLaunch, "removalRefused": removalRefused,
      "existsAfterRemoval": FileManager.default.fileExists(atPath: url.path)])
  }
}
let data = try JSONSerialization.data(withJSONObject: results)
print(String(data: data, encoding: .utf8)!)
