import SolaraModel

extension Session {
  func run(_ listener: SettleListener, prev: BrowserState) {
    let s = state
    switch listener {
    case .forgetClosedPrivateWindows:
      if s.windows.changed(from: prev.windows), let next = forgetClosedPrivateWindows(s) { set(next) }
    case .settleNesting:
      if !s.groups.changed(from: prev.groups) && s.windows.values.allSatisfy({ $0.tabIds == prev.windows[$0.id]?.tabIds }) { return }
      if let settled = Groups.settleNesting(s) {
        var next = state
        next.groups = settled.groups
        next.windows = settled.windows
        set(next)
      }
    case .livePinTable:
      if !s.pinChoices.changed(from: prev.pinChoices) && !s.pinSync.changed(from: prev.pinSync) && !s.tabs.changed(from: prev.tabs)
        && !s.groups.changed(from: prev.groups) && !s.parkedPins.changed(from: prev.parkedPins) && !s.profiles.changed(from: prev.profiles)
      {
        return
      }
      let pinChoices = livePinTable(s.pinChoices, s)
      let pinSync = livePinTable(s.pinSync, s)
      if pinChoices.changed(from: s.pinChoices) || pinSync.changed(from: s.pinSync) {
        var next = state
        next.pinChoices = pinChoices
        next.pinSync = pinSync
        set(next)
      }
    case .settlePeeks:
      if let next = settlePeeks(s, prev) { set(next) }
    case .mirror:
      if mirroring > 3 { return }
      let homes = settlePinHomes(s, prev)
      var start = s
      if let homes { start.tabs = homes }
      let unshared = unshareTabs(start, prev) ?? pagesIntoSplits(start, prev) ?? (homes != nil ? start : nil)
      let base = unshared ?? start
      let shared = settleSharedPins(base, prev) ?? unshared
      let settled = settleTileFolders(shared ?? base, prev) ?? shared
      let pinned = mirrorPins(settled ?? base, prev) ?? settled
      guard let next = mirrorTabs(pinned ?? base, prev) ?? pinned else { return }
      mirroring += 1
      defer { mirroring -= 1 }
      set(next)
    case .noteOrderChoices:
      if let next = noteOrderChoices(s, prev) { set(next) }
    case .forgetClosedIncognito:
      if !s.windows.changed(from: prev.windows) { return }
      for w in prev.windows.values {
        if !w.incognito || s.windows[w.id] != nil { continue }
        let session = s.privateSession(w.profileId)
        if s.windows.values.contains(where: { $0.incognito && s.privateSession($0.profileId) == session }) { continue }
        for d in s.downloads where downloadSession(s, d) == session && d.isDownloading { emit(.cancelDownload(id: d.id)) }
        forgetDownloads(w.profileId)
        if let session { emit(.endPrivateSession(session: session)) }
      }
    }
  }
}
