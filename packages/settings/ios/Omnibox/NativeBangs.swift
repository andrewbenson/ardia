import SolaraShell
import Foundation
import SolaraOmnibox

@MainActor
enum NativeBangs {
  static let shared = BangStore(
    readDocument: { DocumentStore.read($0) },
    writeDocument: { try DocumentStore.write($0, $1) },
    saveDocument: { name, contents in
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        do {
          try DocumentStore.write(name, contents) { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    })
}
