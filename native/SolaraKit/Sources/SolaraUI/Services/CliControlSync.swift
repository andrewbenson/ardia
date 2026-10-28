import Foundation

public struct CliControlServer: Sendable, Equatable {
  public var state: String
  public var port: Int?
  public var connections: Int?
  public var generation: Int?
  public var reason: String?

  public init(state: String, port: Int? = nil, connections: Int? = nil, generation: Int? = nil, reason: String? = nil) {
    self.state = state
    self.port = port
    self.connections = connections
    self.generation = generation
    self.reason = reason
  }

  public init(_ dict: [String: Any]) {
    state = dict["state"] as? String ?? "off"
    port = (dict["port"] as? NSNumber)?.intValue
    connections = (dict["connections"] as? NSNumber)?.intValue
    generation = (dict["generation"] as? NSNumber)?.intValue
    reason = (dict["reason"] as? String) ?? (dict["error"] as? String)
  }
}

public enum CliControlRequest: Equatable, Sendable {
  case status
  case set(Bool)
}

public struct CliControlCall: Equatable, Sendable {
  public let request: Int
  public let call: CliControlRequest
}

public struct CliControlSync: Sendable {
  public private(set) var server: CliControlServer?
  private var latest = 0
  private var inFlight = 0
  private var newest = 0
  private var applied: Bool?

  public init() {}

  public mutating func settingChanged(_ on: Bool) -> CliControlCall? {
    guard on != applied else { return nil }
    let first = applied == nil
    applied = on
    latest += 1
    inFlight += 1
    return CliControlCall(request: latest, call: first && !on ? .status : .set(on))
  }

  public mutating func settled(_ request: Int, _ server: CliControlServer, settingOn: Bool) -> Bool {
    inFlight -= 1
    guard request == latest else { return false }
    return apply(server, mayReconcile: true, settingOn: settingOn)
  }

  public mutating func event(_ server: CliControlServer, settingOn: Bool) -> Bool {
    apply(server, mayReconcile: inFlight == 0, settingOn: settingOn)
  }

  private mutating func apply(_ server: CliControlServer, mayReconcile: Bool, settingOn: Bool) -> Bool {
    if (server.generation ?? newest) < newest { return false }
    newest = max(newest, server.generation ?? 0)
    self.server = server
    let stoppedItself = server.state == "off" && !(server.reason ?? "").isEmpty
    return mayReconcile && stoppedItself && settingOn
  }
}
