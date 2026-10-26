import Foundation
import Testing

@testable import SolaraLive

@Suite struct GitHubTests {
  let fixture = Fixture.decode(GithubResponse.self, "github.json")
  var all: [RawPR] { (fixture.data!.authored.nodes + fixture.data!.review.nodes).compactMap(\.pullRequest) }
  let filters = LiveFilters(authored: true, reviewRequests: true)

  func pr(_ id: String) -> RawPR {
    var found = all.first { $0.id == id }!
    found.state = "OPEN"
    return found
  }

  func kind(_ body: () throws -> Void) -> String {
    do {
      try body()
    } catch let error as LiveError {
      return error.kind.rawValue
    } catch {
      Issue.record("not a LiveError: \(error)")
      return "?"
    }
    return "ok"
  }

  func idsOnly(_ ids: [String]) -> GithubNodes { GithubNodes(nodes: ids.map(GithubNode.id)) }

  @Test func aPageWithoutErrorsReturnsEveryPR() throws {
    let ids = all.prefix(3).map(\.id)
    #expect(try GitHub.detailNodes(ids, DetailsResponse(data: .init(nodes: ids.map(pr)))).map(\.id) == ids)
  }

  @Test func aFieldErrorKeepsThePRWithThatFieldEmpty() throws {
    let ids = all.prefix(2).map(\.id)
    var nodes: [RawPR?] = ids.map(pr)
    nodes[1]!.commits = RawPR.Commits(nodes: [RawPR.CommitNode(commit: RawPR.Commit(statusCheckRollup: nil))])
    let errors = [
      GraphqlError(
        type: "FORBIDDEN", message: "no checks",
        path: [.key("nodes"), .index(1), .key("commits"), .key("nodes"), .index(0), .key("commit"), .key("statusCheckRollup")])
    ]
    let kept = try GitHub.detailNodes(ids, DetailsResponse(data: .init(nodes: nodes), errors: errors))
    #expect(kept.map(\.id) == ids)
    var data = fixture.data!
    data.authored = idsOnly(ids)
    data.review = GithubNodes(nodes: [])
    let items = GitHub.mapGithub(GitHub.withDetails(GithubResponse(data: data), kept), filters: filters)
    #expect(items.first { $0.id == "github:\(ids[1])" }!.pr!.checks == [])
  }

  @Test func aPRGitHubCantFindOrWontShowDropsOutTheRestStay() throws {
    let ids = all.prefix(3).map(\.id)
    for type in ["NOT_FOUND", "FORBIDDEN"] {
      var nodes: [RawPR?] = ids.map(pr)
      nodes[1] = nil
      let kept = try GitHub.detailNodes(
        ids, DetailsResponse(data: .init(nodes: nodes), errors: [GraphqlError(type: type, message: type, path: [.key("nodes"), .index(1)])]))
      #expect(kept.map(\.id) == [ids[0], ids[2]])
    }
  }

  @Test func aPRLostToAnythingElseFailsThePageAndARateLimitSaysSo() {
    let ids = all.prefix(2).map(\.id)
    let lost: [RawPR?] = [pr(ids[0]), nil]
    #expect(
      kind {
        _ = try GitHub.detailNodes(
          ids,
          DetailsResponse(
            data: .init(nodes: lost), errors: [GraphqlError(type: "SERVICE_UNAVAILABLE", message: "timeout", path: [.key("nodes"), .index(1)])]))
      } == "other")
    #expect(
      kind { _ = try GitHub.detailNodes(ids, DetailsResponse(data: .init(nodes: lost), errors: [GraphqlError(message: "Something went wrong")])) }
        == "other")
    #expect(kind { _ = try GitHub.detailNodes(ids, DetailsResponse(data: .init(nodes: lost))) } == "other")
    #expect(kind { _ = try GitHub.detailNodes(ids, DetailsResponse(data: .init(nodes: [pr(ids[0])]))) } == "other")
    #expect(kind { _ = try GitHub.detailNodes(ids, DetailsResponse(data: nil)) } == "other")
    #expect(
      kind {
        _ = try GitHub.detailNodes(ids, DetailsResponse(data: .init(nodes: ids.map(pr)), errors: [GraphqlError(type: "RATE_LIMITED", message: "slow down")]))
      } == "rateLimited")
  }

  @Test func detailsKeepTheSearchsOrderAndSectionsAndDropPRsThatClosedInBetween() {
    let ids = GitHub.detailIds(fixture, filters: filters)
    #expect(Set(ids).count == ids.count)
    var details: [RawPR?] = ids.map(pr).reversed()
    details[0]!.state = "MERGED"
    var data = fixture.data!
    data.authored = idsOnly(fixture.data!.authored.nodes.compactMap(\.nodeId))
    data.review = idsOnly(fixture.data!.review.nodes.compactMap(\.nodeId))
    let items = GitHub.mapGithub(GitHub.withDetails(GithubResponse(data: data), details), filters: filters)
    let before = GitHub.mapGithub(fixture, filters: filters).filter { $0.id != "github:\(details[0]!.id)" }
    #expect(items.map { [$0.id, $0.section?.rawValue ?? ""] } == before.map { [$0.id, $0.section?.rawValue ?? ""] })
  }
}
