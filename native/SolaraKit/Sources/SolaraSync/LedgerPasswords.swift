import Foundation
import SolaraModel

public enum DocumentRead: Sendable, Equatable {
  case contents(String)
  case missing
  case failure(String)
}

public protocol LedgerPasswordsHost: AnyObject, Sendable {
  func engineProfile(_ profileId: String) -> String
  func readMarked(_ engineProfile: String) async throws -> JSONValue?
  func checkSealed(_ values: [LedgerValue]) async throws -> [JSONValue]
  func saveSealed(_ engineProfile: String, _ origin: String, _ username: String, _ sealed: String, _ replacing: Bool) async throws -> Bool
  func deletePassword(_ engineProfile: String, _ origin: String, _ username: String) async throws -> Bool
  func writeMark(_ engineProfile: String, _ value: String) async throws
  func readLedgerDocument() -> DocumentRead
  func writeLedgerDocument(_ contents: String)
  func sleep(_ ms: Double) async
}

public struct LedgerPasswordsMemory: Sendable, Equatable {
  public var lastRead: Double
  public var quietUntil: Double
  public var unconfirmed: OrderedSet<JSKey>
  public var claimed: OrderedSet<JSKey>
  public var held: OrderedSet<JSKey>
  public var heldDigests: OrderedDict<JSKey, String>
  public var confirmed: OrderedSet<JSKey>
  public var restoring: OrderedDict<JSKey, String>
  public var judgedForFolder: OrderedSet<JSKey>

  public init(
    lastRead: Double = 0, quietUntil: Double = 0, unconfirmed: OrderedSet<JSKey> = OrderedSet(), claimed: OrderedSet<JSKey> = OrderedSet(),
    held: OrderedSet<JSKey> = OrderedSet(), heldDigests: OrderedDict<JSKey, String> = OrderedDict(), confirmed: OrderedSet<JSKey> = OrderedSet(),
    restoring: OrderedDict<JSKey, String> = OrderedDict(), judgedForFolder: OrderedSet<JSKey> = OrderedSet()
  ) {
    self.lastRead = lastRead
    self.quietUntil = quietUntil
    self.unconfirmed = unconfirmed
    self.claimed = claimed
    self.held = held
    self.heldDigests = heldDigests
    self.confirmed = confirmed
    self.restoring = restoring
    self.judgedForFolder = judgedForFolder
  }
}
