import Foundation

public struct LiveAuthError: Error, Sendable, Equatable, CustomStringConvertible {
  public var message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
}

public struct GithubDeviceFlow: Sendable {
  public let userCode: String
  public let verificationUri: String
  public let expiresAt: Double
  public let done: Task<Void, Error>

  public func cancel() { done.cancel() }
}

public enum GoogleAuth {
  public static let redirect = "http://127.0.0.1:53682/ardia-oauth"
  public static let scope = "https://www.googleapis.com/auth/drive.metadata.readonly"
  static let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func random(_ n: Int) -> String {
    var rng = SystemRandomNumberGenerator()
    return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count, using: &rng)] })
  }

  public static func query(_ url: String) -> [String: String] {
    let beforeHash = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let parts = beforeHash.split(separator: "?", omittingEmptySubsequences: false)
    let search = parts.count > 1 ? String(parts[1]) : ""
    var out: [String: String] = [:]
    for pair in search.split(separator: "&") where !pair.isEmpty {
      let pieces = pair.split(separator: "=", omittingEmptySubsequences: false).map {
        JS.decodeURIComponent(String($0).replacingOccurrences(of: "+", with: " "))
      }
      out[pieces[0]] = pieces.count > 1 ? pieces[1] : nil
    }
    return out
  }

  public static func authorizeURL(endpoint: String, clientId: String, verifier: String, state: String) -> String {
    "\(endpoint)?" + LiveNet.form([
      ("client_id", clientId), ("redirect_uri", redirect), ("response_type", "code"), ("scope", scope), ("code_challenge", verifier),
      ("code_challenge_method", "plain"), ("state", state), ("access_type", "offline"), ("prompt", "consent"),
    ])
  }
}

struct GraphqlBody<W: Encodable>: Encodable {
  var query: String
  var variables: W
}

extension LiveEngine {
  public func secret(_ source: LiveSourceId) async throws -> String {
    let value = await effects.secrets.secret(account: endpoints.secretAccount(source))
    guard let value, !value.isEmpty else {
      throw LiveError(state.accounts[source] != nil ? .signedOut : .notConfigured, "Not signed in")
    }
    return value
  }

  func setSecret(_ source: LiveSourceId, _ value: String) async {
    await effects.secrets.setSecret(value, account: endpoints.secretAccount(source))
  }

  nonisolated func githubGraphql<T: Decodable, V: Encodable & Sendable>(_ type: T.Type, token: String, query: String, variables: V) async throws -> T {
    let body = try LiveJSON.encode(GraphqlBody(query: query, variables: variables))
    let data = try await requester.data(
      LiveHTTPRequest(
        method: "POST", url: endpoints.githubGraphql, headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"], body: body))
    let envelope = try JSONDecoder().decode(GraphqlEnvelope.self, from: data)
    if let error = envelope.errors?.first, !envelope.hasData {
      throw LiveError(error.type == "RATE_LIMITED" ? .rateLimited : .other, error.message)
    }
    return try JSONDecoder().decode(type, from: data)
  }

  func bitbucketAuth() async throws -> String {
    let user = state.config.bitbucketUser
    return LiveNet.basic(user, try await secret(.bitbucket))
  }

  func googleAccessToken() async throws -> String {
    let stored = try JSONDecoder().decode(GoogleTokens.self, from: Data(try await secret(.gdrive).utf8))
    if stored.expires_at > effects.clock.now() + 60_000 { return stored.access_token }
    let json = try await requester.json(
      GoogleTokenResponse.self,
      LiveHTTPRequest(
        method: "POST", url: endpoints.googleToken, headers: ["Content-Type": "application/x-www-form-urlencoded"],
        body: Data(
          LiveNet.form([
            ("client_id", state.config.googleClientId), ("client_secret", stored.client_secret), ("refresh_token", stored.refresh_token),
            ("grant_type", "refresh_token"),
          ]).utf8)))
    var next = stored
    next.access_token = json.access_token
    next.expires_at = effects.clock.now() + json.expires_in * 1000
    await setSecret(.gdrive, try LiveJSON.text(next))
    return json.access_token
  }

  func account(_ login: String, _ name: String?, _ avatar: String?) -> LiveAccount {
    LiveAccount(login: login, name: name, avatar: avatar, connectedAt: effects.clock.now())
  }

  static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

  public func connectGithub(token: String) async throws {
    let token = LiveEngine.trimmed(token)
    let json = try await githubGraphql(GithubViewerResponse.self, token: token, query: GitHubQueries.viewer, variables: [String: String]())
    guard let viewer = json.data?.viewer else { throw LiveError(.signedOut, "GitHub didn't accept the token") }
    await setSecret(.github, token)
    setAccount(.github, account(viewer.login, viewer.name, viewer.avatarUrl))
  }

  public func startGithubDeviceFlow(clientId: String) async throws -> GithubDeviceFlow {
    let form: @Sendable ([(String, String)]) -> LiveHTTPRequest = { fields in
      LiveHTTPRequest(
        method: "POST", url: "", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(LiveNet.form(fields).utf8))
    }
    var codeRequest = form([("client_id", clientId), ("scope", "repo read:org")])
    codeRequest.url = "\(endpoints.githubWeb)/login/device/code"
    let code = try await requester.json(DeviceCode.self, codeRequest)
    let clock = effects.clock
    let expiresAt = clock.now() + code.expires_in * 1000
    let tokenUrl = "\(endpoints.githubWeb)/login/oauth/access_token"
    let requester = self.requester
    let done = Task<Void, Error> {
      var interval = max(code.interval, 1) * 1000
      while !Task.isCancelled, clock.now() < expiresAt {
        do { try await clock.sleep(milliseconds: interval) } catch { break }
        if Task.isCancelled { break }
        var poll = form([("client_id", clientId), ("device_code", code.device_code), ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")])
        poll.url = tokenUrl
        let json: DeviceToken
        do {
          json = try await requester.json(DeviceToken.self, poll)
        } catch {
          if Task.isCancelled { break }
          throw error
        }
        if let token = json.access_token, !token.isEmpty { return try await self.connectGithub(token: token) }
        if json.error == "slow_down" {
          interval = (json.interval ?? interval / 1000 + 5) * 1000
        } else if let error = json.error, !error.isEmpty, error != "authorization_pending" {
          throw LiveError(.signedOut, error == "access_denied" ? "Access was denied" : error)
        }
      }
      throw LiveError(.signedOut, Task.isCancelled ? "Cancelled" : "The code expired")
    }
    return GithubDeviceFlow(userCode: code.user_code, verificationUri: code.verification_uri, expiresAt: expiresAt, done: done)
  }

  public func connectBitbucket(user: String, token: String) async throws {
    let user = LiveEngine.trimmed(user)
    let token = LiveEngine.trimmed(token)
    let me = try await requester.json(
      BitbucketMe.self, LiveHTTPRequest(url: "\(endpoints.bitbucket)/user", headers: ["Authorization": LiveNet.basic(user, token)]))
    await setSecret(.bitbucket, token)
    updateConfig(ConfigPatch(bitbucketUser: user))
    setAccount(.bitbucket, account(me.account_id, me.display_name, me.links?.avatar?.href))
  }

  public func connectNotion(token: String) async throws {
    let token = LiveEngine.trimmed(token)
    let me = try await requester.json(NotionMe.self, LiveHTTPRequest(url: "\(endpoints.notion)/users/me", headers: LiveSource.notionHeaders(token)))
    await setSecret(.notion, token)
    let workspace = me.bot?.workspace_name
    setAccount(.notion, account(workspace ?? me.name ?? "Notion", workspace, nil))
  }

  public static func confluenceBase(_ site: String) -> String {
    var base = trimmed(site)
    while base.hasSuffix("/") { base.removeLast() }
    if !base.hasPrefix("http://"), !base.hasPrefix("https://") { base = "https://" + base }
    return base
  }

  public func connectConfluence(site: String, email: String, token: String) async throws {
    let base = LiveEngine.confluenceBase(site)
    let email = LiveEngine.trimmed(email)
    let token = LiveEngine.trimmed(token)
    let me = try await requester.json(
      ConfluenceMe.self,
      LiveHTTPRequest(url: "\(endpoints.confluence(base))/wiki/rest/api/user/current", headers: ["Authorization": LiveNet.basic(email, token)]))
    await setSecret(.confluence, token)
    updateConfig(ConfigPatch(confluenceSite: base, confluenceEmail: email))
    setAccount(.confluence, account(me.accountId, me.displayName, nil))
  }

  public func connectGoogle(clientId: String, clientSecret: String, code: String, verifier: String, redirectUri: String) async throws {
    let json = try await requester.json(
      GoogleTokenResponse.self,
      LiveHTTPRequest(
        method: "POST", url: endpoints.googleToken, headers: ["Content-Type": "application/x-www-form-urlencoded"],
        body: Data(
          LiveNet.form([
            ("client_id", clientId), ("client_secret", clientSecret), ("code", code), ("code_verifier", verifier),
            ("grant_type", "authorization_code"), ("redirect_uri", redirectUri),
          ]).utf8)))
    guard let refresh = json.refresh_token, !refresh.isEmpty else { throw LiveError(.signedOut, "Google didn't return a refresh token") }
    let tokens = GoogleTokens(
      access_token: json.access_token, refresh_token: refresh, expires_at: effects.clock.now() + json.expires_in * 1000, client_secret: clientSecret)
    await setSecret(.gdrive, try LiveJSON.text(tokens))
    let about = try? await requester.json(
      DriveAbout.self, LiveHTTPRequest(url: "\(endpoints.drive)/about?fields=user", headers: ["Authorization": "Bearer \(json.access_token)"]))
    updateConfig(ConfigPatch(googleClientId: clientId))
    setAccount(.gdrive, account(about?.user?.emailAddress ?? "Google Drive", about?.user?.displayName, about?.user?.photoLink))
  }

  public func connectGoogleDrive(clientId: String, clientSecret: String) async throws {
    googlePending?.cancel()
    let clientId = LiveEngine.trimmed(clientId)
    let clientSecret = LiveEngine.trimmed(clientSecret)
    let verifier = GoogleAuth.random(64)
    let expectedState = GoogleAuth.random(24)
    let url = GoogleAuth.authorizeURL(endpoint: endpoints.googleAuth, clientId: clientId, verifier: verifier, state: expectedState)
    let presenter = effects.auth
    let task = Task<Void, Error> {
      let landed: String
      do {
        landed = try await presenter.authorize(url: url, redirectPrefix: GoogleAuth.redirect)
      } catch {
        if Task.isCancelled { throw LiveAuthError("Cancelled") }
        throw error
      }
      if Task.isCancelled { throw LiveAuthError("Cancelled") }
      let params = GoogleAuth.query(landed)
      if params["state"] != expectedState { throw LiveAuthError("Sign-in didn't match this request") }
      guard let code = params["code"], !code.isEmpty else { throw LiveAuthError(params["error"] ?? "Google didn't grant access") }
      try await self.connectGoogle(clientId: clientId, clientSecret: clientSecret, code: code, verifier: verifier, redirectUri: GoogleAuth.redirect)
    }
    googlePending = task
    defer { if googlePending == task { googlePending = nil } }
    try await task.value
  }

  public func disconnect(_ source: LiveSourceId) async {
    await effects.secrets.deleteSecret(account: endpoints.secretAccount(source))
    setAccount(source, nil)
  }
}
