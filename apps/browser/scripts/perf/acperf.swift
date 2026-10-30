import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit

let args = CommandLine.arguments
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func nanos(_ ticks: UInt64) -> UInt64 { ticks * UInt64(timebase.numer) / UInt64(timebase.denom) }
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

func rusage(_ pid: pid_t) -> [String: Any]? {
  var info = rusage_info_v4()
  let rc = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
  }
  guard rc == 0 else { return nil }
  return [
    "pid": pid,
    "cpuNs": nanos(info.ri_user_time) + nanos(info.ri_system_time),
    "idleWakeups": info.ri_pkg_idle_wkups,
    "interruptWakeups": info.ri_interrupt_wkups,
    "footprint": info.ri_phys_footprint,
    "resident": info.ri_resident_size,
    "energyNj": info.ri_billed_energy,
    "at": nowMs(),
  ]
}

func windows(_ pid: pid_t) -> [[String: Any]] {
  guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
  return list.compactMap { w in
    guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { return nil }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return ["id": w[kCGWindowNumber as String] ?? 0, "layer": w[kCGWindowLayer as String] ?? 0,
            "alpha": w[kCGWindowAlpha as String] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0, "x": b["X"] ?? 0, "y": b["Y"] ?? 0]
  }
}

func hidIdleNs() -> UInt64? {
  let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
  guard service != 0 else { return nil }
  defer { IOObjectRelease(service) }
  return (IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
    .takeRetainedValue() as? NSNumber)?.uint64Value
}

let dragLock = NSLock()
nonisolated(unsafe) var dragButtonDown = false
nonisolated(unsafe) var dragFinished = false
nonisolated(unsafe) var dragStop: String? = nil

func postMouseUp() {
  let at = CGEvent(source: nil)?.location ?? .zero
  CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func printJSON(_ value: Any) {
  let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  print(String(data: data, encoding: .utf8)!)
}

switch args.count > 1 ? args[1] : "" {
case "rusage":
  for p in args.dropFirst(2) { if let pid = pid_t(p), let r = rusage(pid) { printJSON(r) } }
case "windows":
  printJSON(windows(pid_t(args[2]) ?? 0))
case "hididle":
  guard let idle = hidIdleNs() else { exit(1) }
  print(idle)
case "activate":
  exit(NSRunningApplication(processIdentifier: pid_t(args[2]) ?? 0)?.activate() == true ? 0 : 1)
case "display":
  let session = CGSessionCopyCurrentDictionary() as? [String: Any]
  printJSON(["asleep": CGDisplayIsAsleep(CGMainDisplayID()) != 0, "locked": (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false])
case "quit":
  exit(NSRunningApplication(processIdentifier: pid_t(args[2]) ?? 0)?.terminate() == true ? 0 : 1)
case "waitwindow":
  let pid = pid_t(args[2]) ?? 0
  let deadline = Date().addingTimeInterval(Double(args[3]) ?? 30)
  while Date() < deadline {
    if windows(pid).contains(where: { ($0["w"] as? Double ?? 0) >= 300 && ($0["h"] as? Double ?? 0) >= 200 && ($0["alpha"] as? Double ?? 0) > 0 }) {
      print(String(format: "%.0f", nowMs()))
      exit(0)
    }
    if kill(pid, 0) != 0 { exit(3) }
    usleep(4000)
  }
  exit(2)
case "newwindow":
  let pid = pid_t(args[2]) ?? 0
  let deadline = Date().addingTimeInterval(Double(args[3]) ?? 30)
  let shown = { windows(pid).filter { ($0["w"] as? Double ?? 0) >= 300 && ($0["h"] as? Double ?? 0) >= 200 && ($0["alpha"] as? Double ?? 0) > 0 } }
  let before = Set(shown().compactMap { $0["id"] as? Int })
  print("ready")
  fflush(stdout)
  while Date() < deadline {
    if let new = shown().first(where: { !before.contains($0["id"] as? Int ?? 0) }) {
      print(String(format: "{\"at\":%.1f,\"id\":%d}", nowMs(), new["id"] as? Int ?? 0))
      exit(0)
    }
    if kill(pid, 0) != 0 { exit(3) }
    usleep(2000)
  }
  exit(2)
case "input":
  let pid = pid_t(args[2]) ?? 0
  let tick = 0.25
  let deadline = Date().addingTimeInterval(Double(args[3]) ?? 60)
  guard hidIdleNs() != nil else {
    printJSON(["error": "no HIDIdleTime"])
    exit(1)
  }
  func overOwnWindow(_ at: CGPoint) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }
    for w in list {
      guard let layer = w[kCGWindowLayer as String] as? Int, layer < 20, (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
            let b = w[kCGWindowBounds as String] as? [String: Double],
            CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(at)
      else { continue }
      return (w[kCGWindowOwnerPID as String] as? Int32) == pid
    }
    return false
  }
  var input = 0, over = 0
  var last = CGEvent(source: nil)?.location
  while Date() < deadline {
    usleep(UInt32(tick * 1e6))
    let at = CGEvent(source: nil)?.location
    defer { last = at }
    guard let idle = hidIdleNs(), Double(idle) < tick * 1e9 else { continue }
    input += 1
    if let at, at != last, overOwnWindow(at) { over += 1 }
  }
  printJSON(["inputSecs": Double(input) * tick, "overWindowSecs": Double(over) * tick])
case "postkeys":
  guard args.count >= 5, let pid = pid_t(args[2]), pid > 1, let gap = Double(args[3]) else {
    FileHandle.standardError.write("usage: acperf postkeys <pid> <gap ms> <spec>...\n".data(using: .utf8)!)
    exit(64)
  }
  guard CGPreflightPostEventAccess() else {
    FileHandle.standardError.write("acperf postkeys: macOS event-posting access denied; allow the benchmark runner in Accessibility before timing\n".data(using: .utf8)!)
    exit(77)
  }
  let codes: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49,
  ]
  let shifted: [Character: Character] = ["?": "/", ":": ";", "_": "-", "+": "=", "&": "7"]
  let named: [String: UInt16] = ["enter": 36, "return": 36, "tab": 48, "esc": 53, "escape": 53, "delete": 51, "space": 49, "down": 125, "up": 126]
  let source = CGEventSource(stateID: .combinedSessionState)
  func press(_ code: UInt16, _ flags: CGEventFlags, _ chars: String?) -> Double {
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let at = nowMs()
    down?.flags = flags
    if let chars { down?.keyboardSetUnicodeString(stringLength: chars.utf16.count, unicodeString: Array(chars.utf16)) }
    down?.postToPid(pid)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    up?.flags = flags
    up?.postToPid(pid)
    return at
  }
  for spec in args.dropFirst(4) {
    var first = 0.0
    if spec.hasPrefix("text:") {
      for (i, ch) in spec.dropFirst(5).enumerated() {
        let shift = shifted[ch] != nil || (ch.isUppercase)
        let base = shifted[ch] ?? Character(ch.lowercased())
        guard let code = codes[base] else {
          FileHandle.standardError.write("acperf postkeys: no key for \(ch)\n".data(using: .utf8)!)
          exit(64)
        }
        let at = press(code, shift ? .maskShift : [], String(ch))
        if i == 0 { first = at }
        if gap > 0 { usleep(UInt32(gap * 1000)) }
      }
    } else {
      var flags: CGEventFlags = []
      var key = ""
      for part in spec.split(separator: "+").map(String.init) {
        switch part {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default: key = part
        }
      }
      guard let code = named[key] ?? key.first.flatMap({ key.count == 1 ? codes[$0] : nil }) else {
        FileHandle.standardError.write("acperf postkeys: no key for \(spec)\n".data(using: .utf8)!)
        exit(64)
      }
      first = press(code, flags, flags.isEmpty && key.count == 1 ? key : nil)
    }
    printJSON(["spec": spec, "at": (first * 10).rounded() / 10])
    fflush(stdout)
  }
case "postscroll":
  guard args.count >= 9, let pid = pid_t(args[2]), pid > 1, let window = Int64(args[3]), let x = Double(args[4]), let y = Double(args[5]),
        let windowX = Double(args[6]), let windowY = Double(args[7]) else {
    FileHandle.standardError.write("usage: acperf postscroll <pid> <window id> <x> <y> <window x> <window y> trackpad|fingers|wheel [events/s]\n".data(using: .utf8)!)
    exit(64)
  }
  let gesture = args[8]
  let rate = args.count > 9 ? Double(args[9]) ?? 120 : 120
  let point = CGPoint(x: x, y: y)
  typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
  let setWindowLocation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation").map { unsafeBitCast($0, to: SetWindowLocation.self) }
  func scroll(_ dy: Double, phase: Int64 = 0, momentum: Int64 = 0, continuous: Bool = true) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: continuous ? .pixel : .line, wheelCount: 1,
                              wheel1: Int32(continuous ? dy.rounded() : (dy < 0 ? -1 : 1)), wheel2: 0, wheel3: 0) else { return }
    event.location = point
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
    if continuous {
      event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
      event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
      event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(max(-10, min(10, (dy / 10).rounded()))))
      event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
      event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    }
    event.setIntegerValueField(CGEventField(rawValue: 51)!, value: window)
    setWindowLocation?(event, CGPoint(x: x - windowX, y: y - windowY))
    event.postToPid(pid)
  }
  let tick = 1 / rate
  let start = Date().timeIntervalSince1970
  var elapsed = 0.0
  func wait(_ seconds: Double) {
    elapsed += seconds
    var left = start + elapsed - Date().timeIntervalSince1970
    while left > 0 {
      if left > 0.002 { usleep(useconds_t((left - 0.0015) * 1e6)) }
      left = start + elapsed - Date().timeIntervalSince1970
    }
  }
  var events = 0
  switch gesture {
  case "trackpad", "fingers":
    scroll(0, phase: 128)
    wait(tick)
    let fingerEvents = Int((0.3 * rate).rounded())
    for i in 0..<fingerEvents {
      scroll(-(4 + 22 * sin(Double(i) / Double(fingerEvents) * .pi * 0.85)) * 120 / rate, phase: i == 0 ? 1 : 2)
      events += 1
      wait(tick)
    }
    scroll(0, phase: 4)
    wait(tick)
    if gesture == "trackpad" {
      var velocity = -24.0 * 120 / rate
      var first = true
      while abs(velocity) > 0.4 * 120 / rate {
        scroll(velocity, momentum: first ? 1 : 2)
        first = false
        events += 1
        velocity *= pow(0.972, 120 / rate)
        wait(tick)
      }
      scroll(0, momentum: 3)
    }
  case "wheel":
    for _ in 0..<12 {
      scroll(-1, continuous: false)
      events += 1
      wait(0.09)
    }
  default:
    FileHandle.standardError.write("acperf postscroll: no gesture \(gesture)\n".data(using: .utf8)!)
    exit(64)
  }
  printJSON(["events": events, "ms": Int((Date().timeIntervalSince1970 - start) * 1000)])
case "postmouse":
  guard args.count >= 9, let pid = pid_t(args[2]), pid > 1, let window = Int64(args[3]), let x = Double(args[4]), let y = Double(args[5]),
        let windowX = Double(args[6]), let windowY = Double(args[7]), let holdMs = Double(args[8]) else {
    FileHandle.standardError.write("usage: acperf postmouse <pid> <window id> <x> <y> <window x> <window y> <hold ms> [left|middle|right]\n".data(using: .utf8)!)
    exit(64)
  }
  let button = args.count > 9 ? args[9] : "left"
  let middle = button == "middle"
  let right = button == "right"
  typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
  let setWindowLocation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation").map { unsafeBitCast($0, to: SetWindowLocation.self) }
  func click(_ type: CGEventType) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: middle ? .center : right ? .right : .left) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.setIntegerValueField(CGEventField(rawValue: 51)!, value: window)
    setWindowLocation?(event, CGPoint(x: x - windowX, y: y - windowY))
    event.postToPid(pid)
  }
  click(middle ? .otherMouseDown : right ? .rightMouseDown : .leftMouseDown)
  usleep(useconds_t(holdMs * 1000))
  click(middle ? .otherMouseUp : right ? .rightMouseUp : .leftMouseUp)
  printJSON(["heldMs": holdMs])
case "dragguard":
  var last: UInt8 = UInt8(ascii: "u")
  var byte: UInt8 = 0
  while read(0, &byte, 1) == 1 { last = byte }
  if last == UInt8(ascii: "d") { postMouseUp() }
case "mouseup":
  postMouseUp()
  printJSON(["posted": "mouseup"])
case "postdrag":
  let pair = { (text: String) -> CGPoint? in
    let parts = text.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2, parts.allSatisfy({ $0.isFinite && abs($0) <= 20_000 }) else { return nil }
    return CGPoint(x: parts[0], y: parts[1])
  }
  guard args.count >= 8, let pid = pid_t(args[2]), pid > 1, let window = CGWindowID(args[3]), let from = pair(args[4]), let delta = pair(args[5]),
        abs(delta.x) <= 2000, abs(delta.y) <= 2000, let steps = Int(args[6]), steps > 0, steps <= 400, let gap = Double(args[7]), gap.isFinite, gap >= 1, gap <= 50
  else {
    FileHandle.standardError.write("usage: acperf postdrag <pid> <window id> <from x,y> <dx,dy ≤ 2000> <steps ≤ 400> <gap ms 1–50> [line|wiggle]\n".data(using: .utf8)!)
    exit(64)
  }
  let shape = args.count > 8 ? args[8] : "line"
  func origin() -> CGPoint? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]],
          let b = list.first?[kCGWindowBounds as String] as? [String: Double] else { return nil }
    return CGPoint(x: b["X"] ?? 0, y: b["Y"] ?? 0)
  }
  func onScreen() -> [[String: Any]] { (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [] }
  func ownerOf(_ w: [String: Any]) -> pid_t { (w[kCGWindowOwnerPID as String] as? Int32) ?? 0 }
  func ours() -> String? {
    CFRunLoopRunInMode(.defaultMode, 0, true)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return "pid \(pid) isn't the frontmost app" }
    let list = onScreen()
    guard let front = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }), ownerOf(front) == pid else {
      return "the frontmost normal window isn't pid \(pid)'s"
    }
    guard let top = list.first(where: { w in
      guard let b = w[kCGWindowBounds as String] as? [String: Double] else { return false }
      return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(from)
    }) else { return "no window under \(from)" }
    let topId = (top[kCGWindowNumber as String] as? UInt32) ?? 0
    guard ownerOf(top) == pid, topId == window else { return "the window under \(from) is \(topId) of pid \(ownerOf(top)), not \(window) of pid \(pid)" }
    return nil
  }
  func finish(_ body: [String: Any], code: Int32) -> Never {
    dragLock.withLock {
      if dragButtonDown { postMouseUp() }
      dragButtonDown = false
      dragFinished = true
    }
    printJSON(body)
    exit(code)
  }
  if let why = ours() { finish(["error": why, "posted": "nothing"], code: 2) }
  guard let start = origin() else { finish(["error": "no window \(window)", "posted": "nothing"], code: 2) }
  atexit {
    dragLock.withLock {
      if dragButtonDown { postMouseUp() }
      dragButtonDown = false
    }
  }
  var signalSources: [DispatchSourceSignal] = []
  for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler {
      dragLock.withLock { dragStop = "signal \(sig)" }
      usleep(300_000)
      dragLock.withLock {
        guard !dragFinished else { return }
        if dragButtonDown { postMouseUp() }
        dragButtonDown = false
        dragFinished = true
      }
      _exit(128 + sig)
    }
    source.resume()
    signal(sig, SIG_IGN)
    signalSources.append(source)
  }
  var guardPipe: [Int32] = [-1, -1]
  if pipe(&guardPipe) == 0 {
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, guardPipe[0], 0)
    posix_spawn_file_actions_addclose(&actions, guardPipe[1])
    var attrs: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attrs)
    posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID))
    var guardPid: pid_t = 0
    let exe = CommandLine.arguments[0]
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), strdup("dragguard"), nil]
    let spawned = posix_spawn(&guardPid, exe, &actions, &attrs, argv, environ)
    argv.forEach { free($0) }
    close(guardPipe[0])
    if spawned != 0 { finish(["error": "couldn't start the drag guard", "posted": "nothing"], code: 2) }
  } else {
    finish(["error": "couldn't open the drag guard's pipe", "posted": "nothing"], code: 2)
  }
  func tellGuard(_ c: UInt8) {
    var byte = c
    _ = write(guardPipe[1], &byte, 1)
  }
  let deadline = DispatchSource.makeTimerSource(queue: .global())
  deadline.schedule(deadline: .now() + .milliseconds(Int(Double(steps) * gap * 3) + 10_000))
  deadline.setEventHandler { dragLock.withLock { dragStop = "its own deadline" } }
  deadline.resume()
  var lastPoint = from
  func post(_ type: CGEventType, _ at: CGPoint, delta d: CGPoint = .zero) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left) else { return }
    if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
    if type == .leftMouseDragged {
      event.setIntegerValueField(.mouseEventDeltaX, value: Int64(d.x.rounded()))
      event.setIntegerValueField(.mouseEventDeltaY, value: Int64(d.y.rounded()))
    }
    event.post(tap: .cghidEventTap)
  }
  func point(_ i: Int) -> CGPoint {
    if shape == "wiggle" {
      let phase = Double(i % 20) / 10
      let tri = phase <= 1 ? phase : 2 - phase
      return CGPoint(x: from.x + delta.x * tri, y: from.y + delta.y * tri)
    }
    let f = Double(i) / Double(steps)
    return CGPoint(x: from.x + delta.x * f, y: from.y + delta.y * f)
  }
  post(.mouseMoved, from)
  usleep(50_000)
  if let why = ours() { finish(["error": why, "posted": "the pointer moved to the start, no button"], code: 2) }
  let downAt = nowMs()
  let stoppedBeforeDown: String? = dragLock.withLock {
    if let stop = dragStop { return stop }
    tellGuard(UInt8(ascii: "d"))
    dragButtonDown = true
    post(.leftMouseDown, from)
    return nil
  }
  if let stop = stoppedBeforeDown { finish(["error": "stopped by \(stop) before the button went down", "posted": "the pointer only"], code: 2) }
  var rows: [[String: Any]] = []
  var firstMove: [String: Any]? = nil
  var aborted: String? = nil
  for i in 1...steps {
    CFRunLoopRunInMode(.defaultMode, 0, true)
    if let stop = dragLock.withLock({ dragStop }) {
      aborted = "stopped by \(stop) at step \(i)"
      break
    }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
      aborted = "pid \(pid) stopped being frontmost at step \(i)"
      break
    }
    let p = point(i)
    let at = nowMs()
    post(.leftMouseDragged, p, delta: CGPoint(x: p.x - lastPoint.x, y: p.y - lastPoint.y))
    lastPoint = p
    usleep(useconds_t(gap * 1000))
    guard let w = origin() else { continue }
    let read = nowMs()
    rows.append(["i": i, "at": at - downAt, "read": read - downAt, "px": p.x, "py": p.y, "wx": w.x - start.x, "wy": w.y - start.y,
                 "trail": hypot((p.x - from.x) - (w.x - start.x), (p.y - from.y) - (w.y - start.y))])
    if firstMove == nil && (w.x != start.x || w.y != start.y) {
      firstMove = ["ms": read - downAt, "travelPt": hypot(p.x - from.x, p.y - from.y), "step": i, "resolutionMs": gap]
    }
  }
  dragLock.withLock {
    if dragButtonDown {
      dragButtonDown = false
      post(.leftMouseUp, lastPoint)
    }
    tellGuard(UInt8(ascii: "u"))
  }
  usleep(200_000)
  let end = origin() ?? start
  let endError = hypot((lastPoint.x - from.x) - (end.x - start.x), (lastPoint.y - from.y) - (end.y - start.y))
  let trails = rows.compactMap { $0["trail"] as? Double }.sorted()
  finish(["shape": shape, "steps": steps, "gapMs": gap, "firstMove": firstMove ?? NSNull(), "endErrorPt": endError, "aborted": aborted ?? NSNull(),
          "movedX": end.x - start.x, "movedY": end.y - start.y,
          "trailMedianPt": trails.isEmpty ? 0 : trails[trails.count / 2], "trailMaxPt": trails.last ?? 0, "rows": rows], code: aborted == nil ? 0 : 3)
default:
  FileHandle.standardError.write("usage: acperf rusage <pid>... | windows <pid> | hididle | activate <pid> | display | quit <pid> | waitwindow <pid> <secs> | newwindow <pid> <secs> | input <pid> <secs> | postkeys <pid> <gap ms> <spec>... | postscroll <pid> <window id> <x> <y> <window x> <window y> <gesture> [events/s] | postmouse <pid> <window id> <x> <y> <window x> <window y> <hold ms> [left|middle|right] | postdrag <pid> <window id> <from x,y> <dx,dy> <steps> <gap ms> [line|wiggle] | mouseup\n".data(using: .utf8)!)
  exit(64)
}
