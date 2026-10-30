import Foundation

private final class BangRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

public enum BangURLSession {
  public static func fetch(endpoint: URL, etag: String?) async throws -> BangFetchReply {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let etag, !etag.isEmpty, etag.count <= 200, !etag.contains(where: { $0.isNewline }) {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    let (bytes, response) = try await session.bytes(for: request, delegate: BangRedirectBlocker())
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard response.expectedContentLength <= 5_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
    var data = Data()
    if http.statusCode == 200 {
      for try await byte in bytes {
        guard data.count < 5_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        data.append(byte)
      }
    }
    let body: String?
    if http.statusCode == 200 {
      guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
      body = text
    } else {
      body = nil
    }
    return BangFetchReply(status: http.statusCode, body: body,
      etag: http.value(forHTTPHeaderField: "ETag"), contentType: http.value(forHTTPHeaderField: "Content-Type"))
  }
}
