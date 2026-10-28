import Foundation
import Security

public enum RekeyItem: Equatable {
  case absent
  case value(Data)
  case failed(OSStatus)
}

public protocol RekeyKeychain {
  func exists() -> RekeyItem
  func read() -> RekeyItem
  func addIfAbsent(_ secret: Data) -> OSStatus
  func update(_ secret: Data) -> OSStatus
}

public struct RekeyLoginKeychain: RekeyKeychain {
  let service: String
  let account: String

  init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: false,
    ]
  }

  private func withoutInteraction<T>(_ body: () -> T) -> T {
    var allowed: DarwinBoolean = true
    let known = SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess
    SecKeychainSetUserInteractionAllowed(false)
    defer { if known { SecKeychainSetUserInteractionAllowed(allowed.boolValue) } }
    return body()
  }

  public func exists() -> RekeyItem {
    withoutInteraction(probe)
  }

  private func probe() -> RekeyItem {
    var probe = query
    probe[kSecReturnAttributes as String] = true
    probe[kSecMatchLimit as String] = kSecMatchLimitOne
    probe[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    var result: CFTypeRef?
    let status = SecItemCopyMatching(probe as CFDictionary, &result)
    switch status {
    case errSecSuccess: return .value(Data())
    case errSecItemNotFound: return .absent
    default: return .failed(status)
    }
  }

  public func read() -> RekeyItem {
    withoutInteraction(lookup)
  }

  private func lookup() -> RekeyItem {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    switch status {
    case errSecSuccess: return (result as? Data).map(RekeyItem.value) ?? .failed(errSecDecode)
    case errSecItemNotFound: return .absent
    default: return .failed(status)
    }
  }

  public func addIfAbsent(_ secret: Data) -> OSStatus {
    var add = query
    add[kSecValueData as String] = secret
    return withoutInteraction { SecItemAdd(add as CFDictionary, nil) }
  }

  public func update(_ secret: Data) -> OSStatus {
    withoutInteraction { SecItemUpdate(query as CFDictionary, [kSecValueData as String: secret] as CFDictionary) }
  }
}

public struct RekeyFileKeychain: RekeyKeychain {
  let file: URL
  let log: URL
  let failure: OSStatus

  public init(file: URL, log: URL, failure: OSStatus = errSecSuccess) {
    self.file = file
    self.log = log
    self.failure = failure
  }

  static func failure(named name: String?) -> OSStatus {
    switch name {
    case "decode": return errSecDecode
    case "denied": return errSecAuthFailed
    case "interaction": return errSecInteractionRequired
    case "entitlement": return errSecMissingEntitlement
    case "io": return errSecIO
    default: return errSecSuccess
    }
  }

  public func exists() -> RekeyItem {
    if failure != errSecSuccess {
      note("rekey probe failed \(failure)")
      return .failed(failure)
    }
    let present = FileManager.default.fileExists(atPath: file.path)
    note(present ? "rekey probe found" : "rekey probe missing")
    return present ? .value(Data()) : .absent
  }

  public func read() -> RekeyItem {
    if failure != errSecSuccess {
      note("rekey find failed \(failure)")
      return .failed(failure)
    }
    guard FileManager.default.fileExists(atPath: file.path) else {
      note("rekey find missing")
      return .absent
    }
    guard let data = try? Data(contentsOf: file) else {
      note("rekey find failed")
      return .failed(errSecIO)
    }
    note("rekey find found")
    return .value(data)
  }

  public func addIfAbsent(_ secret: Data) -> OSStatus {
    let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      let exists = errno == EEXIST
      note(exists ? "add duplicate" : "add failed")
      return exists ? errSecDuplicateItem : errSecIO
    }
    let wrote = secret.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == secret.count
    let synced = fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
    close(fd)
    guard wrote, synced else {
      note("add failed")
      return errSecIO
    }
    MigrationFiles.syncFolder(file.deletingLastPathComponent())
    note("add created")
    return errSecSuccess
  }

  public func update(_ secret: Data) -> OSStatus {
    guard FileManager.default.fileExists(atPath: file.path) else {
      note("rekey update missing")
      return errSecItemNotFound
    }
    guard MigrationFiles.writeDurably(secret, to: file, mode: 0o600, fullSync: true) else {
      note("rekey update failed")
      return errSecIO
    }
    note("rekey update done")
    return errSecSuccess
  }

  private func note(_ what: String) {
    let line = Data((what + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: log) {
      handle.seekToEndOfFile()
      handle.write(line)
      try? handle.close()
    } else {
      try? line.write(to: log)
    }
  }
}
