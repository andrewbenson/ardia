import Foundation

public struct NotionRichText: Codable, Sendable, Equatable {
  public var plain_text: String
}

public enum NotionIcon: Codable, Sendable, Equatable {
  case emoji(String)
  case external(String)
  case file(String)

  struct Link: Codable { var url: String }
  enum CodingKeys: String, CodingKey { case type, emoji, external, file }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "emoji": self = .emoji(try c.decode(String.self, forKey: .emoji))
    case "external": self = .external(try c.decode(Link.self, forKey: .external).url)
    default: self = .file(try c.decode(Link.self, forKey: .file).url)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .emoji(let e):
      try c.encode("emoji", forKey: .type)
      try c.encode(e, forKey: .emoji)
    case .external(let url):
      try c.encode("external", forKey: .type)
      try c.encode(Link(url: url), forKey: .external)
    case .file(let url):
      try c.encode("file", forKey: .type)
      try c.encode(Link(url: url), forKey: .file)
    }
  }

  var value: String {
    switch self {
    case .emoji(let v), .external(let v), .file(let v): v
    }
  }
}

public struct NotionProperty: Codable, Sendable, Equatable {
  public var type: String
  public var title: [NotionRichText]?
}

public struct NotionPage: Codable, Sendable, Equatable {
  public struct Editor: Codable, Sendable, Equatable { public var id: String }

  public var object: String
  public var id: String
  public var url: String
  public var archived: Bool?
  public var in_trash: Bool?
  public var last_edited_time: String
  public var last_edited_by: Editor?
  public var icon: NotionIcon??
  public var title: [NotionRichText]?
  public var properties: [String: NotionProperty]?

  enum CodingKeys: String, CodingKey {
    case object, id, url, archived, in_trash, last_edited_time, last_edited_by, icon, title, properties
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    object = try c.decode(String.self, forKey: .object)
    id = try c.decode(String.self, forKey: .id)
    url = try c.decode(String.self, forKey: .url)
    archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
    in_trash = try c.decodeIfPresent(Bool.self, forKey: .in_trash)
    last_edited_time = try c.decode(String.self, forKey: .last_edited_time)
    last_edited_by = try c.decodeIfPresent(Editor.self, forKey: .last_edited_by)
    if c.contains(.icon) {
      icon = try c.decodeNil(forKey: .icon) ? .some(nil) : .some(try c.decode(NotionIcon.self, forKey: .icon))
    } else {
      icon = .none
    }
    title = try c.decodeIfPresent([NotionRichText].self, forKey: .title)
    properties = try c.decodeIfPresent([String: NotionProperty].self, forKey: .properties)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(object, forKey: .object)
    try c.encode(id, forKey: .id)
    try c.encode(url, forKey: .url)
    try c.encodeIfPresent(archived, forKey: .archived)
    try c.encodeIfPresent(in_trash, forKey: .in_trash)
    try c.encode(last_edited_time, forKey: .last_edited_time)
    try c.encodeIfPresent(last_edited_by, forKey: .last_edited_by)
    if case .some(let icon) = icon { try c.encode(icon, forKey: .icon) }
    try c.encodeIfPresent(title, forKey: .title)
    try c.encodeIfPresent(properties, forKey: .properties)
  }
}

public struct NotionSearch: Codable, Sendable, Equatable {
  public var results: [NotionPage]
}

public struct NotionUsers: Codable, Sendable, Equatable {
  public struct User: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(name, forKey: .name)
    }
  }
  public var results: [User]
}

public struct NotionMe: Codable, Sendable, Equatable {
  public struct Bot: Codable, Sendable, Equatable { public var workspace_name: String? }
  public var object: String?
  public var id: String?
  public var name: String?
  public var type: String?
  public var bot: Bot?
}

public struct ConfluenceSearch: Codable, Sendable, Equatable {
  public struct Space: Codable, Sendable, Equatable {
    public var key: String
    public var name: String
  }
  public struct By: Codable, Sendable, Equatable { public var displayName: String }
  public struct LastUpdated: Codable, Sendable, Equatable {
    public var when: String
    public var by: By?
  }
  public struct History: Codable, Sendable, Equatable { public var lastUpdated: LastUpdated? }
  public struct Links: Codable, Sendable, Equatable { public var webui: String }
  public struct Result: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var title: String
    public var space: Space?
    public var history: History?
    public var _links: Links
  }
  public struct BaseLinks: Codable, Sendable, Equatable { public var base: String? }

  public var results: [Result]
  public var _links: BaseLinks?
}

public struct DriveFiles: Codable, Sendable, Equatable {
  public struct User: Codable, Sendable, Equatable { public var displayName: String }
  public struct File: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var webViewLink: String
    public var iconLink: String?
    public var modifiedTime: String
    public var lastModifyingUser: User?
  }
  public var files: [File]
}

public struct BitbucketPR: Codable, Sendable, Equatable {
  public struct Href: Codable, Sendable, Equatable { public var href: String }
  public struct AvatarLinks: Codable, Sendable, Equatable { public var avatar: Href? }
  public struct Author: Codable, Sendable, Equatable {
    public var display_name: String
    public var links: AvatarLinks?
  }
  public struct Branch: Codable, Sendable, Equatable { public var name: String }
  public struct Repository: Codable, Sendable, Equatable { public var full_name: String }
  public struct Source: Codable, Sendable, Equatable { public var branch: Branch }
  public struct Destination: Codable, Sendable, Equatable {
    public var branch: Branch
    public var repository: Repository
  }
  public struct Links: Codable, Sendable, Equatable { public var html: Href }
  public struct Participant: Codable, Sendable, Equatable {
    public var role: String
    public var state: String?
    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(role, forKey: .role)
      try c.encode(state, forKey: .state)
    }
  }

  public var id: Int
  public var title: String
  public var draft: Bool?
  public var updated_on: String
  public var comment_count: Int
  public var author: Author
  public var source: Source
  public var destination: Destination
  public var links: Links
  public var participants: [Participant]?
}

public struct BitbucketStatuses: Codable, Sendable, Equatable {
  public struct Status: Codable, Sendable, Equatable {
    public var state: String
    public var name: String
    public var url: String
  }
  public var values: [Status]
}

public enum Documents {
  public static let notionSearchBody = #"{"sort":{"direction":"descending","timestamp":"last_edited_time"},"page_size":30}"#

  static func notionTitle(_ p: NotionPage) -> String {
    let title = p.title ?? (p.properties ?? [:]).sorted { $0.key < $1.key }.first { $0.value.type == "title" }?.value.title ?? []
    let text = title.map(\.plain_text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "Untitled" : text
  }

  public static func mapNotion(_ json: NotionSearch, users: NotionUsers?, workspace: String?) -> [LiveItem] {
    var names: [String: String?] = [:]
    for u in users?.results ?? [] { names[u.id] = u.name }
    return json.results
      .filter { !($0.archived ?? false) && !($0.in_trash ?? false) }
      .map { p in
        let editedBy: String? = p.last_edited_by.flatMap { names[$0.id] ?? nil }
        return LiveItem(
          id: "notion:\(p.id)", source: .notion, url: p.url, title: notionTitle(p), subtitle: workspace ?? "Notion",
          icon: (p.icon ?? nil)?.value, updatedAt: JS.dateParse(p.last_edited_time),
          doc: DocumentInfo(kind: p.object == "database" ? "Database" : "Page", editedBy: editedBy, place: workspace))
      }
  }

  public static let confluenceCQL =
    "type=page AND (contributor=currentUser() OR creator=currentUser() OR watcher=currentUser()) ORDER BY lastmodified DESC"

  public static func mapConfluence(_ json: ConfluenceSearch, site: String) -> [LiveItem] {
    let base = json._links?.base ?? "\(site.hasSuffix("/") ? String(site.dropLast()) : site)/wiki"
    return json.results.map { r in
      LiveItem(
        id: "confluence:\(r.id)", source: .confluence, url: base + r._links.webui, title: r.title.isEmpty ? "Untitled" : r.title,
        subtitle: r.space?.name ?? "Confluence", icon: nil, updatedAt: JS.dateParse(r.history?.lastUpdated?.when ?? ""),
        doc: DocumentInfo(kind: "Page", editedBy: r.history?.lastUpdated?.by?.displayName, place: r.space?.name))
    }
  }

  public static let driveQuery: [(String, String)] = [
    ("q", "trashed = false and mimeType != 'application/vnd.google-apps.folder' and (viewedByMeTime > '1970-01-01T00:00:00Z' or 'me' in owners)"),
    ("orderBy", "modifiedTime desc"),
    ("pageSize", "30"),
    ("fields", "files(id,name,mimeType,webViewLink,iconLink,modifiedTime,lastModifyingUser(displayName))"),
  ]

  static let driveKinds: [String: String] = [
    "application/vnd.google-apps.document": "Document",
    "application/vnd.google-apps.spreadsheet": "Spreadsheet",
    "application/vnd.google-apps.presentation": "Presentation",
    "application/vnd.google-apps.form": "Form",
    "application/vnd.google-apps.drawing": "Drawing",
    "application/pdf": "PDF",
  ]

  public static func mapDrive(_ json: DriveFiles) -> [LiveItem] {
    json.files.map { f in
      LiveItem(
        id: "gdrive:\(f.id)", source: .gdrive, url: f.webViewLink, title: f.name.isEmpty ? "Untitled" : f.name,
        subtitle: driveKinds[f.mimeType] ?? "Google Drive", icon: nil, updatedAt: JS.dateParse(f.modifiedTime),
        doc: DocumentInfo(kind: driveKinds[f.mimeType] ?? "File", editedBy: f.lastModifyingUser?.displayName, place: nil))
    }
  }

  public static func mapBitbucket(_ pr: BitbucketPR, statuses: BitbucketStatuses?) -> LiveItem {
    let reviewers = (pr.participants ?? []).filter { $0.role == "REVIEWER" }
    let repo = pr.destination.repository.full_name
    let review: ReviewDecision? =
      reviewers.contains { $0.state == "changes_requested" } ? .changesRequested
      : reviewers.contains { $0.state == "approved" } ? .approved : reviewers.isEmpty ? nil : .required
    let checks = (statuses?.values ?? []).map { s in
      PullRequestCheck(
        name: s.name, state: s.state == "SUCCESSFUL" ? .success : s.state == "FAILED" ? .failure : s.state == "STOPPED" ? .neutral : .pending,
        url: s.url)
    }
    return LiveItem(
      id: "bitbucket:\(repo)#\(pr.id)", source: .bitbucket, url: pr.links.html.href, title: pr.title, subtitle: "\(repo) #\(pr.id)",
      icon: nil, updatedAt: JS.dateParse(pr.updated_on), section: .authored,
      pr: PullRequestInfo(
        number: pr.id, repo: repo, author: pr.author.display_name, authorAvatar: pr.author.links?.avatar?.href, draft: pr.draft ?? false,
        headRef: pr.source.branch.name, baseRef: pr.destination.branch.name, review: review, mergeable: .unknown, checks: checks,
        comments: pr.comment_count, unresolvedThreads: 0, additions: 0, deletions: 0, changedFiles: 0))
  }
}
