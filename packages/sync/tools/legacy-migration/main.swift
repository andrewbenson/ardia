import ArdiaSyncCore
import Foundation

switch CommandLine.arguments.dropFirst().first {
case "names":
  FileHandle.standardOutput.write(LegacyMigration.namesJSON())
case "run":
  guard ProcessInfo.processInfo.environment["ARDIA_DATA_DIR"] != nil else {
    FileHandle.standardError.write(Data("set ARDIA_DATA_DIR and ARDIA_LEGACY_SOURCE\n".utf8))
    exit(2)
  }
  exit(LegacyMigration.runAtLaunch(bundleId: "com.ardia.browser") ? 0 : 3)
case "move":
  let args = CommandLine.arguments
  if args.count == 4, args[2] == "--wait" {
    while !FileManager.default.fileExists(atPath: args[3]) { usleep(20_000) }
  }
  LegacyMigration.moveToNewName(bundleId: LegacyName.successorBundleId)
  let launched = LegacyMigration.launchedExecutable() ?? "?"
  print("at \(launched)|\(ProcessInfo.processInfo.environment["MOVE_MARK"] ?? "")|\(args.dropFirst().joined(separator: " "))")
default:
  FileHandle.standardError.write(Data("usage: legacy-migration names|run|move [--wait <file>]\n".utf8))
  exit(2)
}
