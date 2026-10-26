import Foundation

extension LiveEngine {
  func visibleCalendarIds(_ calendars: [SystemCalendar]) -> [String] {
    let hidden = Set(state.calendar.hiddenCalendarIds)
    return calendars.filter { !hidden.contains($0.id) }.map(\.id)
  }

  @discardableResult
  public func refreshCalendar() -> Task<Void, Never> {
    if let running = calendarInflight { return running }
    let task = Task {
      await self.runCalendarRefresh()
      self.calendarInflight = nil
    }
    calendarInflight = task
    return task
  }

  func startOfToday() -> Double {
    let now = Date(timeIntervalSince1970: effects.clock.now() / 1000)
    return (Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000).rounded()
  }

  func runCalendarRefresh() async {
    setCalendarData { $0.loading = true }
    defer { setCalendarData { $0.loading = false } }
    do {
      if effects.environment.calendarFixture {
        let text = effects.documents.read(CalendarFixture.documentName) ?? #"{"calendars":[],"events":[]}"#
        let fixture = try LiveJSON.decode(CalendarFixture.self, from: text).resolved(launchedAt: launchedAt)
        let ids = Set(visibleCalendarIds(fixture.calendars))
        let now = effects.clock.now()
        setCalendarData {
          $0.access = .fixture
          $0.calendars = fixture.calendars
          $0.events = fixture.events.filter { ids.contains($0.calendarId) }
          $0.error = nil
          $0.lastFetch = now
        }
        return
      }
      let access = await effects.calendar.authorization()
      if access != .fullAccess {
        setCalendarData {
          $0.access = access
          $0.calendars = []
          $0.events = []
          $0.error = nil
        }
        return
      }
      let calendars = try await effects.calendar.calendars()
      let ids = visibleCalendarIds(calendars)
      let start = startOfToday()
      let events = ids.isEmpty ? [] : try await effects.calendar.events(start: start, end: effects.clock.now() + CalendarFixture.horizonMs, calendarIds: ids)
      let now = effects.clock.now()
      setCalendarData {
        $0.access = access
        $0.calendars = calendars
        $0.events = events.stableSorted { $0.start < $1.start }
        $0.error = nil
        $0.lastFetch = now
      }
    } catch {
      let message = (error as? LiveError)?.message ?? String(describing: error)
      setCalendarData { $0.error = message }
    }
  }

  public func connectCalendar() async -> Bool {
    if effects.environment.calendarFixture {
      await refreshCalendar().value
      return true
    }
    let granted = await effects.calendar.requestAccess()
    await refreshCalendar().value
    return granted
  }

  public func calendarChanged() { refreshCalendar() }

  public var calendarConnected: Bool { calendarData.connected }

  public func alertEvent(now: Double? = nil) -> CalendarEvent? {
    guard let lead = Meetings.alertLeads.first(where: { $0.value == state.calendar.alertLead })?.minutes else { return nil }
    return Meetings.dueAlerts(calendarData.events, now: now ?? effects.clock.now(), leadMinutes: lead, dismissed: Set(state.dismissedAlerts)).first
  }

  public func checkAlerts() async {
    let event = alertEvent()
    if event?.occurrence != meetingAlert?.occurrence {
      meetingAlert = event
      emit()
    }
    guard let event, !appActive, state.calendar.alertCondition == .always, !notified.contains(event.occurrence) else { return }
    notified.insert(event.occurrence)
    let link = Meetings.joinLink(event)
    let now = effects.clock.now()
    let when = Meetings.relativeTime(event.start, now: now)
    let lead = when == "Now" ? "Starting now" : event.start < now ? "Started \(when)" : "Starts \(when)"
    await effects.notifier.post(
      LiveNotification(
        id: "meeting:\(event.occurrence)", title: event.title.isEmpty ? "Untitled event" : event.title,
        body: lead + (link.map { " · \(Meetings.joinTitle($0.provider))" } ?? ""), data: ["meeting": event.occurrence]))
  }

  public func dismissAlert(_ event: CalendarEvent) async {
    mutate { $0.dismissAlert(event.occurrence) }
    await effects.notifier.remove(ids: ["meeting:\(event.occurrence)"])
    if meetingAlert?.occurrence == event.occurrence {
      meetingAlert = nil
      emit()
    }
    await checkAlerts()
  }

  public func offerAlertsForPinnedTab(url: String) -> Bool {
    guard Meetings.isCalendarUrl(url), !state.calendar.prompted else { return false }
    updateCalendarSettings(CalendarSettingsPatch(prompted: true))
    return true
  }

  public func answerAlertOffer(confirmed: Bool) async {
    if confirmed {
      _ = await connectCalendar()
    } else {
      updateCalendarSettings(CalendarSettingsPatch(alertLead: "never"))
    }
  }
}
