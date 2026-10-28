import AppKit
import SolaraLive

public struct SidebarMeetingCountdown: Equatable, Sendable {
  public static let showWithinMinutes = 10.0
  public static let urgentMinutes = 2.0
  public static let wiggleMarks = [5.0, 2.0]

  public let minutesLeft: Double?
  public let label: String?
  public let urgent: Bool

  public init(_ meeting: MeetingGroup?, now: Double) {
    guard let meeting, meeting.endedAt == nil, let end = meeting.end else {
      minutesLeft = nil
      label = nil
      urgent = false
      return
    }
    let left = (end - now) / 60_000
    minutesLeft = left
    label = left <= Self.showWithinMinutes ? Self.timeRemaining(end: end, now: now) : nil
    urgent = left <= Self.urgentMinutes
  }

  public static func timeRemaining(end: Double, now: Double) -> String {
    let minutes = Int(((end - now) / 60_000).rounded(.up))
    if minutes <= 0 { return "Ending now" }
    return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min left" : "\(minutes) min left"
  }

  public static func dueWiggles(groupId: String, minutesLeft: Double, done: inout Set<String>) -> Bool {
    let due = wiggleMarks.filter { minutesLeft <= $0 && minutesLeft > $0 - 1 && !done.contains("\(groupId):\($0)") }
    for mark in wiggleMarks where minutesLeft <= mark - 1 { done.insert("\(groupId):\(mark)") }
    for mark in due { done.insert("\(groupId):\(mark)") }
    return !due.isEmpty
  }

  @MainActor static var wiggled = Set<String>()

  static func nowColor(dark: Bool) -> NSColor {
    NSColor(srgbRed: dark ? 0xE5 / 255 : 0xD1 / 255, green: dark ? 0x53 / 255 : 0x24 / 255, blue: dark ? 0x4B / 255 : 0x2F / 255, alpha: 1)
  }

  static func wiggle(around size: CGSize) -> CAKeyframeAnimation {
    let steps: [(CGFloat, Double)] = [(1, 0.07), (-1, 0.11), (0.8, 0.11), (-0.6, 0.11), (0.3, 0.10), (0, 0.09)]
    let total = steps.reduce(0) { $0 + $1.1 }
    func turned(_ amount: CGFloat) -> NSValue {
      var t = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
      t = CATransform3DRotate(t, amount * 4 * .pi / 180, 0, 0, 1)
      return NSValue(caTransform3D: CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0))
    }
    var values: [NSValue] = [turned(0)]
    var times: [NSNumber] = [0]
    var at = 0.0
    for (value, duration) in steps {
      at += duration
      values.append(turned(value))
      times.append(NSNumber(value: at / total))
    }
    let turn = CAKeyframeAnimation(keyPath: "sublayerTransform")
    turn.values = values
    turn.keyTimes = times
    turn.duration = total
    turn.timingFunctions = Array(repeating: CAMediaTimingFunction(controlPoints: 0.455, 0.03, 0.515, 0.955), count: steps.count)
    return turn
  }
}
