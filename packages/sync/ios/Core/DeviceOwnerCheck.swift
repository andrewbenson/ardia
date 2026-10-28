import Foundation
import LocalAuthentication
import Security

enum DeviceOwnerUnavailable: String {
  case noLoginPassword
}

final class DeviceOwnerCheck {
  typealias Evaluate = (_ reason: String, _ done: @escaping (Bool) -> Void) -> Void

  static let validity: UInt64 = 60 * NSEC_PER_SEC
  private let evaluate: Evaluate
  private let lock = NSLock()
  private var grantedAt: UInt64?
  private var epoch = 0
  private var waiting: [(Bool) -> Void]?

  init(evaluate: @escaping Evaluate = DeviceOwnerCheck.system) {
    self.evaluate = evaluate
  }

  private static var now: UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

  func revoke() {
    lock.lock()
    grantedAt = nil
    epoch += 1
    lock.unlock()
  }

  func confirm(reason: String, then done: @escaping (Bool) -> Void) {
    lock.lock()
    if let grantedAt, Self.now - grantedAt < Self.validity {
      lock.unlock()
      return done(true)
    }
    if waiting != nil {
      waiting?.append(done)
      lock.unlock()
      return
    }
    waiting = [done]
    let asked = epoch
    lock.unlock()
    evaluate(reason) { granted in
      self.lock.lock()
      let current = granted && self.epoch == asked
      if current { self.grantedAt = Self.now }
      let everyone = self.waiting ?? []
      self.waiting = nil
      self.lock.unlock()
      everyone.forEach { $0(current) }
    }
  }

  func disclose<Secret: Equatable>(reason: String, current: @escaping () -> Secret?, then done: @escaping (Secret?) -> Void) {
    guard let asked = current() else { return done(nil) }
    confirm(reason: reason) { granted in
      done(granted && current() == asked ? asked : nil)
    }
  }

  static func unavailable() -> DeviceOwnerUnavailable? {
    let environment = ProcessInfo.processInfo.environment
    if environment["ARDIA_BACKGROUND"] == "1" {
      return testHonoured(environment) && environment["ARDIA_TEST_REAUTH"] == "noLoginPassword" ? .noLoginPassword : nil
    }
    var problem: NSError?
    guard !LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else { return nil }
    return problem?.code == LAError.passcodeNotSet.rawValue ? .noLoginPassword : nil
  }

  static func system(_ reason: String, _ done: @escaping (Bool) -> Void) {
    let environment = ProcessInfo.processInfo.environment
    if environment["ARDIA_BACKGROUND"] == "1" {
      let granted = testHonoured(environment) && environment["ARDIA_TEST_REAUTH"] == "granted"
      NSLog("[sync] device owner check (%@) in a hidden test instance, no prompt: %@", reason, granted ? "granted" : "denied")
      return done(granted)
    }
    let context = LAContext()
    var problem: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
      NSLog("[sync] device owner check unavailable: %@", problem?.localizedDescription ?? "unknown")
      return done(false)
    }
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { granted, _ in
      withExtendedLifetime(context) { done(granted) }
    }
  }

  private static func testHonoured(_ environment: [String: String]) -> Bool {
    environment["ARDIA_DATA_DIR"] != nil && !signedForDistribution
  }

  static let signedForDistribution: Bool = {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
    var requirement: SecRequirement?
    let distribution = "anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or "
      + "certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists)"
    guard SecRequirementCreateWithString(distribution as CFString, [], &requirement) == errSecSuccess, let requirement else { return true }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
  }()
}
