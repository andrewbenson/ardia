import Foundation
import SolaraModel
import SolaraStore

public struct UserScriptsTarget: Sendable, Equatable {
  public var engine: String
  public var names: [String]

  public init(engine: String, names: [String]) {
    self.engine = engine
    self.names = names
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.engine.jsEquals(rhs.engine) && lhs.names.count == rhs.names.count && zip(lhs.names, rhs.names).allSatisfy { $0.jsEquals($1) }
  }
}

public struct UserScriptsFolder: Sendable, Equatable {
  public var state: String
  public var generation: Double?
  public var path: String?
  public var error: String?
  public var token: String?

  public init(state: String, generation: Double? = nil, path: String? = nil, error: String? = nil, token: String? = nil) {
    self.state = state
    self.generation = generation
    self.path = path
    self.error = error
    self.token = token
  }

  public init(_ value: [String: Any]) {
    self.init(state: value["state"] as? String ?? "empty", generation: (value["generation"] as? NSNumber)?.doubleValue,
      path: value["path"] as? String, error: value["error"] as? String, token: value["token"] as? String)
  }
}

public struct UserScriptsExtension: Sendable, Equatable {
  public var id: String
  public var path: String?
  public var enabled: Bool
  public var state: String
  public var blockedByPolicy: Bool
  public var errors: [String]

  public init(id: String, path: String?, enabled: Bool, state: String, blockedByPolicy: Bool = false, errors: [String] = []) {
    self.id = id
    self.path = path
    self.enabled = enabled
    self.state = state
    self.blockedByPolicy = blockedByPolicy
    self.errors = errors
  }

  public init(_ value: [String: Any]) {
    self.init(id: value["id"] as? String ?? "", path: value["path"] as? String, enabled: value["enabled"] as? Bool ?? false,
      state: value["state"] as? String ?? "", blockedByPolicy: value["blockedByPolicy"] as? Bool ?? false, errors: value["errors"] as? [String] ?? [])
  }
}

@MainActor
public protocol UserScriptsHost: AnyObject {
  func watch(_ on: Bool)
  func read() async throws -> UserScriptsFolder
  func readStatus() async throws -> String?
  func writeStatus(_ json: String) async throws
  func list(_ profile: String) async throws -> [UserScriptsExtension]
  func install(_ path: String, profile: String) async throws -> String
  func reload(_ id: String, profile: String) async throws
  func uninstall(_ id: String, profile: String) async throws
  func warn(_ message: String, error: any Error)
}

@MainActor
public final class UserScriptsSync {
  private enum Wanted: Equatable { case present, absent }

  private struct Applied {
    let generation: Double
    let wanted: Wanted
    let outcome: JSONValue?
  }

  private let host: any UserScriptsHost
  private let product: String
  private var enabled = false
  private var targets: [UserScriptsTarget] = []
  private var syncedTargets: [UserScriptsTarget] = []
  private var applied = JSMap<Applied>()
  private var seeded = false
  private var lastStatus: String?
  private var running: Task<Void, Never>?
  private var again = false

  public init(host: any UserScriptsHost, product: String) {
    self.host = host
    let trimmed = product.jsTrim()
    self.product = trimmed.isEmpty ? "Solara" : trimmed
  }

  public static func targets(_ state: BrowserState) -> [UserScriptsTarget] {
    var targets: [UserScriptsTarget] = []
    var indexes = JSMap<Int>()
    var taken = JSMap<Int>()
    for id in state.profileOrder {
      guard let profile = state.profiles[id], !Ids.isIncognitoProfile(id) else { continue }
      let trimmed = profile.name.jsTrim()
      let base = trimmed.isEmpty ? id : trimmed
      let seen = (taken[base] ?? 0) + 1
      taken[base] = seen
      let name = seen == 1 ? base : "\(base) (\(seen))"
      let engine = state.engineProfile(id)
      if let index = indexes[engine] {
        targets[index].names.append(name)
      } else {
        indexes[engine] = targets.count
        targets.append(UserScriptsTarget(engine: engine, names: [name]))
      }
    }
    return targets
  }

  public func sync(enabled on: Bool, targets next: [UserScriptsTarget]) {
    targets = next
    let key = on ? next : []
    guard on != enabled || key != syncedTargets else { return }
    enabled = on
    syncedTargets = key
    host.watch(on)
    if on { schedule() }
  }

  public func schedule() {
    if running != nil {
      again = true
      return
    }
    running = Task { @MainActor in
      repeat {
        again = false
        do { try await reconcile() }
        catch { host.warn("[scripts] couldn't apply the solara scripts", error: error) }
      } while again && enabled
      running = nil
    }
  }

  public func waitUntilIdle() async {
    while let running { await running.value }
  }

  private func seed() async {
    guard !seeded else { return }
    seeded = true
    do {
      lastStatus = try await host.readStatus()
      guard let lastStatus, !lastStatus.isEmpty else { return }
      let status = try JSONValue.parse(lastStatus)
      guard let generation = status["generation"]?.number, let profiles = status["profiles"]?.object else { return }
      for target in targets {
        guard let name = target.names.first else { continue }
        guard let outcome = profiles[name], outcome.truthy else { continue }
        if outcome.object == nil && outcome.array == nil { throw InvalidScriptsStatus() }
        let object = outcome.object
        if object?.contains("error") == true || target.names.contains(where: { !Self.sameToken(profiles[$0]?.text(), outcome.text()) }) { continue }
        applied[target.engine] = Applied(generation: generation, wanted: object?.contains("removed") == true ? .absent : .present, outcome: outcome)
      }
    } catch {
      host.warn("[scripts] couldn't read status.json", error: error)
    }
  }

  private func reconcile() async throws {
    guard enabled else { return }
    await seed()
    let folder = try await host.read()
    guard enabled, !again else { return }
    if ["empty", "busy", "pending"].contains(folder.state) { return }
    let generation = folder.generation ?? 0
    let targets = self.targets
    var outcomes = JSMap<JSONValue>()
    let refused = folder.state == "invalid" ? folder.error : nil
    let loadPath = folder.state == "ready" ? folder.path : nil
    let unloadPath = ["absent", "invalid"].contains(folder.state) ? folder.path : nil
    let wanted: Wanted = loadPath?.isEmpty == false ? .present : .absent
    for target in targets {
      let done = applied[target.engine]
      let cached = refused == nil && done?.generation == generation && done?.wanted == wanted
      let outcome: JSONValue?
      if cached {
        outcome = done?.outcome
      } else if let refused {
        if let unloadPath, !unloadPath.isEmpty {
          let unloaded = await unload(target.engine, path: unloadPath)
          let suffix = unloaded["error"]?.string.map { " (and the loaded copy couldn't be removed: \($0))" } ?? ""
          outcome = ["error": .string(refused + suffix)]
        } else {
          outcome = ["error": .string(refused)]
        }
      } else if let loadPath, !loadPath.isEmpty {
        outcome = await load(target.engine, path: loadPath)
      } else if let unloadPath, !unloadPath.isEmpty {
        outcome = await unload(target.engine, path: unloadPath)
      } else {
        outcome = ["removed": true]
      }
      if !cached, !Self.sameToken(try await host.read().token, folder.token) {
        applied[target.engine] = nil
        again = true
        return
      }
      outcomes[target.engine] = outcome
      if outcome?.object?.contains("error") != true {
        applied[target.engine] = Applied(generation: generation, wanted: wanted, outcome: outcome)
      }
      guard enabled else { return }
    }
    guard !again, enabled else { return }
    var profiles = JSONObject()
    for target in targets {
      for name in target.names where name != "__proto__" { profiles[name] = outcomes[target.engine] }
    }
    let status: JSONValue = ["generation": .number(generation), "profiles": .object(profiles)]
    let json = Self.pretty(status)
    guard lastStatus.map({ json.jsEquals($0) }) != true else { return }
    try await host.writeStatus(json)
    lastStatus = json
  }

  private func load(_ profile: String, path: String) async -> JSONValue {
    do {
      let existing = try await host.list(profile).first { Self.loadedFrom($0, path: path) }
      if let existing, !existing.enabled, !existing.blockedByPolicy {
        try await host.reload(existing.id, profile: profile)
        return ["disabled": true]
      }
      let id = try await host.install(path, profile: profile)
      guard let loaded = try await host.list(profile).first(where: { $0.id.jsEquals(id) }) else { return ["error": "The extension didn't load."] }
      if loaded.enabled { return ["ok": true] }
      if loaded.blockedByPolicy {
        return ["error": .string(loaded.errors.first ?? "\(product) Scripts can only hold content scripts, and the engine blocked this copy.")]
      }
      return loaded.state == "DISABLED" ? ["disabled": true] : ["error": .string("The extension is \(loaded.state.lowercased()).")]
    } catch {
      return ["error": .string(error.localizedDescription)]
    }
  }

  private func unload(_ profile: String, path: String) async -> JSONValue {
    do {
      for ext in try await host.list(profile).filter({ Self.loadedFrom($0, path: path) }) {
        try await host.uninstall(ext.id, profile: profile)
      }
      return ["removed": true]
    } catch {
      return ["error": .string(error.localizedDescription)]
    }
  }

  private struct InvalidScriptsStatus: Error {}

  private static func sameToken(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): true
    case (.some(let lhs), .some(let rhs)): lhs.jsEquals(rhs)
    default: false
    }
  }

  private static func loadedFrom(_ ext: UserScriptsExtension, path: String) -> Bool {
    guard let source = ext.path, !source.isEmpty else { return false }
    return withoutPrivate(source).jsEquals(withoutPrivate(path))
  }

  private static func withoutPrivate(_ path: String) -> String {
    if ["/private/tmp/", "/private/var/", "/private/etc/"].contains(where: { path.hasPrefix($0) }) { return String(path.dropFirst(8)) }
    return path
  }

  private static func pretty(_ value: JSONValue, depth: Int = 0) -> String {
    let indent = String(repeating: "  ", count: depth)
    let inner = indent + "  "
    switch value {
    case .object(let object):
      if object.isEmpty { return "{}" }
      return "{\n" + object.map { inner + JSONValue.string($0.key).text() + ": " + pretty($0.value, depth: depth + 1) }.joined(separator: ",\n") + "\n" + indent + "}"
    case .array(let array):
      if array.isEmpty { return "[]" }
      return "[\n" + array.map { inner + pretty($0, depth: depth + 1) }.joined(separator: ",\n") + "\n" + indent + "]"
    default: return value.text()
    }
  }
}
