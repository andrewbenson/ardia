import Foundation

public final class FolderLock: Sendable {
  public static let fileName = "solara.lock"

  let descriptor: Int32

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }

  public static func acquire(_ folder: DataFolder) throws -> FolderLock? {
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    let path = folder.url.appending(path: fileName).path
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(fd)
      if code == EWOULDBLOCK { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    let pid = Data("\(getpid())\n".utf8)
    ftruncate(fd, 0)
    _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, pid.count, 0) }
    return FolderLock(descriptor: fd)
  }

  public static func holder(_ folder: DataFolder) -> pid_t? {
    guard let text = try? String(contentsOf: folder.url.appending(path: fileName), encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
