import Foundation

public enum ArdiaCoreSettingsBridge {
  public static let contentBlockerChanged = Notification.Name("ArdiaCoreContentBlockerChanged")

  public static func webKitExternalAppAllowances(profile: String) -> [[String: Any]] {
    WebKitHub.shared.externalAppAllowances(profile: profile)
  }

  public static func removeWebKitExternalAppAllowance(profile: String, origin: String, scheme: String) {
    WebKitHub.shared.removeExternalAppAllowance(profile: profile, origin: origin, scheme: scheme)
  }
}
