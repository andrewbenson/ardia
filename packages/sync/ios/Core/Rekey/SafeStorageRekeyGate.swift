import Foundation

public enum SafeStorageRekeyMode: Equatable {
  case real
  case test
  case off
}

public struct SafeStorageRekeyGate: Equatable {
  public let mode: SafeStorageRekeyMode
  public let userDataDir: URL
  public let refusal: String?

  public static func resolve(
    environment env: [String: String], chromeUsesRealKeychain: Bool, signedForDistribution: Bool,
    installedUserDataDir: URL, currentDirectory: String = FileManager.default.currentDirectoryPath
  ) -> SafeStorageRekeyGate {
    let scratch = env["ARDIA_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    let userDataDir = scratch.map { scratchUserDataDir($0, currentDirectory: currentDirectory) } ?? installedUserDataDir
    guard let test = env["ARDIA_TEST_REKEY"] else {
      return SafeStorageRekeyGate(mode: chromeUsesRealKeychain ? .real : .off, userDataDir: userDataDir, refusal: nil)
    }
    var missing: [String] = []
    if test != "1" { missing.append("ARDIA_TEST_REKEY isn't 1") }
    if scratch == nil { missing.append("ARDIA_DATA_DIR isn't set") }
    if env["ARDIA_TEST_KEYCHAIN"] != "file" { missing.append("ARDIA_TEST_KEYCHAIN isn't file") }
    if signedForDistribution { missing.append("the build is signed for distribution") }
    if chromeUsesRealKeychain { missing.append("Chrome runs on the real keychain") }
    guard missing.isEmpty else {
      return SafeStorageRekeyGate(mode: .off, userDataDir: userDataDir, refusal: "test re-key refused: " + missing.joined(separator: ", "))
    }
    return SafeStorageRekeyGate(mode: .test, userDataDir: userDataDir, refusal: nil)
  }

  static func scratchUserDataDir(_ dataDir: String, currentDirectory: String) -> URL {
    let absolute = dataDir.hasPrefix("/") ? dataDir : (currentDirectory as NSString).appendingPathComponent(dataDir)
    let standard = (absolute as NSString).standardizingPath
    return URL(fileURLWithPath: (standard as NSString).appendingPathComponent("Chromium"), isDirectory: true)
  }

  public func keychain(product: String, environment env: [String: String]) -> RekeyKeychain? {
    switch mode {
    case .real:
      return RekeyLoginKeychain(service: "\(product) Safe Storage", account: product)
    case .test:
      return RekeyFileKeychain(
        file: userDataDir.appendingPathComponent("Test Safe Storage Key"),
        log: userDataDir.appendingPathComponent("Test Safe Storage Log"),
        failure: RekeyFileKeychain.failure(named: env["ARDIA_TEST_KEYCHAIN_FAIL"]))
    case .off:
      return nil
    }
  }
}
