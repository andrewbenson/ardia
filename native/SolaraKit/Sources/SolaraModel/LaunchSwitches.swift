import Foundation
import Synchronization
#if os(macOS)
import Security
#endif
#if canImport(CoreGraphics) && os(macOS)
import CoreGraphics
#endif

public enum LaunchSwitch: String, CaseIterable, Sendable {
  case nativeShell = "ARDIA_NATIVE_SHELL"
  case shellPanes = "ARDIA_SHELL_PANES"
  case nativePagesPool = "ARDIA_NATIVE_PAGES_POOL"
  case shellMainTop = "ARDIA_SHELL_MAIN_TOP"
  case nativeSidebar = "ARDIA_NATIVE_SIDEBAR"
  case nativeTopStrip = "ARDIA_NATIVE_TOP_STRIP"
  case nativeIconPicker = "ARDIA_NATIVE_ICON_PICKER"
  case nativeMedia = "ARDIA_NATIVE_MEDIA"
  case nativeAutoHide = "ARDIA_NATIVE_AUTOHIDE"
  case nativeSettings = "ARDIA_NATIVE_SETTINGS"
  case nativeImport = "ARDIA_NATIVE_IMPORT"
  case nativeOnboarding = "ARDIA_NATIVE_ONBOARDING"
  case nativeNewTab = "ARDIA_NATIVE_NEWTAB"
  case nativeOmnibox = "ARDIA_NATIVE_OMNIBOX"
  case nativePages = "ARDIA_NATIVE_PAGES"
  case nativeStatusBubble = "ARDIA_NATIVE_STATUS_BUBBLE"
  case nativeDownloadMagnet = "ARDIA_NATIVE_DOWNLOAD_MAGNET"
  case nativeSidePanel = "ARDIA_NATIVE_SIDE_PANEL"
  case nativePanePrompts = "ARDIA_NATIVE_PANE_PROMPTS"
  case nativeStore = "ARDIA_NATIVE_STORE"
  case nativeTabPickers = "ARDIA_NATIVE_TAB_PICKERS"
  case syncRedesign = "ARDIA_SYNC_REDESIGN"
  case nativeServices = "ARDIA_NATIVE_SERVICES"

  public static let experiments: [LaunchSwitch] = [.nativeShell, .shellPanes, .nativeAutoHide, .nativeSidebar, .nativeTopStrip, .nativeMedia]
  static let storedInDevelopment: Set<LaunchSwitch> = [
    .nativeShell, .shellPanes, .nativePagesPool, .shellMainTop, .nativeSidebar, .nativeTopStrip, .nativeMedia, .nativeAutoHide, .nativeTabPickers,
  ]
  static let developmentOnly: Set<LaunchSwitch> = [.syncRedesign]

  public var needs: [LaunchSwitch] {
    switch self {
    case .shellPanes, .nativePagesPool, .nativeAutoHide, .nativeTabPickers: [.nativeShell]
    case .shellMainTop: [.shellPanes, .nativePagesPool]
    default: []
    }
  }

  public func storable(distribution: Bool) -> Bool {
    distribution ? Self.experiments.contains(self) : Self.storedInDevelopment.contains(self)
  }
}

public struct LaunchSwitches: Sendable {
  public static let scopeVariable = "ARDIA_NATIVE_SCOPE"
  public static let defaultsVariable = "ARDIA_LAUNCH_SWITCHES_DEFAULTS"
  public static let optionVariable = "ARDIA_LAUNCH_SWITCHES_OPTION"
  static let storedPrefixes = ["ARDIA_NATIVE_", "ARDIA_SHELL_"]

  public let isolated: Bool
  public let defaultsSuite: String?
  public let distribution: Bool
  public let skippedStored: Bool
  public var droppedAfterFailedLaunches = false
  public var countedLaunch = false
  public let scope: String?
  let environment: [LaunchSwitch: Bool]
  let stored: [LaunchSwitch: Bool]

  public init(environment env: [String: String], defaults: UserDefaults?, distribution: Bool, skipStored: Bool) {
    let isolated = env["ARDIA_BACKGROUND"] == "1" || env["ARDIA_DATA_DIR"] != nil
    self.isolated = isolated
    let suite = distribution ? nil : env[Self.defaultsVariable].flatMap { $0.isEmpty ? nil : $0 }
    self.defaultsSuite = suite
    self.distribution = distribution
    self.scope = env[Self.scopeVariable]
    var environment: [LaunchSwitch: Bool] = [:]
    let ownDataFolder = env["ARDIA_DATA_DIR"].map { !$0.isEmpty } ?? false
    for name in LaunchSwitch.allCases where !LaunchSwitch.developmentOnly.contains(name) || (ownDataFolder && !distribution) {
      if let value = env[name.rawValue].flatMap(Self.parse) { environment[name] = value }
    }
    self.environment = environment
    let readsDefaults = (!isolated || suite != nil) && defaults != nil
    self.skippedStored = readsDefaults && skipStored
      && LaunchSwitch.allCases.contains { $0.storable(distribution: distribution) && Self.storedValue($0, in: defaults) != nil }
    var stored: [LaunchSwitch: Bool] = [:]
    if readsDefaults, !skipStored, let defaults {
      for name in LaunchSwitch.allCases where name.storable(distribution: distribution) {
        if let value = Self.storedValue(name, in: defaults) { stored[name] = value }
      }
    }
    self.stored = stored
  }

  public var usesDefaults: Bool { !isolated || defaultsSuite != nil }

  public static var defaults: UserDefaults { shared.defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

  static let current = Mutex<LaunchSwitches?>(nil)

  public static var shared: LaunchSwitches {
    current.withLock { current in
      if let current { return current }
      let switches = system(counting: false)
      current = switches
      return switches
    }
  }

  @discardableResult
  public static func countLaunch() -> LaunchSwitches {
    current.withLock { current in
      if let current { return current }
      let switches = system(counting: true)
      current = switches
      return switches
    }
  }

  public func isOn(_ name: LaunchSwitch, defaultOn: Bool) -> Bool {
    environment[name] ?? stored[name] ?? defaultOn
  }

  public func fromEnvironment(_ name: LaunchSwitch) -> Bool { environment[name] != nil }

  static func parse(_ text: String) -> Bool? {
    switch text {
    case "1": true
    case "0": false
    default: nil
    }
  }

  static func storedValue(_ name: LaunchSwitch, in defaults: UserDefaults?) -> Bool? {
    switch defaults?.object(forKey: name.rawValue) {
    case let text as String: parse(text)
    case let number as NSNumber: number.intValue == 1 ? true : number.intValue == 0 ? false : nil
    default: nil
    }
  }

  static let failedLaunchesKey = "SolaraLaunchSwitchFailedLaunches"
  static let failedLaunchLimit = 2

  public static func launching(environment env: [String: String], defaults: UserDefaults, distribution: Bool, optionHeld: () -> Bool) -> LaunchSwitches {
    let probe = LaunchSwitches(environment: env, defaults: nil, distribution: distribution, skipStored: false)
    if !probe.usesDefaults { return probe }
    var switches = LaunchSwitches(environment: env, defaults: defaults, distribution: distribution, skipStored: optionHeld())
    guard !switches.stored.isEmpty else {
      defaults.removeObject(forKey: failedLaunchesKey)
      return switches
    }
    let failed = defaults.integer(forKey: failedLaunchesKey)
    if failed >= failedLaunchLimit {
      StoredLaunchSwitches(defaults: defaults, distribution: distribution).clear()
      defaults.removeObject(forKey: failedLaunchesKey)
      switches = LaunchSwitches(environment: env, defaults: defaults, distribution: distribution, skipStored: false)
      switches.droppedAfterFailedLaunches = true
      return switches
    }
    defaults.set(failed + 1, forKey: failedLaunchesKey)
    switches.countedLaunch = true
    return switches
  }

  public static func launchSucceeded(defaults: UserDefaults = LaunchSwitches.defaults, isolated: Bool = !shared.usesDefaults) {
    guard !isolated else { return }
    defaults.removeObject(forKey: failedLaunchesKey)
  }

  static func system(counting: Bool) -> LaunchSwitches {
    let env = ProcessInfo.processInfo.environment
    let distribution = signedForDistribution()
    let probe = LaunchSwitches(environment: env, defaults: nil, distribution: distribution, skipStored: false)
    let defaults = probe.defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    let held = { (probe.defaultsSuite != nil && env[optionVariable] == "1") || optionHeld() }
    if counting { return launching(environment: env, defaults: defaults, distribution: distribution, optionHeld: held) }
    if !probe.usesDefaults { return probe }
    return LaunchSwitches(environment: env, defaults: defaults, distribution: distribution, skipStored: held())
  }

  static func optionHeld() -> Bool {
    #if canImport(CoreGraphics) && os(macOS)
    CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    #else
    false
    #endif
  }

  static func signedForDistribution() -> Bool {
    #if os(macOS)
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
    let text = "anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or "
      + "certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists)"
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return true }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    #else
    false
    #endif
  }
}

public struct StoredLaunchSwitches {
  let defaults: UserDefaults?
  public let distribution: Bool

  public init(defaults: UserDefaults?, distribution: Bool) {
    self.defaults = defaults
    self.distribution = distribution
  }

  public init(_ running: LaunchSwitches, defaults: UserDefaults = LaunchSwitches.defaults) {
    self.init(defaults: running.usesDefaults ? defaults : nil, distribution: running.distribution)
  }

  public var writable: Bool { defaults != nil }

  public func value(_ name: LaunchSwitch) -> Bool? {
    name.storable(distribution: distribution) ? LaunchSwitches.storedValue(name, in: defaults) : nil
  }

  public var any: Bool { LaunchSwitch.allCases.contains { value($0) != nil } }

  public func set(_ name: LaunchSwitch, _ on: Bool?) {
    guard let defaults, name.storable(distribution: distribution) else { return }
    if let on { defaults.set(on ? "1" : "0", forKey: name.rawValue) } else { defaults.removeObject(forKey: name.rawValue) }
    removeUnknown()
  }

  public func clear() {
    guard let defaults else { return }
    for name in LaunchSwitch.allCases where name.storable(distribution: distribution) { defaults.removeObject(forKey: name.rawValue) }
    removeUnknown()
  }

  func removeUnknown() {
    guard let defaults else { return }
    let known = Set(LaunchSwitch.allCases.map(\.rawValue) + [LaunchSwitches.scopeVariable])
    for key in defaults.dictionaryRepresentation().keys
    where LaunchSwitches.storedPrefixes.contains(where: key.hasPrefix) && !known.contains(key) {
      defaults.removeObject(forKey: key)
    }
  }
}
