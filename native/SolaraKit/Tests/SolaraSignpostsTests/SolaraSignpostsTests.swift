import Foundation
import Synchronization
import Testing

@testable import SolaraSignposts

private let seen = Mutex<[(String, Int, Double)]>([])

@Suite(.serialized) struct SolaraSignpostsTests {
  @Test func anObserverHearsEachPointWithItsWindowAndTime() {
    seen.withLock { $0.removeAll() }
    solaraSignpostsSetObserver { name, window, at in seen.withLock { $0.append((String(cString: name), window, at)) } }
    defer { solaraSignpostsSetObserver(nil) }
    let before = Date().timeIntervalSince1970 * 1000
    SolaraSignposts.emit(.selectionShown, window: 7)
    #expect("suggestions shown".withCString { solaraSignpostsEmit($0, 2) })
    #expect(!"no such point".withCString { solaraSignpostsEmit($0, 0) })
    let got = seen.withLock { $0 }
    #expect(got.map(\.0) == ["selection shown", "suggestions shown"])
    #expect(got.map(\.1) == [7, 2])
    #expect(got.allSatisfy { $0.2 >= before && $0.2 <= Date().timeIntervalSince1970 * 1000 })
  }

  @Test func countersAddUpAndReset() {
    SolaraSignposts.reset()
    SolaraSignposts.count(.storeCommit)
    SolaraSignposts.count(.storeCommit, by: 2)
    #expect("layout pass".withCString { solaraSignpostsCount($0, 5) })
    #expect(SolaraSignposts.read() == [.storeCommit: 3, .layoutPass: 5])
    #expect("store commit".withCString { solaraSignpostsCounter($0) } == 3)
    #expect("nope".withCString { solaraSignpostsCounter($0) } == -1)
    SolaraSignposts.reset()
    #expect(SolaraSignposts.read().isEmpty)
  }
}
