import Foundation
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct SafeFlushTests {
  @Test func aSafeLaunchWithNoDatabaseSkipsItsFlushWithoutReportingSaved() {
    let result = FlushResult.flushing(nil, timeout: 5)
    #expect(result == .skipped("safe mode opened no database"))
    #expect(result != .saved)
    #expect(result.description == "skipped: safe mode opened no database")
    #expect(!result.isProblem)
  }

  @Test func aWriterStillReportsItsOwnResult() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(FlushResult.flushing(writer, timeout: 5) == .saved)
    #expect(!FlushResult.saved.isProblem)
    #expect(FlushResult.timedOut.isProblem && FlushResult.failed("x").isProblem)
    try launch.database.close()
  }
}
