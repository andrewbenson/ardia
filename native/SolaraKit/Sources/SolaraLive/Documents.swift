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

}
