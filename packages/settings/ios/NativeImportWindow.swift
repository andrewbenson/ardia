import AppKit
import ArdiaShell
import Foundation
import SolaraUI
import SwiftUI

@MainActor
enum NativeImportWindow {
  static let kind = "import"

  nonisolated static var enabled: Bool {
    ProcessInfo.processInfo.environment["ARDIA_NATIVE_IMPORT"] != "0" && NativeSettingsWindow.enabled
  }

  static func makeController() -> NSViewController? {
    guard enabled else { return nil }
    let model = ImportModel(services: ImportAdapter(), appName: Bundle.main.productName)
    return ImportHostingController(model: model)
  }
}

@MainActor
final class ImportHostingController: NSHostingController<ImportWindowView> {
  let model: ImportModel
  private weak var observedWindow: NSWindow?

  init(model: ImportModel) {
    self.model = model
    super.init(rootView: ImportWindowView(model: model))
    sizingOptions = []
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func viewDidAppear() {
    super.viewDidAppear()
    guard observedWindow == nil, let window = view.window else { return }
    observedWindow = window
    NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
  }

  @objc private func windowWillClose(_ notification: Notification) {
    NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow)
    model.dispose()
  }
}
