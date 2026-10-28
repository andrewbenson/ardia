import ArdiaCore
import Foundation

struct EngineCallError: Error, CustomStringConvertible {
  let description: String
}

enum EngineCalls {
  @MainActor
  static func result<T: Sendable>(
    _ start: (@escaping @Sendable ([String: Any]) -> Void) -> Void,
    _ map: @escaping @Sendable ([String: Any]) -> T
  ) async -> T {
    await withCheckedContinuation { continuation in
      start { continuation.resume(returning: map($0)) }
    }
  }

  @MainActor
  static func settle(_ start: (@escaping @Sendable (String?) -> Void) -> Void) async throws {
    let error: String? = await withCheckedContinuation { continuation in start { continuation.resume(returning: $0) } }
    if let error { throw EngineCallError(description: error) }
  }

  static func failed(_ result: [String: Any], _ name: String) -> Bool {
    guard let error = result["error"] else { return false }
    NSLog("[settings] %@ failed: %@", name, String(describing: error))
    return true
  }
}
