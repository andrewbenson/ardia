import Foundation

public enum LiveSourceId: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable, Comparable {
  case github, notion, gdrive

  public static func < (a: LiveSourceId, b: LiveSourceId) -> Bool {
    allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
  }
}

public enum LiveFolderKind: String, Codable, Sendable, CaseIterable {
  case pullRequests, documents
}

public struct LiveFilters: Codable, Sendable, Equatable {
  public var authored: Bool
  public var reviewRequests: Bool

  public init(authored: Bool = true, reviewRequests: Bool = true) {
    self.authored = authored
    self.reviewRequests = reviewRequests
  }
}

public struct LiveFolder: Codable, Sendable, Equatable {
  public var id: String
  public var profileId: String
  public var kind: LiveFolderKind
  public var name: String
  public var icon: String?
  public var collapsed: Bool
  public var sources: [LiveSourceId]
  public var filters: LiveFilters
  public var groupStacks: Bool
  public var showCompleted: Bool
  public var createdAt: Double
  public var after: String??

  public init(
    id: String, profileId: String, kind: LiveFolderKind, name: String, icon: String? = nil, collapsed: Bool = false,
    sources: [LiveSourceId], filters: LiveFilters = LiveFilters(), groupStacks: Bool = true, showCompleted: Bool = true,
    createdAt: Double, after: String?? = .none
  ) {
    self.id = id
    self.profileId = profileId
    self.kind = kind
    self.name = name
    self.icon = icon
    self.collapsed = collapsed
    self.sources = sources
    self.filters = filters
    self.groupStacks = groupStacks
    self.showCompleted = showCompleted
    self.createdAt = createdAt
    self.after = after
  }

  enum CodingKeys: String, CodingKey {
    case id, profileId, kind, name, icon, collapsed, sources, filters, groupStacks, showCompleted, createdAt, after
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    profileId = try c.decode(String.self, forKey: .profileId)
    kind = try c.decode(LiveFolderKind.self, forKey: .kind)
    name = try c.decode(String.self, forKey: .name)
    icon = try c.decodeIfPresent(String.self, forKey: .icon)
    collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    sources = (try? c.decodeIfPresent([String].self, forKey: .sources))?.compactMap(LiveSourceId.init(rawValue:)) ?? []
    filters = try c.decodeIfPresent(LiveFilters.self, forKey: .filters) ?? LiveFilters()
    groupStacks = try c.decodeIfPresent(Bool.self, forKey: .groupStacks) ?? true
    showCompleted = try c.decodeIfPresent(Bool.self, forKey: .showCompleted) ?? true
    createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
    if c.contains(.after) {
      after = try c.decodeNil(forKey: .after) ? .some(nil) : .some(try c.decode(String.self, forKey: .after))
    } else {
      after = .none
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(profileId, forKey: .profileId)
    try c.encode(kind, forKey: .kind)
    try c.encode(name, forKey: .name)
    try c.encode(icon, forKey: .icon)
    try c.encode(collapsed, forKey: .collapsed)
    try c.encode(sources, forKey: .sources)
    try c.encode(filters, forKey: .filters)
    try c.encode(groupStacks, forKey: .groupStacks)
    try c.encode(showCompleted, forKey: .showCompleted)
    try c.encode(createdAt, forKey: .createdAt)
    if case .some(let anchor) = after { try c.encode(anchor, forKey: .after) }
  }
}

public enum PullRequestSection: String, Codable, Sendable, CaseIterable {
  case authored, review, team
}

public enum CheckState: String, Codable, Sendable {
  case success, failure, pending, queued, neutral
}

public struct PullRequestCheck: Codable, Sendable, Equatable {
  public var name: String
  public var state: CheckState
  public var url: String?

  public init(name: String, state: CheckState, url: String?) {
    self.name = name
    self.state = state
    self.url = url
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(state, forKey: .state)
    try c.encode(url, forKey: .url)
  }
}

public enum ReviewDecision: String, Codable, Sendable {
  case approved, changesRequested, required
}

public enum Mergeable: String, Codable, Sendable {
  case mergeable, conflicting, unknown
}

public struct PullRequestStack: Codable, Sendable, Equatable {
  public var id: String
  public var position: Int
  public var size: Int

  public init(id: String, position: Int, size: Int) {
    self.id = id
    self.position = position
    self.size = size
  }
}

public struct PullRequestInfo: Codable, Sendable, Equatable {
  public var number: Int
  public var repo: String
  public var author: String
  public var authorAvatar: String?
  public var draft: Bool
  public var headRef: String
  public var baseRef: String
  public var review: ReviewDecision?
  public var mergeable: Mergeable
  public var checks: [PullRequestCheck]
  public var comments: Int
  public var unresolvedThreads: Int
  public var additions: Int
  public var deletions: Int
  public var changedFiles: Int
  public var stack: PullRequestStack?

  public init(
    number: Int, repo: String, author: String = "", authorAvatar: String? = nil, draft: Bool = false, headRef: String,
    baseRef: String, review: ReviewDecision? = nil, mergeable: Mergeable = .unknown, checks: [PullRequestCheck] = [],
    comments: Int = 0, unresolvedThreads: Int = 0, additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0,
    stack: PullRequestStack? = nil
  ) {
    self.number = number
    self.repo = repo
    self.author = author
    self.authorAvatar = authorAvatar
    self.draft = draft
    self.headRef = headRef
    self.baseRef = baseRef
    self.review = review
    self.mergeable = mergeable
    self.checks = checks
    self.comments = comments
    self.unresolvedThreads = unresolvedThreads
    self.additions = additions
    self.deletions = deletions
    self.changedFiles = changedFiles
    self.stack = stack
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(number, forKey: .number)
    try c.encode(repo, forKey: .repo)
    try c.encode(author, forKey: .author)
    try c.encode(authorAvatar, forKey: .authorAvatar)
    try c.encode(draft, forKey: .draft)
    try c.encode(headRef, forKey: .headRef)
    try c.encode(baseRef, forKey: .baseRef)
    try c.encode(review, forKey: .review)
    try c.encode(mergeable, forKey: .mergeable)
    try c.encode(checks, forKey: .checks)
    try c.encode(comments, forKey: .comments)
    try c.encode(unresolvedThreads, forKey: .unresolvedThreads)
    try c.encode(additions, forKey: .additions)
    try c.encode(deletions, forKey: .deletions)
    try c.encode(changedFiles, forKey: .changedFiles)
    try c.encodeIfPresent(stack, forKey: .stack)
  }
}

public struct DocumentInfo: Codable, Sendable, Equatable {
  public var kind: String
  public var editedBy: String?
  public var place: String?

  public init(kind: String, editedBy: String?, place: String?) {
    self.kind = kind
    self.editedBy = editedBy
    self.place = place
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kind, forKey: .kind)
    try c.encode(editedBy, forKey: .editedBy)
    try c.encode(place, forKey: .place)
  }
}

public struct LiveItem: Codable, Sendable, Equatable {
  public var id: String
  public var source: LiveSourceId
  public var url: String
  public var title: String
  public var subtitle: String
  public var icon: String?
  public var updatedAt: Double
  public var section: PullRequestSection?
  public var pr: PullRequestInfo?
  public var doc: DocumentInfo?

  public init(
    id: String, source: LiveSourceId, url: String, title: String, subtitle: String, icon: String? = nil,
    updatedAt: Double, section: PullRequestSection? = nil, pr: PullRequestInfo? = nil, doc: DocumentInfo? = nil
  ) {
    self.id = id
    self.source = source
    self.url = url
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.updatedAt = updatedAt
    self.section = section
    self.pr = pr
    self.doc = doc
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(source, forKey: .source)
    try c.encode(url, forKey: .url)
    try c.encode(title, forKey: .title)
    try c.encode(subtitle, forKey: .subtitle)
    try c.encode(icon, forKey: .icon)
    try c.encode(updatedAt, forKey: .updatedAt)
    try c.encodeIfPresent(section, forKey: .section)
    try c.encodeIfPresent(pr, forKey: .pr)
    try c.encodeIfPresent(doc, forKey: .doc)
  }
}

public enum CompletionState: String, Codable, Sendable {
  case merged, closed, reviewed
}

public struct CompletedItem: Codable, Sendable, Equatable {
  public var item: LiveItem
  public var state: CompletionState
  public var at: Double

  public init(item: LiveItem, state: CompletionState, at: Double) {
    self.item = item
    self.state = state
    self.at = at
  }
}

public enum LiveErrorKind: String, Codable, Sendable, CaseIterable {
  case signedOut, sso, rateLimited, network, notConfigured, other
}

public struct LiveError: Error, Sendable, Equatable, CustomStringConvertible {
  public var kind: LiveErrorKind
  public var message: String

  public init(_ kind: LiveErrorKind, _ message: String) {
    self.kind = kind
    self.message = message
  }

  public var description: String { message }
}

public struct FolderError: Codable, Sendable, Equatable {
  public var kind: LiveErrorKind
  public var message: String
  public var source: LiveSourceId

  public init(kind: LiveErrorKind, message: String, source: LiveSourceId) {
    self.kind = kind
    self.message = message
    self.source = source
  }
}

public struct FolderStatus: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable {
    case initializing, idle, updating, error
  }

  public var state: State
  public var lastFetch: Double?
  public var error: FolderError?

  public init(state: State, lastFetch: Double? = nil, error: FolderError? = nil) {
    self.state = state
    self.lastFetch = lastFetch
    self.error = error
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(state, forKey: .state)
    try c.encode(lastFetch, forKey: .lastFetch)
    try c.encode(error, forKey: .error)
  }
}

public struct LiveAccount: Codable, Sendable, Equatable {
  public var login: String
  public var name: String?
  public var avatar: String?
  public var connectedAt: Double

  public init(login: String, name: String?, avatar: String?, connectedAt: Double) {
    self.login = login
    self.name = name
    self.avatar = avatar
    self.connectedAt = connectedAt
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(login, forKey: .login)
    try c.encode(name, forKey: .name)
    try c.encode(avatar, forKey: .avatar)
    try c.encode(connectedAt, forKey: .connectedAt)
  }
}

public struct LiveConfig: Codable, Sendable, Equatable {
  public var githubClientId: String
  public var googleClientId: String
  public var extra: [String: LiveAnyJSON] = [:]

  enum CodingKeys: String, CodingKey, CaseIterable {
    case githubClientId, googleClientId
  }

  public static let defaults = LiveConfig(githubClientId: "", googleClientId: "")

  public init(githubClientId: String, googleClientId: String) {
    self.githubClientId = githubClientId
    self.googleClientId = googleClientId
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = LiveConfig.defaults
    githubClientId = (try? c.decodeIfPresent(String.self, forKey: .githubClientId)) ?? d.githubClientId
    googleClientId = (try? c.decodeIfPresent(String.self, forKey: .googleClientId)) ?? d.googleClientId
    extra = UnknownKeys.read(decoder, known: CodingKeys.allCases.map(\.rawValue) + LiveRetiredSource.configKeys)
  }

  public func encode(to encoder: Encoder) throws {
    try UnknownKeys.write(extra, to: encoder)
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(githubClientId, forKey: .githubClientId)
    try c.encode(googleClientId, forKey: .googleClientId)
  }
}

public enum AlertCondition: String, Codable, Sendable {
  case always, activeOnly
}

public struct CalendarSettings: Codable, Sendable, Equatable {
  public var alertLead: String
  public var alertCondition: AlertCondition
  public var showPreview: Bool
  public var showTimeToNext: Bool
  public var hiddenCalendarIds: [String]
  public var prompted: Bool
  public var extra: [String: LiveAnyJSON] = [:]

  enum CodingKeys: String, CodingKey, CaseIterable {
    case alertLead, alertCondition, showPreview, showTimeToNext, hiddenCalendarIds, prompted
  }

  public static let defaults = CalendarSettings(
    alertLead: "1", alertCondition: .always, showPreview: true, showTimeToNext: true, hiddenCalendarIds: [], prompted: false)

  public init(alertLead: String, alertCondition: AlertCondition, showPreview: Bool, showTimeToNext: Bool, hiddenCalendarIds: [String], prompted: Bool) {
    self.alertLead = alertLead
    self.alertCondition = alertCondition
    self.showPreview = showPreview
    self.showTimeToNext = showTimeToNext
    self.hiddenCalendarIds = hiddenCalendarIds
    self.prompted = prompted
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = CalendarSettings.defaults
    alertLead = (try? c.decodeIfPresent(String.self, forKey: .alertLead)) ?? d.alertLead
    alertCondition = (try? c.decodeIfPresent(AlertCondition.self, forKey: .alertCondition)) ?? d.alertCondition
    showPreview = (try? c.decodeIfPresent(Bool.self, forKey: .showPreview)) ?? d.showPreview
    showTimeToNext = (try? c.decodeIfPresent(Bool.self, forKey: .showTimeToNext)) ?? d.showTimeToNext
    hiddenCalendarIds = (try? c.decodeIfPresent([String].self, forKey: .hiddenCalendarIds)) ?? d.hiddenCalendarIds
    prompted = (try? c.decodeIfPresent(Bool.self, forKey: .prompted)) ?? d.prompted
    extra = UnknownKeys.read(decoder, known: CodingKeys.allCases.map(\.rawValue))
  }

  public func encode(to encoder: Encoder) throws {
    try UnknownKeys.write(extra, to: encoder)
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(alertLead, forKey: .alertLead)
    try c.encode(alertCondition, forKey: .alertCondition)
    try c.encode(showPreview, forKey: .showPreview)
    try c.encode(showTimeToNext, forKey: .showTimeToNext)
    try c.encode(hiddenCalendarIds, forKey: .hiddenCalendarIds)
    try c.encode(prompted, forKey: .prompted)
  }
}

public struct MeetingGroup: Codable, Sendable, Equatable {
  public var groupId: String
  public var callTabId: String
  public var occurrence: String?
  public var title: String
  public var start: Double?
  public var end: Double?
  public var endedAt: Double?

  public init(groupId: String, callTabId: String, occurrence: String?, title: String, start: Double?, end: Double?, endedAt: Double?) {
    self.groupId = groupId
    self.callTabId = callTabId
    self.occurrence = occurrence
    self.title = title
    self.start = start
    self.end = end
    self.endedAt = endedAt
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(groupId, forKey: .groupId)
    try c.encode(callTabId, forKey: .callTabId)
    try c.encode(occurrence, forKey: .occurrence)
    try c.encode(title, forKey: .title)
    try c.encode(start, forKey: .start)
    try c.encode(end, forKey: .end)
    try c.encode(endedAt, forKey: .endedAt)
  }
}
