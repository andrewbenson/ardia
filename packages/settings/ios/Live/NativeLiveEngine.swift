import ArdiaShell
import Foundation
import SolaraLive

private enum NativeLiveShadowUnavailable: Error {
  case readOnly
}

private struct NativeLiveDocuments: LiveDocumentStore {
  func read(_ name: String) -> String? { DocumentStore.read(name) }
  func write(_ name: String, _ text: String) throws { throw NativeLiveShadowUnavailable.readOnly }
}

private struct NativeLiveSecrets: LiveSecretStore {
  func secret(account: String) async -> String? { KeychainModule.readSecret(account) }
  func setSecret(_ secret: String, account: String) async {}
  func deleteSecret(account: String) async {}
}

private struct NativeLiveHTTP: LiveHTTPClient {
  func send(_ request: LiveHTTPRequest) async throws -> LiveHTTPResponse { throw NativeLiveShadowUnavailable.readOnly }
}

private struct NativeLiveCalendar: LiveCalendarProvider {
  func authorization() async -> CalendarAuthorization { .notDetermined }
  func requestAccess() async -> Bool { false }
  func calendars() async throws -> [SystemCalendar] { [] }
  func events(start: Double, end: Double, calendarIds: [String]) async throws -> [CalendarEvent] { [] }
}

private struct NativeLiveAuth: LiveAuthPresenter {
  func authorize(url: String, redirectPrefix: String) async throws -> String { throw NativeLiveShadowUnavailable.readOnly }
}

private struct NativeLiveNotifier: LiveNotifier {
  func post(_ notification: LiveNotification) async {}
  func remove(ids: [String]) async {}
}

final class NativeLiveEngine: @unchecked Sendable {
  static let shared = NativeLiveEngine()

  private let shadow: LiveShadow

  private init() {
    #if DEBUG
    let mockBase = ProcessInfo.processInfo.environment["ARDIA_LIVE_MOCK"]
    #else
    let mockBase: String? = nil
    #endif
    shadow = LiveShadow(effects: LiveEffects(
      http: NativeLiveHTTP(), secrets: NativeLiveSecrets(), calendar: NativeLiveCalendar(), auth: NativeLiveAuth(),
      notifier: NativeLiveNotifier(), documents: NativeLiveDocuments(), environment: LiveEnvironment(mockBase: mockBase)))
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
