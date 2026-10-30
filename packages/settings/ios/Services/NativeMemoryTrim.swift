import AppKit
import ArdiaCore
import CoreGraphics
import Foundation
import SolaraStore
import SolaraUI

@MainActor
final class NativeMemoryTrim {
  static let shared = NativeMemoryTrim()

  private var started = false
  private var quitting = false
  private var baselineRevision = 0
  private var schedule: MemoryTrimSchedule?
  private var timer: DispatchWorkItem?
  private var generation = 0
  private var quitGeneration = 0
  private var quitObservers: [NSObjectProtocol] = []

  private init() {}

  func startWhenReady(tries: Int = 40) {
    guard !started, MemoryTrimSchedule.enabled(environment: ProcessInfo.processInfo.environment) else { return }
    guard let store = NativeStoreHandle.store else {
      guard tries > 0 else { return NSLog("[memory] the native store never opened, so memory trim stays off") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.startWhenReady(tries: tries - 1) }
      return
    }
    started = true
    store.subscribe { [weak self] commit in
      let count = commit.state.tabs.count
      let revision = commit.rev
      DispatchQueue.main.async {
        guard let self, revision > self.baselineRevision else { return }
        if self.schedule?.tabsChanged(count: count, now: Self.now) == true { self.arm() }
      }
    }
    let baseline = store.snapshot
    baselineRevision = baseline.rev
    schedule = MemoryTrimSchedule(tabCount: baseline.state.tabs.count)
    for (name, quitting) in [("SolaraWillQuit", true), ("ArdiaCoreQuitCancelled", false)] {
      quitObservers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          let trim = NativeMemoryTrim.shared
          trim.quitting = quitting
          if quitting { trim.quitGeneration += 1 }
        }
      })
    }
  }

  private static var now: Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }

  private static var inputIdleSeconds: Double {
    guard NSRunningApplication.current.isActive else { return 3600 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
  }

  private func trim() {
    let requestedGeneration = quitGeneration
    Task {
      guard !quitting, quitGeneration == requestedGeneration else { return }
      _ = try? await SettingsJS.shared.invoke("memory.compact", [], timeout: 3)
      guard !quitting, quitGeneration == requestedGeneration else { return }
      guard !["off", "0", "false"].contains(ProcessInfo.processInfo.environment["ARDIA_MEMORY_TRIM_ENGINE"] ?? "") else { return }
      ArdiaCoreServices.call("ac_memory_trim", profile: "", args: nil) { @Sendable _ in }
    }
  }

  private func arm() {
    timer?.cancel()
    timer = nil
    generation += 1
    guard let due = schedule?.dueAt else { return }
    let scheduledGeneration = generation
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == scheduledGeneration else { return }
      self.timer = nil
      if self.schedule?.fire(now: Self.now, inputIdleSeconds: Self.inputIdleSeconds, quitting: self.quitting) == true {
        self.trim()
      }
      self.arm()
    }
    timer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - Self.now) / 1000, execute: work)
  }
}
