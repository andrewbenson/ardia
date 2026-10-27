import AppKit

@MainActor
public enum ShellDrag {
  public static func windowId(of window: NSWindow) -> String? {
    WindowManager.shared.windows.first { $0.value === window }?.key
  }

  public static func window(_ id: String) -> NSWindow? {
    WindowManager.shared.windows[id]
  }

  public static func previewBegin(windowId: String, chip: NSRect, grab: NSPoint) {
    DragPreview.shared.begin(windowId: windowId, chip: chip, grab: grab)
  }

  public static func previewUpdate(_ shape: String, at local: NSPoint) {
    DragPreview.shared.update(shape: shape, at: local)
  }

  public static func previewEnd(windowId: String?, fallback: NSRect?) {
    DragPreview.shared.end(windowId: windowId, fallback: fallback)
  }

  public static func previewCancel() {
    DragPreview.shared.cancel()
  }

  public static func focus(_ id: String) {
    WindowManager.shared.focus(id: id)
  }
}
