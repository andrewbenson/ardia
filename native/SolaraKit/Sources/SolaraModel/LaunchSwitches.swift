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
  case nativeProfilePager = "ARDIA_NATIVE_PROFILE_PAGER"
  case syncRedesign = "ARDIA_SYNC_REDESIGN"
  case nativeServices = "ARDIA_NATIVE_SERVICES"
  case nativeToolTour = "ARDIA_NATIVE_TOOL_TOUR"

  public static let experiments: [LaunchSwitch] = [
    .nativeShell, .shellPanes, .nativeAutoHide, .nativeSidebar, .nativeTopStrip, .nativeMedia, .nativeToolTour, .nativeSidePanel,
  ]
  static let storedInDevelopment: Set<LaunchSwitch> = [
    .nativeShell, .shellPanes, .nativePagesPool, .shellMainTop, .nativeSidebar, .nativeTopStrip, .nativeMedia, .nativeAutoHide, .nativeTabPickers, .nativeProfilePager,
    .nativeToolTour, .nativeSidePanel,
  ]
  static let developmentOnly: Set<LaunchSwitch> = [.syncRedesign]
  public static var recoverable: [LaunchSwitch] { experiments.filter(onByDefault.contains) }
  public static let onByDefault: Set<LaunchSwitch> = [
    .nativeSettings, .nativeImport, .nativeOnboarding, .nativeNewTab, .nativeOmnibox, .nativeStatusBubble, .nativeStore, .nativePages,
    .nativeShell, .nativeTabPickers, .nativeTopStrip, .nativeDownloadMagnet, .nativeToolTour, .nativeSidePanel,
    .nativeSidebar, .nativeIconPicker, .nativeMedia, .nativeAutoHide, .nativeProfilePager,
  ]

  public var needs: [LaunchSwitch] {
    switch self {
    case .shellPanes, .nativePagesPool, .nativeAutoHide, .nativeTabPickers: [.nativeShell]
    case .shellMainTop: [.shellPanes, .nativePagesPool]
    case .nativeProfilePager: [.nativeShell, .nativeSidebar, .nativeTopStrip]
    case .nativeIconPicker: [.nativeShell, .nativeSidebar]
    case .nativePanePrompts: [.nativeShell, .nativePagesPool]
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
  public internal(set) var skippedStored: Bool
  public var droppedAfterFailedLaunches = false
  public internal(set) var turnedOffByRecovery: [LaunchSwitch] = []
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
    resolve(current, ask: askRecovery) { system(counting: false, recoveryAnswer: $0) }
  }

  @discardableResult
  public static func countLaunch() -> LaunchSwitches {
    resolve(current, ask: askRecovery) { system(counting: true, recoveryAnswer: $0) }
  }

  static func resolve(
    _ cell: borrowing Mutex<LaunchSwitches?>, ask: () -> Bool?, build: (Bool?) -> LaunchSwitches
  ) -> LaunchSwitches {
    if let existing = cell.withLock({ $0 }) { return existing }
    let recoveryAnswer = ask()
    return cell.withLock { current in
      if let current { return current }
      let switches = build(recoveryAnswer)
      current = switches
      return switches
    }
  }

  public func isOn(_ name: LaunchSwitch, defaultOn: Bool) -> Bool {
    requested(name, defaultOn: defaultOn) && unmetNeeds(name).isEmpty
  }

  public func isOn(_ name: LaunchSwitch) -> Bool {
    isOn(name, defaultOn: LaunchSwitch.onByDefault.contains(name))
  }

  public func requested(_ name: LaunchSwitch, defaultOn: Bool) -> Bool {
    environment[name] ?? stored[name] ?? defaultOn
  }

  public func unmetNeeds(_ name: LaunchSwitch) -> [LaunchSwitch] {
    name.needs.filter { !isOn($0) }
  }

  public var refusals: [String] {
    LaunchSwitch.allCases.compactMap { name in
      let unmet = unmetNeeds(name)
      guard !unmet.isEmpty, requested(name, defaultOn: LaunchSwitch.onByDefault.contains(name)) else { return nil }
      return "\(name.rawValue) is on but stays off: it needs \(unmet.map { "\($0.rawValue)=1" }.joined(separator: " and "))"
    }
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

  public static func launching(
    environment env: [String: String], defaults: UserDefaults, distribution: Bool, optionHeld: () -> Bool, counting: Bool = true,
    confirmRecovery: ([LaunchSwitch]) -> Bool = { _ in true }
  ) -> LaunchSwitches {
    let probe = LaunchSwitches(environment: env, defaults: nil, distribution: distribution, skipStored: false)
    if !probe.usesDefaults { return probe }
    var switches = LaunchSwitches(environment: env, defaults: defaults, distribution: distribution, skipStored: false)
    if optionHeld() {
      let turningOff = switches.wouldRecover
      if turningOff.isEmpty || confirmRecovery(turningOff) {
        defaults.removeObject(forKey: failedLaunchesKey)
        var recovered = turningOff.isEmpty ? switches : recover(switches, environment: env, defaults: defaults)
        recovered.skippedStored = true
        return recovered
      }
    }
    guard counting else { return switches }
    guard !switches.wouldRecover.isEmpty else {
      defaults.removeObject(forKey: failedLaunchesKey)
      return switches
    }
    let failed = defaults.integer(forKey: failedLaunchesKey)
    if failed >= failedLaunchLimit {
      defaults.removeObject(forKey: failedLaunchesKey)
      switches = recover(switches, environment: env, defaults: defaults)
      switches.droppedAfterFailedLaunches = true
      return switches
    }
    defaults.set(failed + 1, forKey: failedLaunchesKey)
    switches.countedLaunch = true
    return switches
  }

  var wouldRecover: [LaunchSwitch] {
    LaunchSwitch.allCases.filter { name in
      name.storable(distribution: distribution) && (stored[name] ?? LaunchSwitch.recoverable.contains(name))
    }
  }

  static func recover(_ before: LaunchSwitches, environment env: [String: String], defaults: UserDefaults) -> LaunchSwitches {
    let turnedOff = before.wouldRecover
    let store = StoredLaunchSwitches(defaults: defaults, distribution: before.distribution)
    store.clear()
    for name in LaunchSwitch.recoverable { store.set(name, false) }
    var after = LaunchSwitches(environment: env, defaults: defaults, distribution: before.distribution, skipStored: false)
    after.turnedOffByRecovery = turnedOff
    return after
  }

  public var recoveryReport: String? {
    guard !turnedOffByRecovery.isEmpty else { return nil }
    let why = droppedAfterFailedLaunches ? "Solara didn't finish opening twice in a row" : "Option was held while Solara opened"
    let names = turnedOffByRecovery.map(\.rawValue).joined(separator: ", ")
    return "\(why), so these were turned off: \(names). Turn them back on in Settings › Advanced › Experimental, or in Terminal with defaults delete <domain> <NAME>."
  }

  public static func launchSucceeded(defaults: UserDefaults = LaunchSwitches.defaults, isolated: Bool = !shared.usesDefaults) {
    guard !isolated else { return }
    defaults.removeObject(forKey: failedLaunchesKey)
  }

  struct Launch {
    let env = ProcessInfo.processInfo.environment
    let distribution = signedForDistribution()
    var probe: LaunchSwitches { LaunchSwitches(environment: env, defaults: nil, distribution: distribution, skipStored: false) }
    var defaults: UserDefaults { probe.defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard }
  }

  static func askRecovery() -> Bool? {
    let launch = Launch()
    let probe = launch.probe
    guard probe.usesDefaults, (probe.defaultsSuite != nil && launch.env[optionVariable] == "1") || optionHeld() else { return nil }
    let turningOff = LaunchSwitches(environment: launch.env, defaults: launch.defaults, distribution: launch.distribution, skipStored: false)
      .wouldRecover
    return turningOff.isEmpty || probe.isolated || confirmRecoveryAlert(turningOff)
  }

  static func system(counting: Bool, recoveryAnswer: Bool?) -> LaunchSwitches {
    let launch = Launch()
    let switches = launching(
      environment: launch.env, defaults: launch.defaults, distribution: launch.distribution, optionHeld: { recoveryAnswer != nil },
      counting: counting, confirmRecovery: { _ in recoveryAnswer ?? false })
    if let report = switches.recoveryReport { NSLog("[launch switches] %@", report) }
    for refusal in switches.refusals { NSLog("[launch switches] %@", refusal) }
    return switches
  }

  static let spokenNames: [LaunchSwitch: String] = [
    .nativeShell: "the native window", .shellPanes: "native page overlays", .nativeAutoHide: "native auto-hide",
    .nativeSidebar: "the native sidebar", .nativeTopStrip: "the native tab strip", .nativeMedia: "native media controls",
    .nativeToolTour: "the native tool tour", .nativeSidePanel: "the native side panel",
  ]

  public static func recoveryQuestion(_ turningOff: [LaunchSwitch]) -> (title: String, message: String) {
    let names = turningOff.map { spokenNames[$0] ?? $0.rawValue }
    let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    return (
      "Turn off Solara's new native interface?",
      "Option was held while Solara opened. This turns off \(list), and they stay off until you turn them back on in Settings › Advanced › Experimental."
    )
  }

  static func confirmRecoveryAlert(_ turningOff: [LaunchSwitch]) -> Bool {
    #if os(macOS)
    let question = recoveryQuestion(turningOff)
    var response: CFOptionFlags = 0
    let shown = CFUserNotificationDisplayAlert(
      0, kCFUserNotificationCautionAlertLevel, nil, nil, nil, question.title as CFString, question.message as CFString,
      "Turn Off" as CFString, "Open Normally" as CFString, nil, &response)
    return shown == 0 && response & 0x3 == kCFUserNotificationDefaultResponse
    #else
    true
    #endif
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
