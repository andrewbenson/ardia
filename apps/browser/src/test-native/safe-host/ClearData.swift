import Foundation

enum ArdiaCoreHost {
  static var safeMode = false
}
let WKWebsiteDataTypeDiskCache = "disk"
let WKWebsiteDataTypeMemoryCache = "memory"
let WKWebsiteDataTypeFetchCache = "fetch"

struct Record {
  let displayName: String
}
struct Cookie {
  let domain: String
}
final class CookieStore {
  var reads = 0
  func getAllCookies(_ done: ([Cookie]) -> Void) {
    reads += 1
    done([".example.test", "example.test", "sub.example.test", "unrelated.test", "notexample.test"].map { Cookie(domain: $0) })
  }
}
final class WKWebsiteDataStore {
  static func allWebsiteDataTypes() -> Set<String> { ["cookies", "storage", "disk", "memory", "fetch"] }
  var removals: [[String: Any]] = []
  var fetches = 0
  let httpCookieStore = CookieStore()
  func removeData(ofTypes kinds: Set<String>, modifiedSince since: Date, completionHandler: () -> Void) {
    removals.append(["kinds": kinds.sorted(), "since": since.timeIntervalSince1970])
    completionHandler()
  }
  func fetchDataRecords(ofTypes kinds: Set<String>, completionHandler: ([Record]) -> Void) {
    fetches += 1
    completionHandler([".example.test", "example.test", "sub.example.test", "unrelated.test", "notexample.test"].map { Record(displayName: $0) })
  }
  func removeData(ofTypes kinds: Set<String>, for records: [Record], completionHandler: () -> Void) {
    removals.append(["kinds": kinds.sorted(), "records": records.map(\.displayName)])
    completionHandler()
  }
}
final class WebKitHub {
  static let siteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes().subtracting([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache])
  var rememberedPermissions = ["fixture|permission": true, "other|permission": true]
  var externalAllowances = ["fixture|allowance": true, "other|allowance": true]
  var storeLookups = 0
  let store = WKWebsiteDataStore()
  func storeKey(_ profile: String) -> String { profile }
  func dataStore(for profile: String) -> WKWebsiteDataStore {
    precondition(profile == "fixture")
    storeLookups += 1
    return store
  }

__PRODUCTION__
}

var results: [[String: Any]] = []
for safe in [true, false] {
  ArdiaCoreHost.safeMode = safe
  for types in [["siteData"], ["cache"], ["siteData", "cache"]] {
    let hub = WebKitHub()
    var callbacks = 0
    hub.clearBrowsingData(profile: "fixture", types: types, since: 123000) { callbacks += 1 }
    results.append(["safe": safe, "path": "browsing", "types": types, "callbacks": callbacks, "storeLookups": hub.storeLookups,
                    "removals": hub.store.removals, "permissions": hub.rememberedPermissions.keys.sorted(), "allowances": hub.externalAllowances.keys.sorted()])
  }
  let hub = WebKitHub()
  var callbacks = 0
  var reply: [String: Any] = [:]
  hub.clearSiteData(profile: "fixture", host: "SUB.EXAMPLE.TEST") { callbacks += 1; reply = $0 }
  results.append(["safe": safe, "path": "site", "callbacks": callbacks, "storeLookups": hub.storeLookups, "fetches": hub.store.fetches,
                  "cookieReads": hub.store.httpCookieStore.reads, "removals": hub.store.removals, "reply": reply])
}
let data = try JSONSerialization.data(withJSONObject: results)
print(String(data: data, encoding: .utf8)!)
