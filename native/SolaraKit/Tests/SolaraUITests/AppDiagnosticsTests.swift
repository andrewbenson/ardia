import Foundation
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@Suite struct AppDiagnosticsTests {
  private func state(_ root: [String: Any]) throws -> BrowserState {
    let text = try #require(String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8))
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private func fixture() throws -> BrowserState {
    try state([
      "profileOrder": ["p", "q"], "windowOrder": ["w", "x", "i"],
      "profiles": ["p": ["id": "p", "name": "Personal"], "q": ["id": "q", "name": "Work"]],
      "tabs": [
        "a": ["id": "a", "windowId": "w", "profileId": "p", "url": "https://a.example/", "title": "A", "customTitle": "Mine"],
        "b": ["id": "b", "windowId": "x", "profileId": "p", "url": "about:blank", "title": "Blank"],
        "c": ["id": "c", "windowId": "i", "profileId": "p", "url": "https://secret.example/", "title": "Secret"],
      ],
      "windows": [
        "w": ["id": "w", "profileId": "p", "tabIds": ["a"], "activeTabIds": ["p": "a"]],
        "x": ["id": "x", "profileId": "p", "tabIds": ["b"], "activeTabIds": ["p": "b"]],
        "i": ["id": "i", "profileId": "p", "incognito": true, "tabIds": ["c"], "activeTabIds": ["p": "c"]],
      ],
    ])
  }

  private var app: AppFacts {
    AppFacts([
      "appName": "Solara", "appVersion": "0.1.0", "appBuild": "42", "configuration": "Debug", "osVersion": "27.0.0", "osBuild": "27A1",
      "arch": "arm64", "model": "Mac16,1", "memoryGB": 15.5, "bundleId": "com.hill.solara", "locale": "en_US",
      "feedbackURL": "https://github.com/andrewbenson/solara/issues/new?body=%s",
    ])
  }

  @Test func reportMatchesTheJavaScriptText() throws {
    let text = AppDiagnostics.report(
      app: app, chromiumVersion: "156.0.1", updates: UpdaterFacts(available: true, configured: true, automaticChecks: true, feedURL: nil),
      state: try fixture())
    #expect(text == """
      Solara 0.1.0 (42) — Debug
      Engine: ArdiaCore, Chromium 156.0.1
      macOS 27.0.0 (27A1), arm64, Mac16,1, 16 GB
      Bundle: com.hill.solara, locale en_US
      Windows: 2 (+1 incognito), tabs: 3, profiles: 2
      Updates: automatic checks on, feed none
      """)
  }

  @Test func updateLines() throws {
    let s = try fixture()
    let line = { (u: UpdaterFacts?) in AppDiagnostics.report(app: app, chromiumVersion: nil, updates: u, state: s).split(separator: "\n").last! }
    #expect(line(nil) == "Updates: not built in")
    #expect(line(UpdaterFacts(available: false, configured: true)) == "Updates: not built in")
    #expect(line(UpdaterFacts(available: true)) == "Updates: not set up for this build")
    #expect(line(UpdaterFacts(available: true, configured: true, feedURL: "https://f/appcast.xml")) == "Updates: automatic checks off, feed https://f/appcast.xml")
    #expect(AppDiagnostics.report(app: app, chromiumVersion: nil, updates: nil, state: s).contains("Engine: unavailable"))
  }

  @Test func encodesLikeEncodeURIComponent() {
    #expect(AppDiagnostics.encodeURIComponent("a b&c=d+e?f/g#h") == "a%20b%26c%3Dd%2Be%3Ff%2Fg%23h")
    #expect(AppDiagnostics.encodeURIComponent("-_.!~*'()") == "-_.!~*'()")
    #expect(AppDiagnostics.encodeURIComponent("é—\n$") == "%C3%A9%E2%80%94%0A%24")
  }

  @Test func feedbackOpensThePageWithTheReport() {
    let target = AppDiagnostics.feedback(report: "R & D", app: app)
    let body = AppDiagnostics.encodeURIComponent("What happened?\n\n\nWhat did you expect?\n\n\n---\nR & D")
    #expect(target == .page("https://github.com/andrewbenson/solara/issues/new?body=\(body)"))
  }

  @Test func feedbackFallsBackToMail() {
    var facts = app
    facts.feedbackURL = "javascript:alert(1)"
    facts.feedbackEmail = "me@example.com"
    guard case .mail(let draft, let body) = AppDiagnostics.feedback(report: "R", app: facts) else { Issue.record("expected mail"); return }
    #expect(draft == "mailto:me@example.com?subject=Solara%20Feedback&body=\(AppDiagnostics.encodeURIComponent(body))")
    facts.feedbackEmail = "me@example.com?cc=x"
    guard case .mail(let unsafe, _) = AppDiagnostics.feedback(report: "R", app: facts) else { Issue.record("expected mail"); return }
    #expect(unsafe.hasPrefix("mailto:?subject="))
  }

  @Test func handoffSkipsIncognitoAndRepeats() throws {
    var tracker = HandoffTracker()
    let s = try fixture()
    #expect(tracker.changes(s) == [
      HandoffActivity(windowId: "w", url: "https://a.example/", title: "Mine"),
      HandoffActivity(windowId: "x", url: nil, title: "Blank"),
      HandoffActivity(windowId: "i", url: nil, title: "Secret"),
    ])
    #expect(tracker.changes(s).isEmpty)
  }
}
