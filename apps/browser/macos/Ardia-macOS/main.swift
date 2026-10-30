import AppKit
import ArdiaCore
import ArdiaStore
import ArdiaSync

if getenv("ARDIA_PREWARM") != nil { exit(0) }

LegacyMigration.moveToNewName()

if !LegacyMigration.runAtLaunch() { exit(0) }

if let code = SafeStorageRekeyRun.runAtLaunch(
  chromeUsesRealKeychain: ArdiaCoreHost.chromeUsesRealKeychain, installedUserDataDir: ArdiaCoreHost.installedDataDirectory,
  stores: { RekeyStores(onStaged: $0) }) { exit(code) }

_ = MainActor.assumeIsolated { NativeStore.launchAtStartup() }
ArdiaCoreHost.safeMode = NativeStore.safeMode

exit(ArdiaCoreHost.run(argc: CommandLine.argc, argv: CommandLine.unsafeArgv) { AppDelegate() })
