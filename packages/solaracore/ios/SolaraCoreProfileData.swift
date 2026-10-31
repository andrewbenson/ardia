import Foundation

enum SolaraCoreProfileData {
  typealias Done = ([String]) -> Void
  private typealias Step = (label: String, run: (@escaping (Bool) -> Void) -> Void)

  static func deleteDefault(_ done: @escaping Done) {
    guard !SolaraCoreHost.safeMode else { return done(["safe mode"]) }
    let steps: [Step] = [
      ("history, cookies and cache", { ok in
        SolaraCoreServices.clearBrowsingData(profile: "", types: ["history", "siteData", "cache", "downloads"], since: 0) { ok(true) }
      }),
      ("autocomplete entries", { ok in
        SolaraCoreServices.call("ac_browsing_data_clear", profile: "", args: ["types": ["formData", "siteSettings"]]) { ok($0["ok"] as? Bool == true) }
      }),
      ("passwords", deletePasswords),
      ("addresses", { ok in clearEach(list: { SolaraCoreServices.addresses(profile: "", completion: $0) }, key: "addresses", done: ok) {
        item, next in SolaraCoreServices.deleteAutofillEntry(item["id"] as? String ?? "", profile: "") { _ in next() }
      } }),
      ("cards", { ok in clearEach(list: { SolaraCoreServices.cards(profile: "", completion: $0) }, key: "cards", done: ok) {
        item, next in SolaraCoreServices.deleteAutofillEntry(item["id"] as? String ?? "", profile: "") { _ in next() }
      } }),
      ("extensions", { ok in clearEach(list: runningExtensions, key: "extensions", done: ok) {
        item, next in SolaraCoreServices.setExtension(item["id"] as? String ?? "", enabled: false, profile: "") { _ in next() }
      } }),
      ("site settings", resetSiteSettings),
      ("zoom levels", resetZoom),
    ]
    var remaining: [String] = []
    func run(_ i: Int) {
      guard i < steps.count else { return done(remaining) }
      steps[i].run { ok in
        if !ok { remaining.append(steps[i].label) }
        run(i + 1)
      }
    }
    run(0)
  }

  private static func deletePasswords(_ ok: @escaping (Bool) -> Void) {
    clearEach(list: { SolaraCoreServices.listPasswords(profile: "", completion: $0) }, key: "passwords", done: { deleted in
      SolaraCoreServices.neverSaveOrigins(profile: "") { result in
        let origins = result["origins"] as? [String] ?? []
        forEach(origins, { origin, next in SolaraCoreServices.allowSaving(profile: "", origin: origin) { _ in next() } }) {
          SolaraCoreServices.neverSaveOrigins(profile: "") { again in ok(deleted && (again["origins"] as? [String])?.isEmpty == true) }
        }
      }
    }) { item, next in
      SolaraCoreServices.deletePassword(profile: "", origin: item["origin"] as? String ?? "", username: item["username"] as? String ?? "") { _ in next() }
    }
  }

  private static func runningExtensions(_ completion: @escaping ([String: Any]) -> Void) {
    SolaraCoreServices.listExtensions(profile: "") { result in
      guard let all = result["extensions"] as? [[String: Any]] else { return completion(result) }
      completion(["extensions": all.filter { $0["mayModify"] as? Bool != false && $0["enabled"] as? Bool == true }])
    }
  }

  private static func resetSiteSettings(_ ok: @escaping (Bool) -> Void) {
    SolaraCoreServices.siteSettingsOrigins(profile: "") { origins in
      forEach(origins, { origin, next in
        SolaraCoreServices.call("ac_site_settings_reset", profile: "", args: ["origin": origin]) { _ in next() }
      }) {
        SolaraCoreServices.siteSettingsOrigins(profile: "") { left in ok(left.isEmpty) }
      }
    }
  }

  private static func resetZoom(_ ok: @escaping (Bool) -> Void) {
    SolaraCoreServices.zoomLevels(profile: "") { levels in
      for host in levels.keys { SolaraCoreServices.setZoom(1, profile: "", host: host) }
      func check(_ attempt: Int) {
        SolaraCoreServices.zoomLevels(profile: "") { left in
          if left.isEmpty || attempt >= 20 { return ok(left.isEmpty) }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check(attempt + 1) }
        }
      }
      check(0)
    }
  }

  private static func clearEach(
    list: @escaping (@escaping ([String: Any]) -> Void) -> Void, key: String, done: @escaping (Bool) -> Void,
    clear: @escaping ([String: Any], @escaping () -> Void) -> Void
  ) {
    list { result in
      guard let items = result[key] as? [[String: Any]] else { return done(false) }
      forEach(items, clear) {
        list { again in done((again[key] as? [Any])?.isEmpty == true) }
      }
    }
  }

  private static func forEach<T>(_ items: [T], _ body: @escaping (T, @escaping () -> Void) -> Void, then: @escaping () -> Void) {
    guard let first = items.first else { return then() }
    body(first) { forEach(Array(items.dropFirst()), body, then: then) }
  }
}
