import AppKit

public enum ToolbarAutoHideMode: String, Sendable, Equatable {
  case shown, collapsed, peek
}

public struct ToolbarAutoHideInput: Sendable, Equatable {
  public var enabled: Bool
  public var hasPage: Bool
  public var scrolledDown: Bool
  public var peek: Bool
  public var needsBar: Bool

  public init(enabled: Bool, hasPage: Bool, scrolledDown: Bool, peek: Bool, needsBar: Bool) {
    self.enabled = enabled
    self.hasPage = hasPage
    self.scrolledDown = scrolledDown
    self.peek = peek
    self.needsBar = needsBar
  }

  public var mode: ToolbarAutoHideMode {
    if !enabled || !hasPage || !scrolledDown || needsBar { return .shown }
    return peek ? .peek : .collapsed
  }
}

public enum ToolbarAutoHideMetrics {
  public static let toolbarHeight: CGFloat = 41
  public static let stripHeight: CGFloat = 20
  public static var barRoom: CGFloat { toolbarHeight - stripHeight }
  public static let hide = (duration: 0.15, easing: RNEasing.outQuad)
  public static let show = (duration: 0.2, easing: RNEasing.outCubic)
  public static let peekDelay: TimeInterval = 0.15
  public static let unpeekDelay: TimeInterval = 0.25
  public static let bandEaseDuration: TimeInterval = 0.18
  public static let shrink: CGFloat = 0.94
  public static let labelSize: CGFloat = 11
  public static let labelPadding: CGFloat = 12
}

public enum ToolbarAutoHideCurves {
  static func piecewise(_ x: Double, _ input: [Double], _ output: [Double]) -> Double {
    if x <= input[0] { return output[0] }
    for i in 1..<input.count where x <= input[i] {
      let t = (x - input[i - 1]) / (input[i] - input[i - 1])
      return output[i - 1] + (output[i] - output[i - 1]) * t
    }
    return output[output.count - 1]
  }

  public static func controlsOpacity(fade: Double) -> Double { piecewise(fade, [0, 0.2, 0.4, 0.6, 1], [1, 0.45, 0.15, 0, 0]) }

  public static func labelOpacity(fade: Double) -> Double { piecewise(fade, [0, 0.5, 1], [0, 0, 1]) }

  public static func toolbarScale(bar: Double) -> Double { 1 + (Double(ToolbarAutoHideMetrics.shrink) - 1) * bar }

  public static func toolbarLift(bar: Double) -> Double {
    let h = Double(ToolbarAutoHideMetrics.toolbarHeight)
    return (-((1 - Double(ToolbarAutoHideMetrics.shrink)) * h) / 2 - 3) * bar
  }

  public static func bandScale(bar: Double) -> Double {
    1 + (Double(ToolbarAutoHideMetrics.stripHeight / ToolbarAutoHideMetrics.toolbarHeight) - 1) * bar
  }

  public static func bandLift(bar: Double) -> Double { -Double(ToolbarAutoHideMetrics.barRoom) / 2 * bar }

  public static func dividerLift(bar: Double) -> Double { -Double(ToolbarAutoHideMetrics.barRoom) * bar }

  public static func pageShift(laid: Double, page: Double, room: Double) -> Double { (laid - page) * room }

  public static func liveTop(laid: Double, page: Double, collapsed: Bool, shownTop: Double) -> Double {
    let strip = Double(ToolbarAutoHideMetrics.stripHeight)
    return (collapsed ? strip : shownTop) + pageShift(laid: laid, page: page, room: shownTop - strip)
  }
}

public struct ToolbarAutoHideTransition: Sendable, Equatable {
  public var page: RNTween
  public var bar: RNTween
  public var fade: RNTween
  public var laid: Double

  public static func between(_ from: ToolbarAutoHideMode, _ to: ToolbarAutoHideMode, current: (page: Double, bar: Double, fade: Double), at now: CFTimeInterval, reduceMotion: Bool) -> ToolbarAutoHideTransition? {
    let wasCollapsed = from != .shown
    let collapsed = to != .shown
    let hidden = to == .collapsed
    let wasHidden = from == .collapsed
    if wasCollapsed == collapsed && wasHidden == hidden { return nil }
    func glide(_ start: Double, _ end: Double, show: Bool) -> RNTween {
      let spec = show ? ToolbarAutoHideMetrics.show : ToolbarAutoHideMetrics.hide
      return RNTween(from: start, to: end, start: now, duration: spec.duration, easing: spec.easing)
    }
    let barTo = hidden ? 1.0 : 0
    if wasCollapsed != collapsed {
      let to = collapsed ? 1.0 : 0
      if reduceMotion {
        return ToolbarAutoHideTransition(page: .resting(to), bar: .resting(barTo), fade: glide(current.fade, barTo, show: !collapsed), laid: to)
      }
      return ToolbarAutoHideTransition(page: glide(current.page, to, show: !collapsed), bar: glide(current.bar, barTo, show: !collapsed), fade: glide(current.fade, barTo, show: !collapsed), laid: to)
    }
    if !hidden {
      return ToolbarAutoHideTransition(page: .resting(current.page), bar: .resting(0), fade: .resting(0), laid: current.page)
    }
    if reduceMotion {
      return ToolbarAutoHideTransition(page: .resting(current.page), bar: .resting(1), fade: glide(current.fade, 1, show: false), laid: current.page)
    }
    return ToolbarAutoHideTransition(page: .resting(current.page), bar: glide(current.bar, 1, show: false), fade: glide(current.fade, 1, show: false), laid: current.page)
  }
}

