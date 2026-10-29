import Foundation

public struct LiveEndpoints: Sendable, Equatable {
  public let mock: String?

  public init(mock: String?) {
    self.mock = mock?.isEmpty == true ? nil : mock
  }

  public var githubGraphql: String { mock.map { "\($0)/github/graphql" } ?? "https://api.github.com/graphql" }
  public var githubWeb: String { mock.map { "\($0)/github" } ?? "https://github.com" }
  public var bitbucket: String { mock.map { "\($0)/bitbucket/2.0" } ?? "https://api.bitbucket.org/2.0" }
  public var notion: String { mock.map { "\($0)/notion/v1" } ?? "https://api.notion.com/v1" }
  public func confluence(_ site: String) -> String {
    mock.map { "\($0)/confluence" } ?? (site.hasSuffix("/") ? String(site.dropLast()) : site)
  }
  public var googleAuth: String { mock.map { "\($0)/google/auth" } ?? "https://accounts.google.com/o/oauth2/v2/auth" }
  public var googleToken: String { mock.map { "\($0)/google/token" } ?? "https://oauth2.googleapis.com/token" }
  public var drive: String { mock.map { "\($0)/google/drive/v3" } ?? "https://www.googleapis.com/drive/v3" }

  public func secretAccount(_ source: LiveSourceId) -> String {
    mock == nil ? source.rawValue : "mock:\(source.rawValue)"
  }
}

public enum LiveNet {
  public static func check(_ response: LiveHTTPResponse) throws {
    let status = response.status
    if status == 401 { throw LiveError(.signedOut, "Signed out") }
    if status == 403, let sso = response.header("x-github-sso"), !sso.isEmpty { throw LiveError(.sso, "Needs Single Sign-On") }
    if status == 429 || (status == 403 && response.header("x-ratelimit-remaining") == "0") {
      throw LiveError(.rateLimited, "Rate Limit Exceeded")
    }
    if !(200...299).contains(status) {
      let text = JS.utf16Prefix(String(decoding: response.body, as: UTF8.self), 200)
      let message = "\(status) \(text)".trimmingCharacters(in: .whitespacesAndNewlines)
      throw LiveError(status == 403 ? .signedOut : .other, message)
    }
  }

  public static func form(_ fields: [(String, String)]) -> String {
    fields.map { "\(JS.encodeURIComponent($0.0))=\(JS.encodeURIComponent($0.1))" }.joined(separator: "&")
  }

  public static func base64(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
  }

  public static func basic(_ user: String, _ secret: String) -> String {
    "Basic \(base64("\(user):\(secret)"))"
  }
}

struct LiveRequester: Sendable {
  let http: any LiveHTTPClient
  var environment = LiveEnvironment()

  func data(_ request: LiveHTTPRequest) async throws -> Data {
    var request = request
    if !request.headers.keys.contains(where: { $0.lowercased() == "accept" }) {
      request.headers["Accept"] = "application/json"
    }
    try environment.checkRequest(request.url)
    let response: LiveHTTPResponse
    do {
      response = try await http.send(request)
    } catch {
      throw LiveError(.network, "Couldn't connect")
    }
    try LiveNet.check(response)
    return response.body
  }

  func json<T: Decodable>(_ type: T.Type, _ request: LiveHTTPRequest) async throws -> T {
    let body = try await data(request)
    return try JSONDecoder().decode(type, from: body)
  }
}
