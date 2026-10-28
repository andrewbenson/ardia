import Darwin
import Foundation
import Security

enum VerifiedLaunch {
  static func spawnSuspended(_ executable: URL, environment: [String: String]) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    let argv = [strdup(executable.path)]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") }
    defer { (argv + envp).forEach { free($0) } }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv + [nil], envp + [nil])
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    return pid
  }

  static func isGenuine(pid: pid_t, requirement: SecRequirement, inside bundle: URL) -> Bool {
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess, let code,
      SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    else { return false }
    var staticCode: SecStaticCode?
    var path: CFURL?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path
    else { return false }
    let running = (path as URL).resolvingSymlinksInPath().standardizedFileURL.path
    let root = bundle.resolvingSymlinksInPath().standardizedFileURL.path
    return running == root || running.hasPrefix(root + "/")
  }

  static func reap(_ pid: pid_t, waiting: Bool = false) -> Int? {
    var status: Int32 = 0
    var reaped = waitpid(pid, &status, waiting ? 0 : WNOHANG)
    while reaped == -1 && errno == EINTR { reaped = waitpid(pid, &status, waiting ? 0 : WNOHANG) }
    guard reaped == pid else { return nil }
    let signal = status & 0x7f
    return signal == 0 ? Int((status >> 8) & 0xff) : Int(signal)
  }
}
