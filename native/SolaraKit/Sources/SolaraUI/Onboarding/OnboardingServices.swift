import AppKit
import Foundation
import SolaraModel

@MainActor
public protocol OnboardingServices: AnyObject {
  func readOnboardingDocument() -> String?
  func writeOnboardingDocument(_ json: String)
  func hasSessionDocument() -> Bool
  var startsOnFirstLaunch: Bool { get }
  func now() -> Double

  func resolveWindowId(_ windowId: String?) -> String?
  func windowTabLayout(_ windowId: String?) -> String
  func setWindowTabLayout(_ windowId: String, _ layout: String)
  func previewSettings(_ patch: JSONObject)
  func profileColor(_ windowId: String) -> ProfileColorValue?
  func isIncognito(_ windowId: String) -> Bool
  func setProfileColor(_ windowId: String, _ color: ProfileColorValue)

  func endToolTour()
  func startToolTour(_ windowId: String)

  func playIntroMusic(_ cues: IntroMusicCues, muted: Bool)
  func setIntroMusicMuted(_ muted: Bool)
  func stopIntroMusic(fade: Double)

  func fileExists(_ path: String) -> Bool
  func fileIcon(_ path: String, size: Int) async -> NSImage?
  var importAvailable: Bool { get }
  func openImport(_ browserId: String)

  var backgroundInstance: Bool { get }
  func isDefaultBrowser() async -> Bool
  func isInDock() async -> Bool
  func loginItemStatus() async -> LoginItemStatus
  func setAsDefaultBrowser() async -> Bool
  func setLaunchAtLogin(_ on: Bool) async
  func addToDock() async

  func appIcons(size: Int) async -> [OnboardingAppIcon]
  func currentAppIcon() async -> String?
  func setAppIcon(_ id: String) async

  func pinnedHosts(_ windowId: String) -> Set<String>
  func history(_ windowId: String) -> [OnboardingHistoryVisit]
  func openPinnedTabs(_ windowId: String, _ sites: [PinnableSite])

  func favicon(_ url: String) async -> NSImage?
}
