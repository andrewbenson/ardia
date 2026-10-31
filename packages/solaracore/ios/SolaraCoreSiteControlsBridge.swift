import Foundation

@MainActor
public enum SolaraCoreSiteControlsBridge {
  public static func webKitSettings(profile: String, origin: String) -> [String: [String: Any]] {
    WebKitHub.shared.sitePermissions(profile: profile, origin: origin)
  }

  public static func setWebKitPermission(profile: String, origin: String, kind: String, value: String) {
    WebKitHub.shared.setSitePermission(profile: profile, origin: origin, kind: kind, value: value)
  }
}
