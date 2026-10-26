public struct BrowserState: Sendable, Equatable {
  public var settings: Settings
  public var downloads: [Download]

  public init(settings: Settings = .defaults, downloads: [Download] = []) {
    self.settings = settings
    self.downloads = downloads
  }
}
