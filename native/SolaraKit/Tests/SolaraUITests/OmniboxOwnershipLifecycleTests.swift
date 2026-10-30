import SolaraStore
import Testing
@testable import SolaraUI

extension OmniboxWorkspaceFeedTests {
  @Test func everyMainActorOwnershipCycleInvalidatesItsPreviousEpoch() {
    let previousResolver = NativeStoreHandle.resolve
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    let store = Store(checksInvariants: false)
    NativeStoreHandle.resolve = { store }
    NativeStoreHandle.ownsWorkspace = true
    let feed = OmniboxWorkspaceFeed(sources: NewTabSources(), ownsWorkspace: { NativeStoreHandle.ownsWorkspace }, resolve: { NativeStoreHandle.store })
    feed.start()
    defer {
      feed.stop()
      NativeStoreHandle.resolve = previousResolver
      NativeStoreHandle.ownsWorkspace = previousOwnership
    }
    for _ in 0..<3 {
      let epoch = feed.status.epoch
      let generation = feed.generation
      NativeStoreHandle.ownsWorkspace = false
      #expect(feed.status.mode == "js-feed" && !feed.status.ready)
      #expect(feed.status.epoch == epoch + 1)
      #expect(feed.generation == generation + 1)
      NativeStoreHandle.ownsWorkspace = true
      #expect(feed.status.mode == "native-store" && feed.status.ready)
      #expect(feed.status.epoch == epoch + 2)
      #expect(feed.generation == generation + 2)
    }
  }

  @Test func reentrantOwnershipRestorationStillInvalidatesEveryEpoch() {
    let previousResolver = NativeStoreHandle.resolve
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    let store = Store(checksInvariants: false)
    NativeStoreHandle.resolve = { store }
    NativeStoreHandle.ownsWorkspace = true
    let feed = OmniboxWorkspaceFeed(sources: NewTabSources(), ownsWorkspace: { NativeStoreHandle.ownsWorkspace }, resolve: { NativeStoreHandle.store })
    feed.start()
    var listeners: [Int] = []
    defer {
      for listener in listeners { NativeStoreHandle.unsubscribeLifecycle(listener) }
      feed.stop()
      NativeStoreHandle.resolve = previousResolver
      NativeStoreHandle.ownsWorkspace = previousOwnership
    }
    var missed = 0
    for _ in 0..<32 {
      listeners.append(NativeStoreHandle.subscribeLifecycle {
        if !NativeStoreHandle.ownsWorkspace { NativeStoreHandle.ownsWorkspace = true }
      })
      let epoch = feed.status.epoch
      let generation = feed.generation
      NativeStoreHandle.ownsWorkspace = false
      #expect(NativeStoreHandle.ownsWorkspace)
      #expect(feed.status.mode == "native-store" && feed.status.ready)
      if feed.status.epoch != epoch + 2 || feed.generation != generation + 2 { missed += 1 }
    }
    print("reentrant ownership restorations: 32, missed invalidations: \(missed)")
    #expect(missed == 0)
  }

  @Test func lifecycleReplayAllowsReentrantMutationAndRemoval() {
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    NativeStoreHandle.ownsWorkspace = false
    var values: [Bool] = []
    let listener = NativeStoreHandle.subscribeLifecycle {
      values.append(NativeStoreHandle.ownsWorkspace)
      if NativeStoreHandle.ownsWorkspace { NativeStoreHandle.ownsWorkspace = false }
    }
    NativeStoreHandle.ownsWorkspace = true
    #expect(values == [false, true, false])
    NativeStoreHandle.unsubscribeLifecycle(listener)
    NativeStoreHandle.ownsWorkspace = true
    #expect(values == [false, true, false])
    NativeStoreHandle.ownsWorkspace = previousOwnership
  }
}
