import Foundation
import Security

let args = CommandLine.arguments
guard args.count >= 5 else {
  FileHandle.standardError.write(Data("usage: aclcheck add|exists|read|update <keychain path> <service> <account> [secret]\n".utf8))
  exit(64)
}
let command = args[1], path = args[2], service = args[3], account = args[4]
var keychainRef: SecKeychain?
guard SecKeychainOpen(path, &keychainRef) == errSecSuccess, let keychain = keychainRef else {
  print("open failed")
  exit(65)
}

var query: [String: Any] {
  [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecUseDataProtectionKeychain as String: false,
  ]
}

func withoutInteraction<T>(_ body: () -> T) -> T {
  var allowed: DarwinBoolean = true
  let known = SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess
  SecKeychainSetUserInteractionAllowed(false)
  defer { if known { SecKeychainSetUserInteractionAllowed(allowed.boolValue) } }
  return body()
}

func probe() -> String {
  var probe = query
  probe[kSecMatchSearchList as String] = [keychain]
  probe[kSecReturnAttributes as String] = true
  probe[kSecMatchLimit as String] = kSecMatchLimitOne
  probe[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
  var result: CFTypeRef?
  let status = SecItemCopyMatching(probe as CFDictionary, &result)
  return "exists \(status)"
}

func lookup() -> String {
  var lookup = query
  lookup[kSecMatchSearchList as String] = [keychain]
  lookup[kSecReturnData as String] = true
  lookup[kSecMatchLimit as String] = kSecMatchLimitOne
  lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
  var result: CFTypeRef?
  let status = SecItemCopyMatching(lookup as CFDictionary, &result)
  let value = (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  return "read \(status) \(value)"
}

func addIfAbsent(_ secret: Data) -> String {
  var add = query
  add[kSecUseKeychain as String] = keychain
  add[kSecValueData as String] = secret
  return "add \(withoutInteraction { SecItemAdd(add as CFDictionary, nil) })"
}

func update(_ secret: Data) -> String {
  var match = query
  match[kSecMatchSearchList as String] = [keychain]
  return "update \(withoutInteraction { SecItemUpdate(match as CFDictionary, [kSecValueData as String: secret] as CFDictionary) })"
}

switch command {
case "add": print(addIfAbsent(Data(args[5].utf8)))
case "exists": print(withoutInteraction(probe))
case "read": print(withoutInteraction(lookup))
case "update": print(update(Data(args[5].utf8)))
default: exit(64)
}
