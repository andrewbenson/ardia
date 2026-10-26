import Foundation

public struct LiveSource: Sendable {
  public typealias Fetch = @Sendable (LiveEngine, LiveFolder) async throws -> [LiveItem]
  public typealias ResolveGone = @Sendable (LiveEngine, [LiveItem]) async throws -> [String: CompletionState]

  public let id: LiveSourceId
  public let name: String
  public let kind: LiveFolderKind
  public let site: String
  public var fetch: Fetch
  public var resolveGone: ResolveGone?

  public init(id: LiveSourceId, name: String, kind: LiveFolderKind, site: String, fetch: @escaping Fetch, resolveGone: ResolveGone? = nil) {
    self.id = id
    self.name = name
    self.kind = kind
    self.site = site
    self.fetch = fetch
    self.resolveGone = resolveGone
  }
}

struct GoogleTokens: Codable, Sendable {
  var access_token: String
  var refresh_token: String
  var expires_at: Double
  var client_secret: String
}

struct GraphqlEnvelope: Decodable {
  var hasData: Bool
  var errors: [GraphqlError]?

  enum CodingKeys: String, CodingKey { case data, errors }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    hasData = c.contains(.data) ? !(try c.decodeNil(forKey: .data)) : false
    errors = try? c.decodeIfPresent([GraphqlError].self, forKey: .errors)
  }
}

struct GithubStateResponse: Decodable {
  struct Node: Decodable {
    var id: String
    var state: String
  }
  struct Payload: Decodable { var nodes: [Node?] }
  var data: Payload?
}

struct GithubViewerResponse: Decodable {
  struct Payload: Decodable { var viewer: GithubViewer? }
  var data: Payload?
}

struct BitbucketPage: Decodable { var values: [BitbucketPR] }
struct BitbucketState: Decodable { var state: String? }

struct BitbucketMe: Decodable {
  struct Href: Decodable { var href: String }
  struct Links: Decodable { var avatar: Href? }
  var account_id: String
  var display_name: String
  var links: Links?
}

struct ConfluenceMe: Decodable {
  var accountId: String
  var displayName: String
}

struct GoogleTokenResponse: Decodable {
  var access_token: String
  var refresh_token: String?
  var expires_in: Double
}

struct DriveAbout: Decodable {
  struct User: Decodable {
    var displayName: String
    var emailAddress: String
    var photoLink: String?
  }
  var user: User?
}

struct DeviceCode: Decodable {
  var device_code: String
  var user_code: String
  var verification_uri: String
  var expires_in: Double
  var interval: Double
}

struct DeviceToken: Decodable {
  var access_token: String?
  var error: String?
  var interval: Double?
}

extension LiveSource {
  public static let names: [LiveSourceId: String] = [
    .github: "GitHub", .bitbucket: "Bitbucket", .notion: "Notion", .confluence: "Confluence", .gdrive: "Google Drive",
  ]

  public static let sites: [LiveSourceId: String] = [
    .github: "https://github.com", .bitbucket: "https://bitbucket.org", .notion: "https://www.notion.so",
    .confluence: "https://www.atlassian.com", .gdrive: "https://drive.google.com",
  ]

  static let bitbucketStateBatch = 10

  static func notionHeaders(_ token: String) -> [String: String] {
    ["Authorization": "Bearer \(token)", "Notion-Version": "2022-06-28", "Content-Type": "application/json"]
  }

  public static let standard: [LiveSourceId: LiveSource] = [
    .github: github, .bitbucket: bitbucket, .notion: notion, .confluence: confluence, .gdrive: gdrive,
  ]

  static let github = LiveSource(
    id: .github, name: "GitHub", kind: .pullRequests, site: "https://github.com",
    fetch: { engine, folder in
      let token = try await engine.secret(.github)
      let json = try await engine.githubGraphql(GithubResponse.self, token: token, query: GitHubQueries.search, variables: GitHubQueries.variables)
      let ids = GitHub.detailIds(json, filters: folder.filters)
      let size = GitHubQueries.detailsPage
      let pages = stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
      @Sendable func page(_ ids: [String]) async throws -> [RawPR] {
        try GitHub.detailNodes(ids, try await engine.githubGraphql(DetailsResponse.self, token: token, query: GitHubQueries.details, variables: ["ids": ids]))
      }
      let details = try await withThrowingTaskGroup(of: (Int, [RawPR]).self) { group in
        for (i, ids) in pages.enumerated() {
          group.addTask {
            do {
              return (i, try await page(ids))
            } catch let error as LiveError where error.kind == .other || error.kind == .network {
              return (i, try await page(ids))
            }
          }
        }
        var out: [(Int, [RawPR])] = []
        for try await result in group { out.append(result) }
        return out.sorted { $0.0 < $1.0 }.flatMap(\.1)
      }
      return GitHub.mapGithub(GitHub.withDetails(json, details), filters: folder.filters)
    },
    resolveGone: { engine, items in
      let prs = items.filter { $0.source == .github }
      if prs.isEmpty { return [:] }
      let token = try await engine.secret(.github)
      let ids = prs.map { String($0.id.dropFirst("github:".count)) }
      let json = try await engine.githubGraphql(GithubStateResponse.self, token: token, query: GitHubQueries.state, variables: ["ids": ids])
      var out: [String: CompletionState] = [:]
      for case let n? in json.data?.nodes ?? [] {
        guard let item = prs.first(where: { $0.id == "github:\(n.id)" }) else { continue }
        if n.state == "MERGED" {
          out[item.id] = .merged
        } else if n.state == "CLOSED" {
          out[item.id] = .closed
        } else if item.section == .review || item.section == .team {
          out[item.id] = .reviewed
        }
      }
      return out
    })

  static let bitbucket = LiveSource(
    id: .bitbucket, name: "Bitbucket", kind: .pullRequests, site: "https://bitbucket.org",
    fetch: { engine, folder in
      if !folder.filters.authored { return [] }
      let auth = try await engine.bitbucketAuth()
      guard let me = await engine.state.accounts[.bitbucket] else { throw LiveError(.signedOut, "Not signed in") }
      let base = engine.endpoints.bitbucket
      let page = try await engine.requester.json(
        BitbucketPage.self,
        LiveHTTPRequest(url: "\(base)/pullrequests/\(JS.encodeURIComponent(me.login))?state=OPEN&pagelen=50", headers: ["Authorization": auth]))
      return await withTaskGroup(of: (Int, LiveItem).self) { group in
        for (i, pr) in page.values.enumerated() {
          group.addTask {
            let repo = pr.destination.repository.full_name
            let statuses = try? await engine.requester.json(
              BitbucketStatuses.self,
              LiveHTTPRequest(url: "\(base)/repositories/\(repo)/pullrequests/\(pr.id)/statuses?pagelen=50", headers: ["Authorization": auth]))
            return (i, Documents.mapBitbucket(pr, statuses: statuses))
          }
        }
        var out: [(Int, LiveItem)] = []
        for await result in group { out.append(result) }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
      }
    },
    resolveGone: { engine, items in
      let auth = try await engine.bitbucketAuth()
      let base = engine.endpoints.bitbucket
      let prs = items.compactMap { it in it.pr.map { (id: it.id, repo: $0.repo, number: $0.number) } }
      var out: [String: CompletionState] = [:]
      for start in stride(from: 0, to: prs.count, by: bitbucketStateBatch) {
        let batch = prs[start..<min(start + bitbucketStateBatch, prs.count)]
        let states = await withTaskGroup(of: (String, String?).self) { group in
          for pr in batch {
            group.addTask {
              let state = try? await engine.requester.json(
                BitbucketState.self, LiveHTTPRequest(url: "\(base)/repositories/\(pr.repo)/pullrequests/\(pr.number)", headers: ["Authorization": auth]))
              return (pr.id, state?.state)
            }
          }
          var out: [(String, String?)] = []
          for await result in group { out.append(result) }
          return out
        }
        for (id, state) in states {
          if state == "MERGED" {
            out[id] = .merged
          } else if state == "DECLINED" || state == "SUPERSEDED" {
            out[id] = .closed
          }
        }
      }
      return out
    })

  static let notion = LiveSource(
    id: .notion, name: "Notion", kind: .documents, site: "https://www.notion.so",
    fetch: { engine, _ in
      let token = try await engine.secret(.notion)
      let base = engine.endpoints.notion
      async let pages = engine.requester.json(
        NotionSearch.self,
        LiveHTTPRequest(method: "POST", url: "\(base)/search", headers: notionHeaders(token), body: Data(Documents.notionSearchBody.utf8)))
      async let users = try? engine.requester.json(NotionUsers.self, LiveHTTPRequest(url: "\(base)/users?page_size=100", headers: notionHeaders(token)))
      let (found, people) = try await (pages, users)
      return Documents.mapNotion(found, users: people, workspace: await engine.state.accounts[.notion]?.name)
    })

  static let confluence = LiveSource(
    id: .confluence, name: "Confluence", kind: .documents, site: "https://www.atlassian.com",
    fetch: { engine, _ in
      let config = await engine.state.config
      if config.confluenceSite.isEmpty { throw LiveError(.notConfigured, "No Confluence site") }
      let auth = LiveNet.basic(config.confluenceEmail, try await engine.secret(.confluence))
      let url =
        "\(engine.endpoints.confluence(config.confluenceSite))/wiki/rest/api/content/search?limit=30&expand=space,history.lastUpdated&cql=\(JS.encodeURIComponent(Documents.confluenceCQL))"
      return Documents.mapConfluence(
        try await engine.requester.json(ConfluenceSearch.self, LiveHTTPRequest(url: url, headers: ["Authorization": auth])), site: config.confluenceSite)
    })

  static let gdrive = LiveSource(
    id: .gdrive, name: "Google Drive", kind: .documents, site: "https://drive.google.com",
    fetch: { engine, _ in
      let token = try await engine.googleAccessToken()
      let query = Documents.driveQuery.map { "\($0.0)=\(JS.encodeURIComponent($0.1))" }.joined(separator: "&")
      return Documents.mapDrive(
        try await engine.requester.json(DriveFiles.self, LiveHTTPRequest(url: "\(engine.endpoints.drive)/files?\(query)", headers: ["Authorization": "Bearer \(token)"])))
    })
}
