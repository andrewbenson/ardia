import ArdiaShell
import Foundation
import SolaraLive

private enum NativeLiveShadowUnavailable: Error {
  case readOnly
}

private struct NativeLiveDocuments: LiveDocumentStore {
  func read(_ name: String) -> String? { DocumentStore.read(name) }
  func readStatus(_ name: String) -> LiveDocumentRead {
    let result = DocumentStore.readResult(name)
    if let text = result["contents"] { return .contents(text) }
    if let failure = result["failure"] { return .failure(failure) }
    return .missing
  }
  func write(_ name: String, _ text: String) throws { throw NativeLiveShadowUnavailable.readOnly }
}

private struct ShadowLiveSecrets: LiveSecretStore {
  func secret(account: String) async -> String? { KeychainModule.readSecret(account) }
  func setSecret(_ secret: String, account: String) async -> Bool { false }
  func deleteSecret(account: String) async -> Bool { false }
}

private struct ShadowLiveHTTP: LiveHTTPClient {
  func send(_ request: LiveHTTPRequest) async throws -> LiveHTTPResponse { throw NativeLiveShadowUnavailable.readOnly }
}

private struct ShadowLiveCalendar: LiveCalendarProvider {
  func authorization() async -> CalendarAuthorization { .notDetermined }
  func requestAccess() async -> Bool { false }
  func calendars() async throws -> [SystemCalendar] { [] }
  func events(start: Double, end: Double, calendarIds: [String]) async throws -> [CalendarEvent] { [] }
}

private struct NativeLiveAuth: LiveAuthPresenter {
  func authorize(url: String, redirectPrefix: String) async throws -> String { throw NativeLiveShadowUnavailable.readOnly }
}

private struct ShadowLiveNotifier: LiveNotifier {
  func post(_ notification: LiveNotification) async {}
  func remove(ids: [String]) async {}
}

final class NativeLiveEngine: @unchecked Sendable {
  static let shared = NativeLiveEngine()

  private let shadow: LiveShadow

  private init() {
    #if DEBUG
    let mockBase = ProcessInfo.processInfo.environment["ARDIA_LIVE_MOCK"]
    let isolated = ProcessInfo.processInfo.environment["ARDIA_DATA_DIR"] != nil
    let fixture = ProcessInfo.processInfo.environment["ARDIA_CALENDAR_FIXTURE"] == "1"
    let separate = ProcessInfo.processInfo.environment["ARDIA_SLOW_TIMERS"] == "separate"
    #else
    let mockBase: String? = nil
    let isolated = false
    let fixture = false
    let separate = false
    #endif
    shadow = LiveShadow(effects: LiveEffects(
      http: ShadowLiveHTTP(), secrets: ShadowLiveSecrets(), calendar: ShadowLiveCalendar(), auth: NativeLiveAuth(),
      notifier: ShadowLiveNotifier(), documents: NativeLiveDocuments(), environment: LiveEnvironment(mockBase: mockBase, calendarFixture: fixture, isolatedDataDirectory: isolated, separateSlowTimers: separate)))
  }

  func reload() async { await shadow.reload() }

  #if DEBUG
  func devSnapshot() async -> [String: Any] {
    let state = await shadow.snapshot().live
    let folders: [[String: Any]] = state.folders.keys.sorted().map { id in
      [
        "id": id,
        "items": state.items[id]?.count ?? 0,
        "hidden": state.hidden[id]?.count ?? 0,
        "completed": state.completed[id]?.count ?? 0,
        "status": state.status[id]?.state.rawValue as Any? ?? NSNull(),
      ]
    }
    let calendar = state.calendar
    return [
      "folders": folders,
      "connectedSources": state.accounts.keys.map(\.rawValue).sorted(),
      "calendar": [
        "alertLead": calendar.alertLead,
        "alertCondition": calendar.alertCondition.rawValue,
        "showPreview": calendar.showPreview,
        "showTimeToNext": calendar.showTimeToNext,
        "hiddenCalendarIds": calendar.hiddenCalendarIds,
        "prompted": calendar.prompted,
      ],
    ]
  }
  #endif
}
