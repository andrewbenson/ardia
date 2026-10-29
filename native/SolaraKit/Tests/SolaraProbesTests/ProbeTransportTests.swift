#if SOLARA_PROBES
import Darwin
import Foundation
import Testing
@testable import SolaraProbes

struct ProbeTransportTests {
  private let id = UUID().uuidString

  private func request(_ changes: [String: Any] = [:]) -> Data {
    var value: [String: Any] = ["protocol": 1, "id": id, "command": "x", "args": [:], "expiresAtMs": 10_000]
    value.merge(changes) { _, new in new }
    return try! JSONSerialization.data(withJSONObject: value)
  }

  @Test func acceptsEnvelope() throws {
    let value = try ProbeRequest.decode(request(), nowMs: 1)
    #expect(value.id == id)
    #expect(value.command == "x")
  }

  @Test func rejectsEnvelope() {
    #expect(throws: ProbeFailure.invalidEnvelope) { try ProbeRequest.decode(Data("[1]".utf8), nowMs: 1) }
    #expect(throws: ProbeFailure.invalidEnvelope) { try ProbeRequest.decode(request(["extra": true]), nowMs: 1) }
    #expect(throws: ProbeFailure.invalidEnvelope) { try ProbeRequest.decode(request(["protocol": true]), nowMs: 1) }
    #expect(throws: ProbeFailure.unsupportedProtocol) { try ProbeRequest.decode(request(["protocol": 2]), nowMs: 1) }
    #expect(throws: ProbeFailure.invalidArgument) { try ProbeRequest.decode(request(["args": []]), nowMs: 1) }
    #expect(throws: ProbeFailure.invalidArgument) { try ProbeRequest.decode(request(["id": "bad"]), nowMs: 1) }
    #expect(throws: ProbeFailure.expired) { try ProbeRequest.decode(request(["expiresAtMs": 1]), nowMs: 1) }
    #expect(throws: ProbeFailure.expired) { try ProbeRequest.decode(request(["expiresAtMs": 90_000]), nowMs: 1) }
    #expect(throws: ProbeFailure.oversized) { try ProbeRequest.decode(Data(repeating: 32, count: 65_537), nowMs: 1) }
  }

  @Test func rejectsDuplicate() {
    var seen = ProbeSeenIds()
    let first = seen.insert(id)
    let second = seen.insert(id)
    #expect(first)
    #expect(!second)
  }

  @Test func rejectsWrongOwner() throws {
    let fd = Darwin.open(FileManager.default.temporaryDirectory.path, O_RDONLY | O_DIRECTORY)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(throws: ProbeFailure.testHooksDenied) { try ProbeFiles.checkedDirectory(fd, owner: getuid() + 1) }
  }

  @Test func rejectsSymlinkedProbeDirectory() throws {
    let root = URL(fileURLWithPath: ProbeFiles.realPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent(UUID().uuidString)
    let data = root.appendingPathComponent("data")
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("probes"), withDestinationURL: other)
    #expect(throws: ProbeFailure.testHooksDenied) { try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory()) }
    #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("probes/claimed").path))
  }

  @Test func checksScratchGate() throws {
    let root = URL(fileURLWithPath: ProbeFiles.realPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent(UUID().uuidString)
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let files = try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory())
    try files.recheck()
    #expect(throws: ProbeFailure.testHooksDenied) { try ProbeFiles.open(dataPath: data.path, defaultPath: data.path, homePath: NSHomeDirectory()) }
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: data.path)
    #expect(throws: ProbeFailure.testHooksDenied) { try files.recheck() }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
    let link = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: data)
    #expect(throws: ProbeFailure.testHooksDenied) { try ProbeFiles.open(dataPath: link.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory()) }
    try FileManager.default.removeItem(at: data.appendingPathComponent(".solara-probe-scratch"))
    #expect(throws: ProbeFailure.testHooksDenied) { try files.recheck() }
    #expect(throws: ProbeFailure.testHooksDenied) { try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory()) }
  }

  @Test func acceptsTheRealPathOfAPrivateTempDir() throws {
    let root = URL(fileURLWithPath: ProbeFiles.realPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent(UUID().uuidString)
    #expect(root.path.hasPrefix("/private/"))
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let files = try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory())
    try files.recheck()
  }

  @Test func claimsRequestsAcrossPolls() throws {
    let root = URL(fileURLWithPath: ProbeFiles.realPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent(UUID().uuidString)
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let files = try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory())
    #expect(files.claim().isEmpty)
    for _ in 0..<2 {
      let next = UUID().uuidString
      try request().write(to: data.appendingPathComponent("probes/inbox/\(next).json"))
      #expect(files.claim().map(\.0) == [next])
    }
  }

  private func scratch() throws -> (URL, URL, ProbeFiles) {
    let root = URL(fileURLWithPath: ProbeFiles.realPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent(UUID().uuidString)
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let files = try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory())
    return (root, data, files)
  }

  @Test func aFifoInTheInboxDoesNotBlock() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString
    #expect(mkfifo(data.appendingPathComponent("probes/inbox/\(id).json").path, 0o600) == 0)
    let claimed = files.claim()
    #expect(claimed.count == 1)
    #expect(claimed.first?.1 == nil)
  }

  @Test func aPollClaimsABoundedBatch() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    for _ in 0..<(ProbeFiles.batch + 8) {
      try request().write(to: data.appendingPathComponent("probes/inbox/\(UUID().uuidString).json"))
    }
    #expect(files.claim().count == ProbeFiles.batch)
    #expect(files.claim().count == 8)
  }
}
#endif
