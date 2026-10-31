import Foundation
import Security

public enum SafeStorageRekeyOutcome: Equatable {
  case proceed
  case quit(code: Int32, message: String)
}

struct RekeyJournal: Codable, Equatable {
  enum Phase: String, Codable {
    case keying, keyed, staged, swapping, undoing, done, abandoned
  }

  var phase: Phase
  var fromA: Bool
  var version: String
  var reason: String?
  var report: RekeyStageReport?
}

struct RekeyFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

public final class SafeStorageRekeyRun {
  public static let mockSecret = Data("mock_password".utf8)
  public static let otherCopyExitCode: Int32 = 75
  public static let undoFailedExitCode: Int32 = 70
  public static let crashExitCode: Int32 = 86
  static let sidecars = ["-wal", "-shm", "-journal"]

  let dir: URL
  let keychain: RekeyKeychain
  let stores: RekeyStoreOperations
  let appVersion: String
  let point: (String) -> Void
  let say: (String) -> Void
  let otherCopyOwns: (URL) -> Bool
  let newSecret: () -> Data?
  let plantedFailureAfterKey: Bool
  private var lockDescriptor: Int32 = -1
  private var moves = 0

  init(
    userDataDir: URL, keychain: RekeyKeychain, stores: RekeyStoreOperations, appVersion: String,
    point: @escaping (String) -> Void = { _ in }, say: @escaping (String) -> Void = { _ in },
    otherCopyOwns: @escaping (URL) -> Bool = SafeStorageRekeyRun.singletonHeld,
    newSecret: @escaping () -> Data? = SafeStorageRekeyRun.randomSecret, plantedFailureAfterKey: Bool = false
  ) {
    self.dir = userDataDir
    self.keychain = keychain
    self.stores = stores
    self.appVersion = appVersion
    self.point = point
    self.say = say
    self.otherCopyOwns = otherCopyOwns
    self.newSecret = newSecret
    self.plantedFailureAfterKey = plantedFailureAfterKey
  }

  deinit {
    releaseLock()
  }

  var journalURL: URL { dir.appendingPathComponent(".safe-storage-rekey.json") }
  var lockURL: URL { dir.appendingPathComponent(".safe-storage-rekey.lock") }
  var logURL: URL { dir.appendingPathComponent(".safe-storage-rekey.log") }
  var stagingDir: URL { dir.appendingPathComponent(".rekey-staging", isDirectory: true) }
  var oldDir: URL { dir.appendingPathComponent(".rekey-old", isDirectory: true) }

  static func unfinished(userDataDir: URL) -> Bool {
    let journal = userDataDir.appendingPathComponent(".safe-storage-rekey.json")
    guard let data = try? Data(contentsOf: journal) else { return FileManager.default.fileExists(atPath: journal.path) }
    guard let parsed = try? JSONDecoder().decode(RekeyJournal.self, from: data) else { return true }
    return ![.done, .abandoned].contains(parsed.phase)
  }

  static var holding: SafeStorageRekeyRun?

  public static func runAtLaunch(
    gate: SafeStorageRekeyGate, product: String, appVersion: String, environment env: [String: String],
    stores: (@escaping (String) -> Void) -> RekeyStoreOperations
  ) -> SafeStorageRekeyOutcome {
    if let refusal = gate.refusal { NSLog("[rekey] %@", refusal) }
    guard let keychain = gate.keychain(product: product, environment: env) else {
      return unfinished(userDataDir: gate.userDataDir) ? .quit(code: undoFailedExitCode, message: unfinishedMessage) : .proceed
    }
    let testing = gate.mode == .test
    let crashAt = testing ? env["SOLARA_TEST_REKEY_CRASH"] : nil
    let point = { (name: String) in
      if testing { NSLog("[rekey] point %@", name) }
      if name == crashAt { _exit(crashExitCode) }
    }
    var stagedStores = 0
    let operations = stores { _ in
      stagedStores += 1
      point("after-staged-store-\(stagedStores)")
    }
    let rekey = SafeStorageRekeyRun(
      userDataDir: gate.userDataDir, keychain: keychain, stores: operations, appVersion: appVersion, point: point,
      say: { NSLog("%@", $0) }, plantedFailureAfterKey: testing && env["SOLARA_TEST_REKEY_FAIL_AFTER_KEY"] == "1")
    holding = rekey
    return rekey.run()
  }

  public static func runAtLaunch(
    chromeUsesRealKeychain: Bool, installedUserDataDir: String, stores: (@escaping (String) -> Void) -> RekeyStoreOperations
  ) -> Int32? {
    let env = ProcessInfo.processInfo.environment
    let info = Bundle.main.infoDictionary
    let product = info?["CFBundleName"] as? String ?? "Solara"
    let gate = SafeStorageRekeyGate.resolve(
      environment: env, chromeUsesRealKeychain: chromeUsesRealKeychain,
      signedForDistribution: env["SOLARA_TEST_REKEY"] == nil ? false : buildSignedForDistribution,
      installedUserDataDir: URL(fileURLWithPath: installedUserDataDir, isDirectory: true))
    let outcome = runAtLaunch(
      gate: gate, product: product, appVersion: info?["CFBundleVersion"] as? String ?? "", environment: env, stores: stores)
    guard case .quit(let code, let message) = outcome else { return nil }
    FileHandle.standardError.write(Data("[rekey] \(message)\n".utf8))
    if env["SOLARA_BACKGROUND"] != "1" { _ = alert("\(product) can't open yet", message, ["Quit"]) }
    return code
  }

  static func alert(_ title: String, _ message: String, _ buttons: [String]) -> Int? {
    var response: CFOptionFlags = 0
    let icon = Bundle.main.url(forResource: (Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "AppIcon", withExtension: "icns") as CFURL?
    let result = CFUserNotificationDisplayAlert(
      0, kCFUserNotificationNoteAlertLevel, icon, nil, nil, title as CFString, message as CFString,
      buttons.first as CFString?, buttons.count > 1 ? buttons[1] as CFString : nil, buttons.count > 2 ? buttons[2] as CFString : nil,
      &response)
    guard result == 0 else { return nil }
    switch response & 0x3 {
    case CFOptionFlags(kCFUserNotificationDefaultResponse): return 0
    case CFOptionFlags(kCFUserNotificationAlternateResponse): return 1
    case CFOptionFlags(kCFUserNotificationOtherResponse): return 2
    default: return nil
    }
  }

  public static var buildSignedForDistribution: Bool { DeviceOwnerCheck.signedForDistribution }

  static let unfinishedMessage =
    "This copy of Solara can't finish moving your saved passwords and cookies to their new key. Open the installed Solara instead."

  func run() -> SafeStorageRekeyOutcome {
    let journal: RekeyJournal?
    do {
      journal = try loadJournal()
    } catch {
      return undoFailed("the journal can't be read: \(error)")
    }
    let keepingOriginals = journal?.phase == .done && journal?.version == appVersion
    if keepingOriginals && present(stagingDir) {
      if takeLock() {
        do { try removeIfPresent(stagingDir) } catch { log("can't remove the staging folder: \(error)") }
      } else {
        log("staging left for the copy that owns the data dir")
      }
    }
    if let journal, journal.phase != .done && journal.phase != .abandoned || leftovers() && !keepingOriginals {
      if let busy = lock() { return busy }
      if let outcome = recover(journal) { return outcome }
    } else if journal == nil && leftovers() {
      return keepMockKey("leftover re-key folders with no journal")
    }
    let settled = try? loadJournal()
    if let settled, settled.phase == .abandoned, settled.version == appVersion {
      return .proceed
    }
    return fresh(afterDone: settled?.phase == .done)
  }

  private func fresh(afterDone: Bool = false) -> SafeStorageRekeyOutcome {
    guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("Local State").path) else { return .proceed }
    let fromA: Bool
    switch keychain.exists() {
    case .absent:
      fromA = false
    case .value:
      if afterDone { return .proceed }
      guard case .value(let value) = keychain.read(), value == Self.mockSecret else {
        return abandon("the Safe Storage item exists and isn't the mock key")
      }
      fromA = true
    case .failed(let status):
      log("the Safe Storage item can't be looked up (\(status)): not migrating")
      return .proceed
    }
    if leftovers() { return keepMockKey("re-key folders from an earlier run are still there") }
    if let busy = lock() { return busy }
    let preflight = stores.preflight(userDataDir: dir, oldSecret: Self.mockSecret)
    guard preflight.mockKeyed else {
      log("the data isn't provably mock-keyed: not migrating")
      return .proceed
    }
    log("preflight: \(preflight.oldKeyedValues) values under the mock key" + notes(preflight.notes))
    guard preflight.blocking.isEmpty else {
      return fallBackBeforeKey("preflight blocked: " + preflight.blocking.joined(separator: "; "), fromA: fromA)
    }
    return key(fromA: fromA)
  }

  private func key(fromA: Bool) -> SafeStorageRekeyOutcome {
    guard writeJournal(RekeyJournal(phase: .keying, fromA: fromA, version: appVersion)) else {
      return fallBackBeforeKey("can't write the journal", fromA: fromA)
    }
    point("after-keying")
    guard let secret = newSecret() else { return fallBackBeforeKey("no random bytes for the key", fromA: fromA) }
    if fromA {
      guard case .value(let value) = keychain.read(), value == Self.mockSecret else {
        return abandon("the item changed before the update")
      }
      let status = keychain.update(secret)
      if status != errSecSuccess {
        log("updating the item failed (\(status))")
        switch keychain.read() {
        case .value(Self.mockSecret): return fallBackBeforeKey("the update didn't happen", fromA: true)
        case .value(secret): break
        default: return undo("the item is in an unknown state after a failed update")
        }
      }
    } else {
      let status = keychain.addIfAbsent(secret)
      if status != errSecSuccess {
        log("adding the item failed (\(status))")
        switch keychain.read() {
        case .absent: return fallBackBeforeKey("the key wasn't added", fromA: false)
        case .value(secret): break
        case .value: return abandon("another key appeared in the keychain")
        case .failed: return undo("the item is in an unknown state after a failed add")
        }
      }
    }
    point("after-key-write")
    guard case .value(secret) = keychain.read() else { return undo("the key didn't read back") }
    guard writeJournal(RekeyJournal(phase: .keyed, fromA: fromA, version: appVersion)) else {
      return undo("can't write the journal after the key")
    }
    point("after-keyed")
    if plantedFailureAfterKey { return undo("planted failure after the key") }
    return stageAndSwap(secret: secret, fromA: fromA, retry: true)
  }

  private func stageAndSwap(secret: Data, fromA: Bool, retry: Bool) -> SafeStorageRekeyOutcome {
    do {
      try removeIfPresent(stagingDir)
    } catch {
      return undo("can't clear the staging folder: \(error)")
    }
    let report: RekeyStageReport
    do {
      report = try stores.stage(userDataDir: dir, stagingDir: stagingDir, oldSecret: Self.mockSecret, newSecret: secret)
    } catch {
      return undo("staging failed: \(error)")
    }
    for note in report.notes { log(note) }
    for store in report.stores {
      let staged = stagingDir.appendingPathComponent(store.relativePath)
      guard stores.verify(file: staged, kind: store.kind, newSecret: secret, oldSecret: Self.mockSecret, expectedValues: store.values) else {
        return undo("the staged \(store.relativePath) didn't verify")
      }
    }
    point("after-stage")
    syncTree(stagingDir)
    guard writeJournal(RekeyJournal(phase: .staged, fromA: fromA, version: appVersion, report: report)) else {
      return undo("can't write the journal after staging")
    }
    point("after-staged")
    return swap(secret: secret, fromA: fromA, report: report, retry: retry)
  }

  private func swap(secret: Data, fromA: Bool, report: RekeyStageReport, retry: Bool) -> SafeStorageRekeyOutcome {
    if otherCopyOwns(dir) { return otherCopy() }
    guard writeJournal(RekeyJournal(phase: .swapping, fromA: fromA, version: appVersion, report: report)) else {
      return undo("can't write the journal before swapping")
    }
    point("after-swapping")
    do {
      for store in report.stores { try swapOne(store.relativePath) }
      for discarded in report.discard { try moveAside(discarded) }
    } catch {
      return undo("swapping failed: \(error)")
    }
    for store in report.stores {
      let live = dir.appendingPathComponent(store.relativePath)
      guard stores.verify(file: live, kind: store.kind, newSecret: secret, oldSecret: Self.mockSecret, expectedValues: store.values) else {
        guard retry else { return undo("the swapped-in \(store.relativePath) didn't verify twice") }
        log("the swapped-in \(store.relativePath) didn't verify: staging again from the originals")
        do { try restoreOriginals() } catch { return undo("can't put the originals back: \(error)") }
        guard writeJournal(RekeyJournal(phase: .keyed, fromA: fromA, version: appVersion)) else {
          return undo("can't write the journal before staging again")
        }
        point("after-restage-keyed")
        return stageAndSwap(secret: secret, fromA: fromA, retry: false)
      }
    }
    guard writeJournal(RekeyJournal(phase: .done, fromA: fromA, version: appVersion, report: report)) else {
      return .quit(code: Self.otherCopyExitCode, message: "Solara couldn't finish moving your saved passwords and cookies to their new key. Quit and open Solara again.")
    }
    point("after-done-write")
    do { try removeIfPresent(stagingDir) } catch { log("can't remove the staging folder: \(error)") }
    log("done: \(report.stores.count) stores re-keyed, \(report.discard.count) discarded")
    point("after-done")
    return .proceed
  }

  private func swapOne(_ relativePath: String) throws {
    let live = dir.appendingPathComponent(relativePath)
    let staged = stagingDir.appendingPathComponent(relativePath)
    let old = oldDir.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    let stagedThere = present(staged), liveThere = present(live), oldThere = present(old)
    guard stagedThere else {
      guard liveThere && oldThere else { throw RekeyFailure("\(relativePath) is missing from staging, live and originals") }
      return
    }
    if liveThere {
      guard !oldThere else { throw RekeyFailure("\(relativePath) has a live file and an original") }
      for sidecar in Self.sidecars where present(sibling(live, sidecar)) {
        try move(sibling(live, sidecar), to: sibling(old, sidecar))
        point("after-sidecar-\(moves)")
      }
      try move(live, to: old)
      point("after-aside-\(moves)")
    }
    try clearSidecars(of: live)
    try clearSidecars(of: staged)
    try move(staged, to: live)
    point("after-landed-\(moves)")
  }

  private func clearSidecars(of main: URL) throws {
    for sidecar in Self.sidecars where present(sibling(main, sidecar)) {
      let stray = stagingDir.appendingPathComponent(".stray", isDirectory: true)
      try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
      try move(sibling(main, sidecar), to: stray.appendingPathComponent("\(moves)-\(main.lastPathComponent)\(sidecar)"))
      log("moved a stray \(main.lastPathComponent)\(sidecar) out of the way")
    }
    for sidecar in Self.sidecars where present(sibling(main, sidecar)) {
      throw RekeyFailure("\(main.lastPathComponent)\(sidecar) is still there")
    }
  }

  private func moveAside(_ relativePath: String) throws {
    let live = dir.appendingPathComponent(relativePath)
    guard present(live) else { return }
    let old = oldDir.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    try move(live, to: old)
    point("after-discard-\(moves)")
  }

  private func recover(_ journal: RekeyJournal) -> SafeStorageRekeyOutcome? {
    log("recovering a re-key at \(journal.phase.rawValue)")
    switch journal.phase {
    case .keying:
      switch keychain.read() {
      case .absent, .value(Self.mockSecret):
        do { try restoreOriginals() } catch { return undoFailed("can't clear a run that never keyed: \(error)") }
        guard unlink(journalURL.path) == 0 else { return undoFailed("can't clear the journal of a run that never keyed") }
        MigrationFiles.syncFolder(dir)
        return fresh()
      case .value(let secret):
        guard stores.preflight(userDataDir: dir, oldSecret: Self.mockSecret).mockKeyed else {
          return undo("a key exists but the data isn't mock-keyed")
        }
        guard writeJournal(RekeyJournal(phase: .keyed, fromA: journal.fromA, version: appVersion)) else {
          return undo("can't write the journal after the key")
        }
        return stageAndSwap(secret: secret, fromA: journal.fromA, retry: true)
      case .failed(let status):
        return keychainUnavailable(status)
      }
    case .keyed:
      switch keychain.read() {
      case .value(Self.mockSecret), .absent:
        return undo("the key is gone before staging")
      case .value(let secret):
        do { try restoreOriginals() } catch { return undo("can't put the originals back: \(error)") }
        return stageAndSwap(secret: secret, fromA: journal.fromA, retry: true)
      case .failed(let status):
        return keychainUnavailable(status)
      }
    case .staged, .swapping:
      switch keychain.read() {
      case .value(Self.mockSecret), .absent:
        return undo("the key is gone while swapping")
      case .value(let secret):
        guard let report = journal.report else { return undo("the journal has no staging report") }
        return swap(secret: secret, fromA: journal.fromA, report: report, retry: true)
      case .failed(let status):
        return keychainUnavailable(status)
      }
    case .undoing:
      return finishUndo(journal.reason ?? "an earlier undo")
    case .done:
      point("before-cleanup")
      do {
        try removeIfPresent(stagingDir)
        try removeIfPresent(oldDir)
      } catch {
        log("can't remove the re-key folders: \(error)")
      }
      return nil
    case .abandoned:
      do { try restoreOriginals() } catch { return undoFailed("can't clear an abandoned run: \(error)") }
      return nil
    }
  }

  private func fallBackBeforeKey(_ reason: String, fromA: Bool) -> SafeStorageRekeyOutcome {
    log(reason + ": keeping the mock key")
    if !fromA {
      let status = keychain.addIfAbsent(Self.mockSecret)
      guard status == errSecSuccess || keychain.read() == .value(Self.mockSecret) else {
        return keychainUnavailable(status)
      }
    }
    writeJournal(RekeyJournal(phase: .abandoned, fromA: fromA, version: appVersion, reason: reason))
    return .proceed
  }

  private func keepMockKey(_ reason: String) -> SafeStorageRekeyOutcome {
    log(reason + ": leaving the folders alone")
    guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("Local State").path),
      keychain.exists() == .absent
    else { return .proceed }
    if let busy = lock() { return busy }
    guard stores.preflight(userDataDir: dir, oldSecret: Self.mockSecret).mockKeyed else { return .proceed }
    let status = keychain.addIfAbsent(Self.mockSecret)
    guard status == errSecSuccess || keychain.read() == .value(Self.mockSecret) else {
      return keychainUnavailable(status)
    }
    log("kept the mock key")
    return .proceed
  }

  private func abandon(_ reason: String) -> SafeStorageRekeyOutcome {
    log(reason + ": not migrating")
    do { try removeIfPresent(stagingDir) } catch { log("can't remove the staging folder: \(error)") }
    writeJournal(RekeyJournal(phase: .abandoned, fromA: false, version: appVersion, reason: reason))
    return .proceed
  }

  private func undo(_ reason: String) -> SafeStorageRekeyOutcome {
    log(reason + ": undoing")
    if !writeJournal(RekeyJournal(phase: .undoing, fromA: false, version: appVersion, reason: reason)) {
      log("can't write the journal before undoing")
    }
    point("after-undoing")
    return finishUndo(reason)
  }

  private func finishUndo(_ reason: String) -> SafeStorageRekeyOutcome {
    do { try restoreOriginals() } catch { return undoFailed("putting the originals back: \(error)") }
    point("after-undo-files")
    switch keychain.read() {
    case .value(Self.mockSecret):
      break
    case .value:
      let status = keychain.update(Self.mockSecret)
      guard status == errSecSuccess, keychain.read() == .value(Self.mockSecret) else {
        return undoFailed("can't set the item back to the mock key (\(status))")
      }
    case .absent:
      let status = keychain.addIfAbsent(Self.mockSecret)
      guard status == errSecSuccess || keychain.read() == .value(Self.mockSecret) else {
        return undoFailed("can't add the mock-key item (\(status))")
      }
    case .failed(let status):
      return undoFailed("can't read the item to undo (\(status))")
    }
    point("after-undo-keychain")
    guard writeJournal(RekeyJournal(phase: .abandoned, fromA: false, version: appVersion, reason: reason)) else {
      return undoFailed("can't write the journal after undoing")
    }
    log("undone: the data and the item are on the mock key again")
    return .proceed
  }

  func restoreOriginals() throws {
    if present(oldDir) {
      try restore(from: oldDir, into: dir)
      guard !containsFiles(oldDir) else { throw RekeyFailure("originals left behind") }
      try FileManager.default.removeItem(at: oldDir)
    }
    try removeIfPresent(stagingDir)
  }

  private func restore(from source: URL, into target: URL) throws {
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: source.path))
    let isSidecar = { (name: String) in Self.sidecars.contains { name.hasSuffix($0) && names.contains(String(name.dropLast($0.count))) } }
    for name in names.sorted() where !isSidecar(name) {
      let from = source.appendingPathComponent(name), to = target.appendingPathComponent(name)
      if isDirectory(from) && isDirectory(to) {
        try restore(from: from, into: to)
        continue
      }
      if isDirectory(to) { throw RekeyFailure("a folder sits where \(name) was") }
      if !isDirectory(from) { try clearSidecars(of: to) }
      try putBack(from, to: to)
      for sidecar in Self.sidecars where names.contains(name + sidecar) {
        try putBack(source.appendingPathComponent(name + sidecar), to: target.appendingPathComponent(name + sidecar))
      }
    }
  }

  private func putBack(_ from: URL, to: URL) throws {
    guard rename(from.path, to.path) == 0 else {
      throw RekeyFailure("can't put back \(from.lastPathComponent): \(String(cString: strerror(errno)))")
    }
    moves += 1
    MigrationFiles.syncFolder(to.deletingLastPathComponent())
    point("after-undo-\(moves)")
  }

  private func lock() -> SafeStorageRekeyOutcome? {
    takeLock() ? nil : otherCopy()
  }

  private func takeLock() -> Bool {
    if lockDescriptor >= 0 { return true }
    if otherCopyOwns(dir) { return false }
    let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      return false
    }
    lockDescriptor = fd
    return true
  }

  func releaseLock() {
    if lockDescriptor >= 0 { close(lockDescriptor) }
    lockDescriptor = -1
  }

  public static func singletonHeld(_ userDataDir: URL) -> Bool {
    singletonHeld(userDataDir, bundleIdentifier: Bundle.main.bundleIdentifier)
  }

  static func singletonHeld(_ userDataDir: URL, bundleIdentifier: String?) -> Bool {
    let link = userDataDir.appendingPathComponent("SingletonLock").path
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    guard readlink(link, &buffer, buffer.count - 1) > 0 else { return false }
    let target = String(cString: buffer)
    guard let dash = target.lastIndex(of: "-"), let pid = pid_t(target[target.index(after: dash)...]), pid > 0 else { return false }
    guard kill(pid, 0) == 0, let bundleIdentifier else { return false }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
    return enclosingBundleIdentifiers(of: String(cString: path)).contains(bundleIdentifier)
  }

  static func enclosingBundleIdentifiers(of executable: String) -> [String] {
    var identifiers: [String] = []
    var url = URL(fileURLWithPath: executable)
    while url.pathComponents.count > 1 {
      url.deleteLastPathComponent()
      guard url.pathExtension == "app",
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
        let identifier = info["CFBundleIdentifier"] as? String
      else { continue }
      identifiers.append(identifier)
    }
    return identifiers
  }

  public static func randomSecret() -> Data? {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
    return Data(Data(bytes).base64EncodedString().utf8)
  }

  private func otherCopy() -> SafeStorageRekeyOutcome {
    log("another copy owns the data dir: quitting")
    return .quit(code: Self.otherCopyExitCode, message: "Quit the other copy of Solara, then open it again.")
  }

  private func keychainUnavailable(_ status: OSStatus) -> SafeStorageRekeyOutcome {
    log("the keychain can't be read or written (\(status)): quitting")
    return .quit(
      code: Self.otherCopyExitCode,
      message: "Solara needs your login keychain to set up the key for your saved passwords and cookies. Unlock it, then open Solara again.")
  }

  private func undoFailed(_ reason: String) -> SafeStorageRekeyOutcome {
    log(reason + ": quitting")
    return .quit(
      code: Self.undoFailedExitCode,
      message: "Solara couldn't move your saved passwords and cookies to their new key. Restore the Solara folder from your backup; the log at \(logURL.path) says what failed.")
  }

  private func loadJournal() throws -> RekeyJournal? {
    guard present(journalURL) else { return nil }
    return try JSONDecoder().decode(RekeyJournal.self, from: Data(contentsOf: journalURL))
  }

  @discardableResult
  private func writeJournal(_ journal: RekeyJournal) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(journal) else { return false }
    return MigrationFiles.writeDurably(data, to: journalURL, mode: 0o600, fullSync: true)
  }

  private func log(_ message: String) {
    say("[rekey] " + message)
    let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: logURL) {
      handle.seekToEndOfFile()
      handle.write(line)
      try? handle.close()
    } else {
      try? line.write(to: logURL)
    }
  }

  private func notes(_ notes: [String]) -> String {
    notes.isEmpty ? "" : "; " + notes.joined(separator: "; ")
  }

  private func leftovers() -> Bool { present(stagingDir) || present(oldDir) }

  private func move(_ from: URL, to: URL) throws {
    guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
      throw RekeyFailure("can't move \(from.lastPathComponent): \(String(cString: strerror(errno)))")
    }
    moves += 1
    MigrationFiles.syncFolder(from.deletingLastPathComponent())
    MigrationFiles.syncFolder(to.deletingLastPathComponent())
  }

  private func removeIfPresent(_ url: URL) throws {
    guard present(url) else { return }
    try FileManager.default.removeItem(at: url)
  }

  private func syncTree(_ root: URL) {
    MigrationFiles.syncFolder(root)
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
    for case let url as URL in walker where isDirectory(url) { MigrationFiles.syncFolder(url) }
  }

  private func containsFiles(_ root: URL) -> Bool {
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
    for case let url as URL in walker where !isDirectory(url) { return true }
    return false
  }

  private func sibling(_ url: URL, _ suffix: String) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
  }

  private func present(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
  }

  private func isDirectory(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
  }
}
