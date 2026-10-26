import Foundation

@testable import SolaraLive

final class MockServer: @unchecked Sendable {
  static let base = "http://mock"

  struct Model {
    var github: [String: Any]
    var prs: [String: [String: Any]]
    var state: [String: String] = [:]
    var approved = false
    var deviceResponses: [[String: Any]] = []
    var detailsError: (id: String, type: String)?
    var bitbucketState = "OPEN"
    var driveTokenValid = "mock-google-access"
  }

  let model: Locked<Model>

  init() {
    let github = try! JSONSerialization.jsonObject(with: Fixture.data("github.json")) as! [String: Any]
    let data = github["data"] as! [String: Any]
    var prs: [String: [String: Any]] = [:]
    for key in ["authored", "review"] {
      for n in (data[key] as! [String: Any])["nodes"] as! [[String: Any]] { prs[n["id"] as! String] = n }
    }
    model = Locked(Model(github: github, prs: prs))
  }

  func drop(_ id: String) {
    model.with { m in
      var data = m.github["data"] as! [String: Any]
      for key in ["authored", "review", "direct"] {
        var section = data[key] as! [String: Any]
        section["nodes"] = (section["nodes"] as! [[String: Any]]).filter { $0["id"] as? String != id }
        data[key] = section
      }
      m.github["data"] = data
    }
  }

  func merge(_ id: String) {
    drop(id)
    model.with { $0.state[id] = "MERGED" }
  }

  func load(_ name: String) -> Any { try! JSONSerialization.jsonObject(with: Fixture.data(name)) }

  var http: FakeHTTP { FakeHTTP { [self] request in self.respond(request) } }

  func respond(_ request: LiveHTTPRequest) -> LiveHTTPResponse {
    let components = URLComponents(string: request.url)!
    let p = components.path
    let auth = request.headers["Authorization"] ?? ""
    if p == "/github/login/device/code" {
      return json(["device_code": "mock-device", "user_code": "WDJB-MJHT", "verification_uri": "\(MockServer.base)/github/login/device", "expires_in": 900, "interval": 1])
    }
    if p == "/github/login/oauth/access_token" {
      return model.with { m in
        if !m.deviceResponses.isEmpty { return json(m.deviceResponses.removeFirst()) }
        return json(m.approved ? ["access_token": "mock-token", "token_type": "bearer"] : ["error": "authorization_pending"])
      }
    }
    if p == "/github/graphql" {
      if auth != "Bearer mock-token" { return json(["message": "Bad credentials"], status: 401) }
      let body = jsonObject(request.body)
      let query = body["query"] as? String ?? ""
      let variables = body["variables"] as? [String: Any] ?? [:]
      let m = model.current
      if query.contains("LiveFolderDetails") {
        let ids = variables["ids"] as! [String]
        var details: [Any] = ids.map { id in
          guard var pr = m.prs[id] else { return NSNull() }
          pr["state"] = m.state[id] ?? "OPEN"
          return pr
        }
        guard let failure = m.detailsError, let i = ids.firstIndex(of: failure.id) else { return json(["data": ["nodes": details]]) }
        if failure.type == "PAGE" { return json(["message": "Server Error"], status: 502) }
        let field = failure.type == "FIELD"
        if field {
          var pr = details[i] as! [String: Any]
          pr["commits"] = ["nodes": [["commit": ["statusCheckRollup": NSNull()]]]]
          details[i] = pr
        } else {
          details[i] = NSNull()
        }
        let path: [Any] = field ? ["nodes", i, "commits", "nodes", 0, "commit", "statusCheckRollup"] : ["nodes", i]
        return json(["data": ["nodes": details], "errors": [["type": field ? "FORBIDDEN" : failure.type, "path": path, "message": "Mock \(failure.type)"]]])
      }
      if query.contains("LiveFolderGone") {
        return json(["data": ["nodes": (variables["ids"] as! [String]).map { ["id": $0, "state": m.state[$0] ?? "OPEN"] }]])
      }
      if !query.contains("search(") { return json(["data": ["viewer": (m.github["data"] as! [String: Any])["viewer"]!]]) }
      return json(m.github)
    }
    if p.hasPrefix("/notion/") {
      if auth != "Bearer mock-notion" { return json(["object": "error", "code": "unauthorized"], status: 401) }
      if p == "/notion/v1/users/me" { return json(load("notion-me.json")) }
      if p == "/notion/v1/users" { return json(load("notion-users.json")) }
      if p == "/notion/v1/search" { return json(load("notion-search.json")) }
    }
    if p.hasPrefix("/confluence/") {
      if !auth.hasPrefix("Basic ") { return json([:], status: 401) }
      if p == "/confluence/wiki/rest/api/user/current" { return json(["accountId": "acc-1", "displayName": "Octo Dev"]) }
      if p == "/confluence/wiki/rest/api/content/search" { return json(load("confluence-search.json")) }
    }
    if p.hasPrefix("/bitbucket/") {
      if !auth.hasPrefix("Basic ") { return json([:], status: 401) }
      let state = model.current.bitbucketState
      if p == "/bitbucket/2.0/user" { return json(["account_id": "bb-1", "display_name": "Octo Dev"]) }
      if p == "/bitbucket/2.0/repositories/acme/pipelines/pullrequests/7" { return json(["id": 7, "state": state]) }
      if p.hasPrefix("/bitbucket/2.0/pullrequests/") {
        if state != "OPEN" { return json(["values": []]) }
        return json([
          "values": [
            [
              "id": 7, "title": "Bitbucket: tidy pipelines", "updated_on": "2026-09-25T06:00:00Z", "comment_count": 2,
              "author": ["display_name": "Octo Dev"], "source": ["branch": ["name": "tidy"]],
              "destination": ["branch": ["name": "main"], "repository": ["full_name": "acme/pipelines"]],
              "links": ["html": ["href": "https://bitbucket.org/acme/pipelines/pull-requests/7"]],
              "participants": [["role": "REVIEWER", "state": "approved"]],
            ]
          ]
        ])
      }
      if p.hasSuffix("/statuses") {
        return json(["values": [["state": "SUCCESSFUL", "name": "Pipeline #12", "url": "https://bitbucket.org/acme/pipelines/pipelines/12"]]])
      }
    }
    if p == "/google/token" { return json(["access_token": "mock-google-access", "refresh_token": "mock-google-refresh", "expires_in": 3600]) }
    if p == "/google/drive/v3/about" { return json(["user": ["displayName": "Octo Dev", "emailAddress": "octo@acme.com"]]) }
    if p == "/google/drive/v3/files" {
      return auth == "Bearer \(model.current.driveTokenValid)" ? json(load("drive-files.json")) : json([:], status: 401)
    }
    return json(["message": "No fixture for \(request.method) \(p)"], status: 404)
  }
}

extension Rig {
  init(mock: MockServer, documents: [String: String] = [:], calendarFixture: Bool = false) {
    self.init(documents: documents, environment: LiveEnvironment(mockBase: MockServer.base, calendarFixture: calendarFixture), http: mock.http)
  }
}
