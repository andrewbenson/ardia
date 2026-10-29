import AppKit
import SolaraStore
import SwiftUI

public struct StoreUnavailableView: View {
  let failure: StoreUnavailable
  let appName: String
  let quit: () -> Void
  let showDataFolder: (URL) -> Void

  public init(failure: StoreUnavailable, appName: String, quit: @escaping () -> Void, showDataFolder: @escaping (URL) -> Void) {
    self.failure = failure
    self.appName = appName
    self.quit = quit
    self.showDataFolder = showDataFolder
  }

  public var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 40))
        .foregroundStyle(.yellow)
        .accessibilityHidden(true)
      Text(title)
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
      Text(explanation)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Text(failure.detail)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .multilineTextAlignment(.center)
        .lineLimit(4)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Details: \(failure.detail)")
      HStack(spacing: 10) {
        Button("Show Data Folder") {
          if let folder = failure.dataFolder { showDataFolder(folder) }
        }
        .disabled(failure.dataFolder == nil)
        Button("Quit \(appName)", action: quit)
          .keyboardShortcut(.defaultAction)
      }
      .controlSize(.large)
      .padding(.top, 6)
    }
    .padding(32)
    .frame(maxWidth: 480)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  var title: String {
    switch failure.cause {
    case .switchedOff: "Settings are off for this launch"
    case .refused, .openFailed: "\(appName) couldn't open its settings"
    }
  }

  var explanation: String {
    switch failure.cause {
    case .switchedOff:
      "\(appName) was started with its settings store switched off, so there are no settings to show. Quit and open \(appName) again without that switch."
    case .refused:
      "\(appName) couldn't safely read the file that holds your windows, tabs and settings, so it left the file as it was instead of risking your data. If a newer version of \(appName) wrote it, update \(appName) and open it again."
    case .openFailed:
      "\(appName) couldn't open its data folder. Nothing in it was changed, moved or reset. Quit and open \(appName) again; if this keeps happening, the details below say what went wrong."
    }
  }
}
