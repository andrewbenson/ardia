import Foundation

public enum ConnectedAccounts {
  public static func keychainService(info: [String: Any]?) -> String {
    let product = info?["CFBundleName"] as? String ?? "Ardia"
    let dev = info?["ACDevBuild"] as? String == "YES"
    return "\(product)\(dev ? " Dev" : "") Connected Accounts"
  }
}
