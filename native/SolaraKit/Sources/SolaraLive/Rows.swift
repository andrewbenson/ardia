import Foundation

public enum FolderRow: Sendable, Equatable, Encodable {
  case item(key: String, item: LiveItem)
  case stack(key: String, id: String, repo: String, items: [LiveItem])
  case header(key: String, title: String)
  case more(key: String, section: String, count: Int)

  public var key: String {
    switch self {
    case .item(let key, _), .stack(let key, _, _, _), .header(let key, _), .more(let key, _, _): key
    }
  }

  enum CodingKeys: String, CodingKey { case kind, key, item, id, repo, items, title, section, count }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kind, forKey: .kind)
    try c.encode(key, forKey: .key)
    switch self {
    case .item(_, let item):
      try c.encode(item, forKey: .item)
    case .stack(_, let id, let repo, let items):
      try c.encode(id, forKey: .id)
      try c.encode(repo, forKey: .repo)
      try c.encode(items, forKey: .items)
    case .header(_, let title):
      try c.encode(title, forKey: .title)
    case .more(_, let section, let count):
      try c.encode(section, forKey: .section)
      try c.encode(count, forKey: .count)
    }
  }

  public var kind: String {
    switch self {
    case .item: "item"
    case .stack: "stack"
    case .header: "header"
    case .more: "more"
    }
  }
}

public enum LiveTabPlace: String, Sendable {
  case row, stray, hidden
}

public enum LiveRows {
  public static let pageSize = 8

  public static func sectionTitle(_ section: PullRequestSection) -> String? {
    switch section {
    case .authored: nil
    case .review: "Review Requests"
    case .team: "Team Review Requests"
    }
  }

  public static func liveTabPlace(_ itemId: String, shown: Set<String>, hidden: Set<String>) -> LiveTabPlace {
    shown.contains(itemId) ? .row : hidden.contains(itemId) ? .hidden : .stray
  }

  public static func folderRows(
    id: String, kind: LiveFolderKind, groupStacks: Bool, items: [LiveItem], showAll: [String: Bool], page: Int = pageSize
  ) -> [FolderRow] {
    let sections: [(String, String?, [LiveItem])] =
      kind == .pullRequests
      ? PullRequestSection.allCases.map { s in (s.rawValue, sectionTitle(s), items.filter { ($0.section ?? .authored) == s }) }
      : [("documents", nil, items)]
    var rows: [FolderRow] = []
    for (section, title, members) in sections {
      if members.isEmpty { continue }
      if let title { rows.append(.header(key: "h:\(section)", title: title)) }
      var entries: [FolderRow] = []
      var stacked = Set<String>()
      for it in members {
        guard let stack = groupStacks ? it.pr?.stack : nil else {
          entries.append(.item(key: it.id, item: it))
          continue
        }
        if !stacked.insert(stack.id).inserted { continue }
        let inStack = members.filter { $0.pr?.stack?.id == stack.id }.stableSorted { $0.pr!.stack!.position < $1.pr!.stack!.position }
        entries.append(.stack(key: stack.id, id: stack.id, repo: it.pr!.repo, items: inStack))
      }
      let all = showAll["\(id):\(section)"] ?? false
      rows.append(contentsOf: all ? entries : Array(entries.prefix(page)))
      if !all, entries.count > page { rows.append(.more(key: "m:\(section)", section: section, count: entries.count - page)) }
    }
    return rows
  }

  public static func folderRows(_ folder: LiveFolder, items: [LiveItem], showAll: [String: Bool], page: Int = pageSize) -> [FolderRow] {
    folderRows(id: folder.id, kind: folder.kind, groupStacks: folder.groupStacks, items: items, showAll: showAll, page: page)
  }
}
