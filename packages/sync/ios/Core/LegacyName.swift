public enum LegacyName {
  public static let bundleId = "com.netnyahoo.browser"
  public static let appFileName = "Netnyahoo.app"
  public static let appName = "Netnyahoo"
  public static let successorBundleId = "com.ardia.browser"

  public static func isSuccessor(_ bundleId: String?) -> Bool { bundleId?.lowercased() == successorBundleId }

  public static let syncMagic = "NNS1"
  public static let syncSalt = "netnyahoo-sync/v1"
  public static let syncFolderName = "Netnyahoo Sync"
}
