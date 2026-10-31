import Security
import XCTest
@testable import SolaraShellCore

final class VerifiedLaunchTests: XCTestCase {
  var root: URL!
  var bundle: URL!
  var executable: URL!
  var marker: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("verified-launch-\(UUID().uuidString)", isDirectory: true)
    bundle = root.appendingPathComponent("Staged.app", isDirectory: true)
    let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    executable = macOS.appendingPathComponent("staged")
    marker = root.appendingPathComponent("ran")
    try compile(writing: "ran", exit: 7, to: executable)
  }

  func compile(writing text: String, exit code: Int, to output: URL) throws {
    let source = root.appendingPathComponent("\(output.lastPathComponent)-\(text).c")
    try """
      #include <stdio.h>
      #include <stdlib.h>
      int main(void) {
        FILE *f = fopen(getenv("MARKER"), "w");
        if (f) { fputs("\(text)", f); fclose(f); }
        return \(code);
      }
      """.write(to: source, atomically: true, encoding: .utf8)
    let clang = Process()
    clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    clang.arguments = ["clang", "-o", output.path, source.path]
    try clang.run()
    clang.waitUntilExit()
    XCTAssertEqual(clang.terminationStatus, 0)
  }

  func swap(_ replacement: URL) throws {
    _ = try FileManager.default.replaceItemAt(executable, withItemAt: replacement)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func requirement(_ text: String) throws -> SecRequirement {
    var requirement: SecRequirement?
    XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
    return try XCTUnwrap(requirement)
  }

  func ownRequirement() throws -> SecRequirement {
    var code: SecStaticCode?
    XCTAssertEqual(SecStaticCodeCreateWithPath(executable as CFURL, [], &code), errSecSuccess)
    var requirement: SecRequirement?
    XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(code), [], &requirement), errSecSuccess)
    return try XCTUnwrap(requirement)
  }

  func waitForExit(_ pid: pid_t) -> Int? {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let status = VerifiedLaunch.reap(pid) { return status }
      usleep(10_000)
    }
    return nil
  }

  func testCodeThatDoesNotMeetTheRequirementIsKilledBeforeItRuns() throws {
    let pid = try VerifiedLaunch.spawnSuspended(executable, environment: ["MARKER": marker.path])
    let other = try requirement("identifier \"com.example.not-this-app\" and anchor apple generic")
    XCTAssertFalse(VerifiedLaunch.isGenuine(pid: pid, requirement: other, inside: bundle))
    kill(pid, SIGKILL)
    XCTAssertEqual(waitForExit(pid), Int(SIGKILL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testCodeRunningFromOutsideTheStagedBundleIsRefused() throws {
    let pid = try VerifiedLaunch.spawnSuspended(executable, environment: ["MARKER": marker.path])
    let elsewhere = root.appendingPathComponent("Other.app", isDirectory: true)
    XCTAssertFalse(VerifiedLaunch.isGenuine(pid: pid, requirement: try ownRequirement(), inside: elsewhere))
    kill(pid, SIGKILL)
    XCTAssertEqual(waitForExit(pid), Int(SIGKILL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testAnImpostorSpawnedWhileTheGenuineFileIsPutBackIsRefused() throws {
    let genuine = try ownRequirement()
    let goodCopy = root.appendingPathComponent("good")
    try FileManager.default.copyItem(at: executable, to: goodCopy)
    let impostor = root.appendingPathComponent("impostor")
    try compile(writing: "impostor", exit: 2, to: impostor)
    try swap(impostor)
    let pid = try VerifiedLaunch.spawnSuspended(executable, environment: ["MARKER": marker.path])
    try swap(goodCopy)
    XCTAssertFalse(VerifiedLaunch.isGenuine(pid: pid, requirement: genuine, inside: bundle))
    kill(pid, SIGKILL)
    XCTAssertEqual(waitForExit(pid), Int(SIGKILL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testGenuineCodeWhoseFileIsReplacedAfterSpawningIsRefused() throws {
    let genuine = try ownRequirement()
    let pid = try VerifiedLaunch.spawnSuspended(executable, environment: ["MARKER": marker.path])
    let impostor = root.appendingPathComponent("impostor")
    try compile(writing: "impostor", exit: 2, to: impostor)
    try swap(impostor)
    XCTAssertFalse(VerifiedLaunch.isGenuine(pid: pid, requirement: genuine, inside: bundle))
    kill(pid, SIGKILL)
    XCTAssertEqual(waitForExit(pid), Int(SIGKILL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testAWaitingReapCollectsAChildThatHasNotExitedYet() throws {
    let pid = try VerifiedLaunch.spawnSuspended(executable, environment: ["MARKER": marker.path])
    XCTAssertNil(VerifiedLaunch.reap(pid))
    kill(pid, SIGKILL)
    XCTAssertEqual(VerifiedLaunch.reap(pid, waiting: true), Int(SIGKILL))
  }

  func testGenuineCodeRunsOnlyOnceResumed() throws {
    let pid = try VerifiedLaunch.spawnSuspended(executable, environment: ["MARKER": marker.path])
    usleep(200_000)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertTrue(VerifiedLaunch.isGenuine(pid: pid, requirement: try ownRequirement(), inside: bundle))
    XCTAssertEqual(kill(pid, SIGCONT), 0)
    XCTAssertEqual(waitForExit(pid), 7)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
  }
}
