import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct ToolbarPressTests {
  static let palette = ToolbarPaletteState(
    background: nil, text: "#000000CC", secondary: "#00000080", icon: "#000000D4", iconDisabled: "#0000006E", hover: "#0000000F",
    pressed: "#0000001A", pill: "#0000000A", divider: "#0000001A", urlHost: nil, urlPath: nil)

  static func window(holding control: NSView, coveredUpTo cover: CGFloat) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    window.contentView = root
    control.frame = NSRect(x: 0, y: 50, width: 300, height: 30)
    root.addSubview(control)
    root.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: cover, height: 100)))
    return window
  }

  static func mouse(_ type: NSEvent.EventType, _ x: CGFloat, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: NSPoint(x: x, y: 65), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
  }

  static func click(_ view: NSView, at x: CGFloat, in window: NSWindow) {
    view.mouseDown(with: mouse(.leftMouseDown, x, in: window))
    view.mouseUp(with: mouse(.leftMouseUp, x, in: window))
  }

  @Test func theAddressFieldTakesOnlyPressesThatLandOnIt() {
    let field = ToolbarUrlFieldView(frame: .zero)
    var clicks: [ToolbarClick.Kind] = []
    field.onClick = { clicks.append($0.kind) }
    let window = Self.window(holding: field, coveredUpTo: 150)
    Self.click(field, at: 100, in: window)
    field.rightMouseDown(with: Self.mouse(.rightMouseDown, 100, in: window))
    #expect(clicks.isEmpty)
    Self.click(field, at: 200, in: window)
    field.rightMouseDown(with: Self.mouse(.rightMouseDown, 200, in: window))
    #expect(clicks == [.press, .menu])
  }

  @Test func aToolbarButtonTakesOnlyPressesThatLandOnIt() throws {
    let state = try JSONDecoder().decode(ToolbarButtonState.self, from: Data(#"{"id":"back","icon":"chevron.left","menu":true}"#.utf8))
    let button = ToolbarButtonView(state: state, palette: Self.palette)
    var clicks: [ToolbarClick.Kind] = []
    button.onClick = { clicks.append($0.kind) }
    let window = Self.window(holding: button, coveredUpTo: 150)
    Self.click(button, at: 100, in: window)
    button.rightMouseDown(with: Self.mouse(.rightMouseDown, 100, in: window))
    #expect(clicks.isEmpty)
    Self.click(button, at: 200, in: window)
    button.rightMouseDown(with: Self.mouse(.rightMouseDown, 200, in: window))
    #expect(clicks == [.press, .menu])
  }
}
