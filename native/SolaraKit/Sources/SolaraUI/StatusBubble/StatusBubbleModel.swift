import Foundation
import Observation
import SolaraOmnibox

public enum StatusBubbleTiming {
  public static let showDelay: Double = 0.5
  public static let hideDelay: Double = 0.5
  public static let expandDelay: Double = 1.5
  public static let fade: Double = 0.1
}

public enum StatusBubbleMetrics {
  public static let inset: CGFloat = 10
  public static let height: CGFloat = 24
  public static let padding: CGFloat = 9
  public static let compactMaxWidth: CGFloat = 400
  public static let fontSize: CGFloat = 12
  public static let pinSlop: CGFloat = 10
  public static let borderWidth: CGFloat = 1
  public static let shadowOpacity: Float = 0.12
  public static let shadowRadius: CGFloat = 5

  public static func maxWidth(containerWidth: CGFloat, expanded: Bool) -> CGFloat {
    let room = max(0, containerWidth - inset * 2)
    return expanded ? room : min(compactMaxWidth, room)
  }

  public static func width(text: CGFloat, containerWidth: CGFloat, expanded: Bool) -> CGFloat {
    min(maxWidth(containerWidth: containerWidth, expanded: expanded), (text * 2).rounded(.up) / 2 + padding * 2)
  }
}

public enum StatusBubbleText {
  public static func display(_ raw: String) -> String {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }
    let shown = toAppUrl(text)
    guard let decoded = shown.removingPercentEncoding, !decoded.unicodeScalars.contains(where: unsafe) else { return shown }
    return decoded
  }

  private static func unsafe(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) && scalar != " "
      || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
  }
}

public enum StatusBubblePin {
  public static func trailing(pointer: CGPoint, bubble: CGRect, containerWidth: CGFloat, current: Bool) -> Bool {
    let hit = bubble.insetBy(dx: -StatusBubbleMetrics.pinSlop, dy: -StatusBubbleMetrics.pinSlop)
    let leading = CGRect(x: 0, y: hit.minY, width: hit.width, height: hit.height)
    let trailing = CGRect(x: containerWidth - hit.width, y: hit.minY, width: hit.width, height: hit.height)
    let inLeading = leading.contains(pointer)
    if inLeading && trailing.contains(pointer) { return current }
    return inLeading
  }
}

@MainActor
public protocol StatusBubbleTimer: AnyObject {
  func cancel()
}

@MainActor
public protocol StatusBubbleClock: AnyObject {
  func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) -> StatusBubbleTimer
}

@MainActor
public final class StatusBubbleMainClock: StatusBubbleClock {
  public init() {}

  public func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) -> StatusBubbleTimer {
    let timer = MainTimer(work)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { timer.fire() } }
    return timer
  }

  private final class MainTimer: StatusBubbleTimer {
    private var work: (@MainActor () -> Void)?

    init(_ work: @escaping @MainActor () -> Void) { self.work = work }

    func fire() {
      let pending = work
      work = nil
      pending?()
    }

    func cancel() { work = nil }
  }
}

@Observable
@MainActor
public final class StatusBubbleModel {
  public enum Presentation: Equatable, Sendable {
    case hidden, pendingPresentation, visible, pendingDismissal, hiding
  }

  public private(set) var presentation: Presentation = .hidden
  public private(set) var text = ""
  public private(set) var expanded = false
  public private(set) var pinnedTrailing = false

  @ObservationIgnored private let clock: StatusBubbleClock
  @ObservationIgnored private var presentationTimer: StatusBubbleTimer?
  @ObservationIgnored private var expansionTimer: StatusBubbleTimer?
  @ObservationIgnored private var lastStatus = ""

  public init(clock: StatusBubbleClock = StatusBubbleMainClock()) {
    self.clock = clock
  }

  public var opaque: Bool { presentation == .visible || presentation == .pendingDismissal }

  public var mounted: Bool { presentation != .hidden && presentation != .pendingPresentation }

  public var expansionPending: Bool { expansionTimer != nil }

  public func setStatus(_ raw: String) {
    guard raw != lastStatus else { return }
    lastStatus = raw
    let shown = StatusBubbleText.display(raw)
    if shown.isEmpty { return clear() }
    text = shown
    switch presentation {
    case .hidden, .pendingPresentation:
      schedule(.pendingPresentation, after: StatusBubbleTiming.showDelay) { $0.present() }
    case .pendingDismissal, .hiding:
      presentationTimer?.cancel()
      presentationTimer = nil
      presentation = .visible
      scheduleExpansion()
    case .visible:
      if expansionTimer != nil { scheduleExpansion() }
    }
  }

  public func pointerMoved(_ pointer: CGPoint, bubble: CGRect, containerWidth: CGFloat) {
    guard mounted else { return }
    let next = StatusBubblePin.trailing(pointer: pointer, bubble: bubble, containerWidth: containerWidth, current: pinnedTrailing)
    if next != pinnedTrailing { pinnedTrailing = next }
  }

  public func reset() {
    presentationTimer?.cancel()
    presentationTimer = nil
    expansionTimer?.cancel()
    expansionTimer = nil
    presentation = .hidden
    lastStatus = ""
    text = ""
    expanded = false
    pinnedTrailing = false
  }

  private func clear() {
    switch presentation {
    case .pendingPresentation:
      reset()
    case .visible:
      schedule(.pendingDismissal, after: StatusBubbleTiming.hideDelay) { $0.dismiss() }
      if expansionTimer != nil {
        expansionTimer?.cancel()
        expansionTimer = nil
      }
    case .hidden, .pendingDismissal, .hiding:
      break
    }
  }

  private func present() {
    presentation = .visible
    scheduleExpansion()
  }

  private func dismiss() {
    presentation = .hiding
    schedule(.hiding, after: StatusBubbleTiming.fade) { $0.reset() }
  }

  private func schedule(_ state: Presentation, after seconds: Double, _ fire: @escaping @MainActor (StatusBubbleModel) -> Void) {
    presentationTimer?.cancel()
    presentation = state
    presentationTimer = clock.after(seconds) { [weak self] in
      guard let self else { return }
      self.presentationTimer = nil
      fire(self)
    }
  }

  private func scheduleExpansion() {
    expansionTimer?.cancel()
    expanded = false
    expansionTimer = clock.after(StatusBubbleTiming.expandDelay) { [weak self] in
      guard let self else { return }
      self.expansionTimer = nil
      self.expanded = true
    }
  }
}
