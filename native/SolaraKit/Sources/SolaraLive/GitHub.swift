import Foundation

public enum GitHubQueries {
  static let prFields = """

      ... on PullRequest {
        id number title url isDraft updatedAt createdAt
        headRefName baseRefName mergeable reviewDecision
        additions deletions changedFiles
        repository { nameWithOwner }
        author { login avatarUrl(size: 64) }
        comments { totalCount }
        reviewThreads(first: 50) { nodes { isResolved } }
        commits(last: 1) {
          nodes { commit { statusCheckRollup { state contexts(first: 60) { nodes {
            __typename
            ... on CheckRun { name status conclusion detailsUrl }
            ... on StatusContext { context state targetUrl }
          } } } } }
        }
      }
    """

  public static let search = """
    query LiveFolder($authored: String!, $review: String!, $direct: String!) {
      viewer { login name avatarUrl(size: 64) }
      authored: search(query: $authored, type: ISSUE, first: 50) { nodes { ... on PullRequest { id } } }
      review: search(query: $review, type: ISSUE, first: 50) { nodes { ... on PullRequest { id } } }
      direct: search(query: $direct, type: ISSUE, first: 50) { nodes { ... on PullRequest { id } } }
    }
    """

  public static let details = "query LiveFolderDetails($ids: [ID!]!) { nodes(ids: $ids) { \(prFields) ... on PullRequest { state } } }"

  public static let detailsPage = 10

  public static let variables: [String: String] = [
    "authored": "is:pr is:open author:@me archived:false sort:updated-desc",
    "review": "is:pr is:open review-requested:@me archived:false sort:updated-desc",
    "direct": "is:pr is:open user-review-requested:@me archived:false",
  ]

  public static let state = """
    query LiveFolderGone($ids: [ID!]!) {
      nodes(ids: $ids) { ... on PullRequest { id state } }
    }
    """

  public static let viewer = "query { viewer { login name avatarUrl(size: 64) } }"
}

public enum RawCheck: Codable, Sendable, Equatable {
  case checkRun(name: String, status: String, conclusion: String?, detailsUrl: String?)
  case statusContext(context: String, state: String, targetUrl: String?)

  enum CodingKeys: String, CodingKey {
    case __typename, name, status, conclusion, detailsUrl, context, state, targetUrl
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if try c.decode(String.self, forKey: .__typename) == "StatusContext" {
      self = .statusContext(
        context: try c.decode(String.self, forKey: .context), state: try c.decode(String.self, forKey: .state),
        targetUrl: try c.decodeIfPresent(String.self, forKey: .targetUrl))
    } else {
      self = .checkRun(
        name: try c.decode(String.self, forKey: .name), status: try c.decode(String.self, forKey: .status),
        conclusion: try c.decodeIfPresent(String.self, forKey: .conclusion), detailsUrl: try c.decodeIfPresent(String.self, forKey: .detailsUrl))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .checkRun(let name, let status, let conclusion, let detailsUrl):
      try c.encode("CheckRun", forKey: .__typename)
      try c.encode(name, forKey: .name)
      try c.encode(status, forKey: .status)
      try c.encode(conclusion, forKey: .conclusion)
      try c.encode(detailsUrl, forKey: .detailsUrl)
    case .statusContext(let context, let state, let targetUrl):
      try c.encode("StatusContext", forKey: .__typename)
      try c.encode(context, forKey: .context)
      try c.encode(state, forKey: .state)
      try c.encode(targetUrl, forKey: .targetUrl)
    }
  }
}

public struct RawPR: Codable, Sendable, Equatable {
  public struct Repository: Codable, Sendable, Equatable { public var nameWithOwner: String }
  public struct Author: Codable, Sendable, Equatable {
    public var login: String
    public var avatarUrl: String
  }
  public struct Count: Codable, Sendable, Equatable { public var totalCount: Int }
  public struct Thread: Codable, Sendable, Equatable { public var isResolved: Bool }
  public struct Threads: Codable, Sendable, Equatable { public var nodes: [Thread] }
  public struct Contexts: Codable, Sendable, Equatable { public var nodes: [RawCheck] }
  public struct Rollup: Codable, Sendable, Equatable {
    public var state: String
    public var contexts: Contexts
  }
  public struct Commit: Codable, Sendable, Equatable {
    public var statusCheckRollup: Rollup?
    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(statusCheckRollup, forKey: .statusCheckRollup)
    }
  }
  public struct CommitNode: Codable, Sendable, Equatable { public var commit: Commit }
  public struct Commits: Codable, Sendable, Equatable { public var nodes: [CommitNode] }

  public var id: String
  public var state: String?
  public var number: Int
  public var title: String
  public var url: String
  public var isDraft: Bool
  public var updatedAt: String
  public var createdAt: String?
  public var headRefName: String
  public var baseRefName: String
  public var mergeable: String
  public var reviewDecision: String?
  public var additions: Int
  public var deletions: Int
  public var changedFiles: Int
  public var repository: Repository
  public var author: Author?
  public var comments: Count
  public var reviewThreads: Threads?
  public var commits: Commits

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encodeIfPresent(state, forKey: .state)
    try c.encode(number, forKey: .number)
    try c.encode(title, forKey: .title)
    try c.encode(url, forKey: .url)
    try c.encode(isDraft, forKey: .isDraft)
    try c.encode(updatedAt, forKey: .updatedAt)
    try c.encodeIfPresent(createdAt, forKey: .createdAt)
    try c.encode(headRefName, forKey: .headRefName)
    try c.encode(baseRefName, forKey: .baseRefName)
    try c.encode(mergeable, forKey: .mergeable)
    try c.encode(reviewDecision, forKey: .reviewDecision)
    try c.encode(additions, forKey: .additions)
    try c.encode(deletions, forKey: .deletions)
    try c.encode(changedFiles, forKey: .changedFiles)
    try c.encode(repository, forKey: .repository)
    try c.encode(author, forKey: .author)
    try c.encode(comments, forKey: .comments)
    try c.encodeIfPresent(reviewThreads, forKey: .reviewThreads)
    try c.encode(commits, forKey: .commits)
  }
}

public enum GithubNode: Codable, Sendable, Equatable {
  case pr(RawPR)
  case id(String)
  case empty

  enum Keys: String, CodingKey { case id, number }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    if c.contains(.number) {
      self = .pr(try RawPR(from: decoder))
    } else if let id = try c.decodeIfPresent(String.self, forKey: .id) {
      self = .id(id)
    } else {
      self = .empty
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .pr(let pr): try pr.encode(to: encoder)
    case .id(let id):
      var c = encoder.container(keyedBy: Keys.self)
      try c.encode(id, forKey: .id)
    case .empty:
      _ = encoder.container(keyedBy: Keys.self)
    }
  }

  public var nodeId: String? {
    switch self {
    case .pr(let pr): pr.id
    case .id(let id): id
    case .empty: nil
    }
  }

  public var pullRequest: RawPR? {
    if case .pr(let pr) = self { return pr }
    return nil
  }
}

public struct GithubViewer: Codable, Sendable, Equatable {
  public var login: String
  public var name: String?
  public var avatarUrl: String

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(login, forKey: .login)
    try c.encode(name, forKey: .name)
    try c.encode(avatarUrl, forKey: .avatarUrl)
  }
}

public struct GithubNodes: Codable, Sendable, Equatable {
  public var nodes: [GithubNode]
  public init(nodes: [GithubNode]) { self.nodes = nodes }
}

public enum GraphqlPathElement: Codable, Sendable, Equatable {
  case key(String)
  case index(Int)

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let i = try? c.decode(Int.self) { self = .index(i) } else { self = .key(try c.decode(String.self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .key(let k): try c.encode(k)
    case .index(let i): try c.encode(i)
    }
  }
}

public struct GraphqlError: Codable, Sendable, Equatable {
  public var type: String?
  public var message: String
  public var path: [GraphqlPathElement]?

  public init(type: String? = nil, message: String, path: [GraphqlPathElement]? = nil) {
    self.type = type
    self.message = message
    self.path = path
  }
}

public struct GithubResponse: Codable, Sendable, Equatable {
  public struct Payload: Codable, Sendable, Equatable {
    public var viewer: GithubViewer
    public var authored: GithubNodes
    public var review: GithubNodes
    public var direct: GithubNodes
  }

  public var data: Payload?
  public var errors: [GraphqlError]?

  public init(data: Payload?, errors: [GraphqlError]? = nil) {
    self.data = data
    self.errors = errors
  }
}

public struct DetailsResponse: Codable, Sendable, Equatable {
  public struct Payload: Codable, Sendable, Equatable {
    public var nodes: [RawPR?]?
    public init(nodes: [RawPR?]?) { self.nodes = nodes }
  }

  public var data: Payload?
  public var errors: [GraphqlError]?

  public init(data: Payload?, errors: [GraphqlError]? = nil) {
    self.data = data
    self.errors = errors
  }
}

public enum GitHub {
  public static func checkState(_ check: RawCheck) -> CheckState {
    switch check {
    case .statusContext(_, let state, _):
      if state == "SUCCESS" { return .success }
      if state == "FAILURE" || state == "ERROR" { return .failure }
      return .pending
    case .checkRun(_, let status, let conclusion, _):
      if status != "COMPLETED" { return status == "IN_PROGRESS" ? .pending : .queued }
      switch conclusion {
      case "SUCCESS": return .success
      case "NEUTRAL", "SKIPPED", "STALE": return .neutral
      default: return .failure
      }
    }
  }

  static func mapPR(_ raw: RawPR, _ section: PullRequestSection) -> LiveItem {
    let rollup = raw.commits.nodes.first?.commit.statusCheckRollup
    let checks = (rollup?.contexts.nodes ?? []).map { check -> PullRequestCheck in
      switch check {
      case .checkRun(let name, _, _, let url): PullRequestCheck(name: name, state: checkState(check), url: url)
      case .statusContext(let context, _, let url): PullRequestCheck(name: context, state: checkState(check), url: url)
      }
    }
    let review: ReviewDecision? =
      switch raw.reviewDecision {
      case "APPROVED": .approved
      case "CHANGES_REQUESTED": .changesRequested
      case "REVIEW_REQUIRED": .required
      default: nil
      }
    let pr = PullRequestInfo(
      number: raw.number, repo: raw.repository.nameWithOwner, author: raw.author?.login ?? "ghost", authorAvatar: raw.author?.avatarUrl,
      draft: raw.isDraft, headRef: raw.headRefName, baseRef: raw.baseRefName, review: review,
      mergeable: raw.mergeable == "CONFLICTING" ? .conflicting : raw.mergeable == "MERGEABLE" ? .mergeable : .unknown,
      checks: checks, comments: raw.comments.totalCount, unresolvedThreads: (raw.reviewThreads?.nodes ?? []).filter { !$0.isResolved }.count,
      additions: raw.additions, deletions: raw.deletions, changedFiles: raw.changedFiles)
    return LiveItem(
      id: "github:\(raw.id)", source: .github, url: raw.url, title: raw.title, subtitle: "\(raw.repository.nameWithOwner) #\(raw.number)",
      icon: nil, updatedAt: JS.dateParse(raw.updatedAt), section: section, pr: pr)
  }

  public static func detailIds(_ json: GithubResponse, filters: LiveFilters) -> [String] {
    guard let data = json.data else { return [] }
    var sections: [GithubNodes] = []
    if filters.authored { sections.append(data.authored) }
    if filters.reviewRequests { sections.append(data.review) }
    return sections.flatMap { $0.nodes.compactMap { node in node.nodeId.flatMap { $0.isEmpty ? nil : $0 } } }.uniqued()
  }

  public static func detailNodes(_ ids: [String], _ response: DetailsResponse) throws -> [RawPR] {
    let errors = response.errors ?? []
    if let limited = errors.first(where: { $0.type == "RATE_LIMITED" }) { throw LiveError(.rateLimited, limited.message) }
    func fail(_ error: GraphqlError? = nil) -> LiveError {
      LiveError(.other, (error ?? errors.first)?.message ?? "Missing pull request details")
    }
    guard let nodes = response.data?.nodes, nodes.count == ids.count else { throw fail() }
    var out: [RawPR] = []
    for (i, node) in nodes.enumerated() {
      if let node {
        out.append(node)
        continue
      }
      let error = errors.first { e in
        guard let path = e.path, path.count >= 2 else { return false }
        return path[0] == .key("nodes") && path[1] == .index(i)
      }
      if error?.type == "NOT_FOUND" || error?.type == "FORBIDDEN" { continue }
      throw fail(error)
    }
    return out
  }

  public static func withDetails(_ json: GithubResponse, _ details: [RawPR?]) -> GithubResponse {
    guard var data = json.data else { return json }
    var byId: [String: RawPR] = [:]
    for d in details { if let d, d.state == "OPEN" { byId[d.id] = d } }
    func fill(_ nodes: [GithubNode]) -> GithubNodes {
      GithubNodes(nodes: nodes.compactMap { n in n.nodeId.flatMap { byId[$0] }.map(GithubNode.pr) })
    }
    data.authored = fill(data.authored.nodes)
    data.review = fill(data.review.nodes)
    var out = json
    out.data = data
    return out
  }

  public static func mapGithub(_ json: GithubResponse, filters: LiveFilters) -> [LiveItem] {
    guard let data = json.data else { return [] }
    let direct = Set(data.direct.nodes.map { $0.nodeId ?? "" })
    var out: [LiveItem] = []
    var seen = Set<String>()
    if filters.authored {
      for n in data.authored.nodes {
        if let pr = n.pullRequest, seen.insert(pr.id).inserted { out.append(mapPR(pr, .authored)) }
      }
    }
    if filters.reviewRequests {
      for n in data.review.nodes {
        if let pr = n.pullRequest, seen.insert(pr.id).inserted { out.append(mapPR(pr, direct.contains(pr.id) ? .review : .team)) }
      }
    }
    return withStacks(out)
  }

  public static func withStacks(_ items: [LiveItem]) -> [LiveItem] {
    var byHead: [String: LiveItem] = [:]
    for it in items { if let pr = it.pr { byHead["\(pr.repo):\(pr.headRef)"] = it } }
    func parent(_ it: LiveItem) -> LiveItem? {
      guard let pr = it.pr else { return nil }
      return byHead["\(pr.repo):\(pr.baseRef)"]
    }
    func bottomOf(_ it: LiveItem) -> LiveItem {
      var cur = it
      var visited = Set<String>()
      var p = parent(cur)
      while let next = p, !visited.contains(next.id) {
        visited.insert(cur.id)
        cur = next
        p = parent(cur)
      }
      return cur
    }
    var stackOrder: [String] = []
    var stacks: [String: [LiveItem]] = [:]
    for it in items where it.pr != nil {
      let bottom = bottomOf(it)
      if stacks[bottom.id] == nil { stackOrder.append(bottom.id) }
      stacks[bottom.id, default: []].append(it)
    }
    var info: [String: PullRequestStack] = [:]
    for bottomId in stackOrder {
      let members = stacks[bottomId]!
      if members.count < 2 { continue }
      func depth(_ it: LiveItem) -> Int {
        var d = 1
        var p = parent(it)
        while let next = p, d <= members.count {
          d += 1
          p = parent(next)
        }
        return d
      }
      let ordered = members.stableSorted { a, b in
        let da = depth(a), db = depth(b)
        return da != db ? da < db : a.pr!.number < b.pr!.number
      }
      for (i, it) in ordered.enumerated() { info[it.id] = PullRequestStack(id: "stack:\(bottomId)", position: i + 1, size: ordered.count) }
    }
    return items.map { it in
      guard let stack = info[it.id], var pr = it.pr else { return it }
      pr.stack = stack
      var out = it
      out.pr = pr
      return out
    }
  }

  public struct CheckSummary: Sendable, Equatable, Codable {
    public enum Tone: String, Sendable, Codable { case success, failure, pending, neutral }
    public struct Counts: Sendable, Equatable, Codable {
      public var success: Int
      public var failure: Int
      public var pending: Int
    }
    public var text: String
    public var tone: Tone
    public var counts: Counts
  }

  public static func summarizeChecks(_ checks: [PullRequestCheck]) -> CheckSummary? {
    if checks.isEmpty { return nil }
    let failure = checks.filter { $0.state == .failure }.count
    let pending = checks.filter { $0.state == .pending || $0.state == .queued }.count
    let queued = checks.filter { $0.state == .queued }.count
    let success = checks.count - failure - pending
    let counts = CheckSummary.Counts(success: success, failure: failure, pending: pending)
    if failure > 0 { return CheckSummary(text: failure == 1 ? "1 check is failing" : "\(failure) checks are failing", tone: .failure, counts: counts) }
    if queued > 0, queued == pending, !checks.contains(where: { $0.state == .success }) {
      return CheckSummary(text: "Checks are queued", tone: .pending, counts: counts)
    }
    if pending > 0 { return CheckSummary(text: "Some checks haven't completed yet", tone: .pending, counts: counts) }
    return CheckSummary(text: "All checks have passed", tone: .success, counts: counts)
  }

  public enum Badge: String, Sendable, Codable { case conflict, failing, changesRequested, pending, approved, passed }

  public static func prBadge(_ pr: PullRequestInfo) -> Badge? {
    if pr.mergeable == .conflicting { return .conflict }
    let summary = summarizeChecks(pr.checks)
    if summary?.tone == .failure { return .failing }
    if pr.review == .changesRequested { return .changesRequested }
    if summary?.tone == .pending { return .pending }
    if pr.review == .approved { return .approved }
    if summary?.tone == .success { return .passed }
    return nil
  }
}
