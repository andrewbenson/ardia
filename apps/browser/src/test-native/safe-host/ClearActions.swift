import Foundation

enum ArdiaCoreHost {
  static var safeMode = false
}
final class Services {
  var calls: [[String]] = []
  func clearHistory(profileId: String, since: Date?) { calls.append(["history", profileId, since == nil ? "all" : "range"]) }
  func pruneProfileFavicons(profileId: String) { calls.append(["favicons", profileId]) }
  func clearBrowsingData(engineProfile: String, kinds: [BrowsingDataKind], since: Date?) async {
    calls.append(["browsing", engineProfile] + kinds.map(\.rawValue))
  }
  func clearSiteData(profile: String, origin: String) async -> ClearSiteDataResult {
    calls.append(["site", profile, origin])
    return ClearSiteDataResult(cookies: 2, storage: true)
  }
}
final class Store {
  func engineProfile(_ id: String) -> String { id == "default" ? "" : id }
}

__PRODUCTION__

var results: [[String: Any]] = []
for safe in [true, false] {
  ArdiaCoreHost.safeMode = safe
  let services = Services()
  let profiles = Profiles(services: services, safeMode: safe)
  await profiles.clearData(profileId: "work", range: .all, history: true, siteData: true)
  await profiles.clearData(profileId: "default", range: .hour, history: false, siteData: true)
  let privacy = Privacy(services: services)
  await privacy.clearData()
  results.append(["safe": safe, "calls": services.calls, "status": privacy.status])
}
let data = try JSONSerialization.data(withJSONObject: results)
print(String(data: data, encoding: .utf8)!)
