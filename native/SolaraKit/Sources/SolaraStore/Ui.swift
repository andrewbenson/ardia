import SolaraModel

extension Session {
  public func setAppDark(_ dark: Bool) {
    guard state.ui.appDark != dark else { return }
    update { $0.ui.appDark = dark }
  }

  public func setFind(_ tabId: String, _ patch: TabUpdate) {
    guard state.tabs.contains(tabId) else { return }
    var find = state.find[tabId] ?? FindState()
    for (key, value) in patch.set { find.json[key] = value }
    for key in patch.unset { find.json.removeValue(forKey: key) }
    update { $0.find[tabId] = find }
  }
}
