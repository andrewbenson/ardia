import Foundation

public struct TabNavigationRequest: Equatable, Sendable {
  public var seq: Int
  public var url: String
  public var userInitiated: Bool

  public init(seq: Int, url: String, userInitiated: Bool = false) {
    self.seq = seq
    self.url = url
    self.userInitiated = userInitiated
  }
}

public struct TabNavigationReport: Equatable, Sendable {
  public var url: String
  public var title: String
  public var isLoading: Bool
  public var canGoBack: Bool
  public var canGoForward: Bool
  public var initialDocumentAccessed: Bool
  public var committedInitial: Bool?

  public init(url: String, title: String = "", isLoading: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false, initialDocumentAccessed: Bool = false, committedInitial: Bool? = nil) {
    self.url = url
    self.title = title
    self.isLoading = isLoading
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.initialDocumentAccessed = initialDocumentAccessed
    self.committedInitial = committedInitial
  }
}

public struct TabPageContext: Equatable, Sendable {
  public var navigationUrl: String?
  public var prewarmOnly: Bool
  public var openedByAdoption: Bool
  public var newTabShownUrl: String?

  public init(navigationUrl: String? = nil, prewarmOnly: Bool = false, openedByAdoption: Bool = false, newTabShownUrl: String? = nil) {
    self.navigationUrl = navigationUrl
    self.prewarmOnly = prewarmOnly
    self.openedByAdoption = openedByAdoption
    self.newTabShownUrl = newTabShownUrl
  }
}

public enum TabPageEffect: Equatable, Sendable {
  case load(String, userInitiated: Bool)
  case clearNewTabShown
  case adoptNavigation(String)
  case markLoading
  case keepNewTabShown(title: String)
  case backToNewTab
  case navigated(url: String, title: String, isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
  case leftPage(from: String, to: String)
}

public struct TabPageModel: Equatable, Sendable {
  public private(set) var pending: String?
  public private(set) var lastPage: String?
  private var adopted: String?
  private var arrived: Bool
  private var loadsOnCreate: Int?
  private let fromNewTab: Bool

  public init(navigation: TabNavigationRequest?, adoptedUrl: String?, handoffSeq: Int?, webkitWithoutHandoff: Bool, wasNewTab: Bool) {
    pending = navigation?.url ?? adoptedUrl
    arrived = handoffSeq != nil && handoffSeq == navigation?.seq
    loadsOnCreate = webkitWithoutHandoff ? navigation?.seq : nil
    fromNewTab = wasNewTab && adoptedUrl == nil
  }

  static func isBlank(_ url: String) -> Bool { url.isEmpty || url == "about:blank" }

  public static func pageKey(_ url: String) -> String {
    guard let hash = url.firstIndex(of: "#") else { return url }
    return String(url[..<hash])
  }

  public mutating func issued(_ navigation: TabNavigationRequest, newTabShown: Bool, startedEarly: Bool) -> [TabPageEffect] {
    if arrived {
      arrived = false
      return []
    }
    if navigation.url == adopted {
      adopted = nil
      return []
    }
    pending = navigation.url
    var effects: [TabPageEffect] = newTabShown ? [.clearNewTabShown] : []
    if loadsOnCreate == navigation.seq {
      loadsOnCreate = nil
      return effects
    }
    if startedEarly { return effects }
    effects.append(.load(navigation.url, userInitiated: navigation.userInitiated))
    return effects
  }

  public mutating func reported(_ report: TabNavigationReport, _ context: TabPageContext) -> [TabPageEffect] {
    let url = report.initialDocumentAccessed && report.committedInitial == true ? "about:blank" : report.url
    let untouched = report.committedInitial.map { $0 && !report.initialDocumentAccessed } ?? (report.url.isEmpty && !context.openedByAdoption)
    let target = pending ?? (lastPage == nil ? context.navigationUrl : nil)
    var effects: [TabPageEffect] = []
    if target == nil, context.prewarmOnly {
      if Self.isBlank(url) { return [] }
      adopted = url
      effects.append(.adoptNavigation(url))
    }
    if let target, Self.isBlank(url), !target.hasPrefix("about:"), untouched {
      return effects + [.markLoading]
    }
    pending = nil
    if let kept = context.newTabShownUrl {
      if url == kept { return effects + [.keepNewTabShown(title: report.title)] }
      effects.append(.clearNewTabShown)
    }
    if fromNewTab, !Self.isBlank(url) { effects.append(.backToNewTab) }
    effects.append(.navigated(url: url, title: report.title, isLoading: report.isLoading, canGoBack: report.canGoBack, canGoForward: report.canGoForward))
    if let last = lastPage, Self.pageKey(url) != last { effects.append(.leftPage(from: last, to: url)) }
    lastPage = Self.pageKey(url)
    return effects
  }

  public mutating func loadFailed() {
    pending = nil
  }
}
