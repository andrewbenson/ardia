import AppKit
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
struct ImportSnapshotTests {
  static let size = NSSize(width: 640, height: 600)
  static let tallSize = NSSize(width: 640, height: 1400)

  func model(_ configure: (FakeImportServices) -> Void = { _ in }) async -> (ImportModel, FakeImportServices) {
    let services = FakeImportServices()
    configure(services)
    let model = ImportModel(services: services, appName: "Solara")
    model.doneDelay = .zero
    await model.start()
    return (model, services)
  }

  func render(_ model: ImportModel, _ name: String) async throws {
    guard let directory = Snapshot.directory else { return }
    for dark in [false, true] {
      let folder = directory.appendingPathComponent("import")
      let scheme = dark ? "dark" : "light"
      try await Snapshot.render(ImportWindowView(model: model, starts: false), size: Self.size, dark: dark, to: folder.appendingPathComponent("\(name)-\(scheme).png"))
      try await Snapshot.render(ImportWindowView(model: model, starts: false), size: Self.tallSize, dark: dark, to: folder.appendingPathComponent("\(name)-\(scheme)-full.png"))
    }
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersEveryStep() async throws {
    let (choose, _) = await model()
    try await render(choose, "choose")

    let (arc, _) = await model()
    arc.choose(ImportFixtures.arc)
    try await render(arc, "choose-arc")
    await arc.next()
    try await render(arc, "spaces")

    let (zen, _) = await model()
    zen.choose(ImportFixtures.zen)
    await zen.next()
    try await render(zen, "spaces-zen")

    let (profiles, _) = await model()
    await profiles.next()
    try await render(profiles, "profiles")
    profiles.sourceProfiles = ["Default", "Profile 1"]
    await profiles.next()
    try await render(profiles, "unlock")
    await profiles.unlock()

    let (refused, _) = await model { $0.unlockSucceeds = false }
    refused.choose(ImportFixtures.brave)
    await refused.next()
    await refused.unlock()
    try await render(refused, "unlock-error")

    let (empty, _) = await model { $0.browsers = [] }
    try await render(empty, "choose-empty")

    let (unavailable, _) = await model { $0.opening = ImportOpening(available: false, preferredSource: nil, targets: [], defaultTarget: "default") }
    try await render(unavailable, "choose-unavailable")

    let (safari, _) = await model()
    safari.choose(ImportFixtures.safari)
    await safari.next()
    try await render(safari, "safari-access")
    safari.fullDiskAccess = true
    try await render(safari, "safari-direct")
    safari.error = "Couldn't read Safari's data. Try the export file below."
    try await render(safari, "safari-error")

    let (access, _) = await model()
    access.choose(ImportFixtures.firefox)
    await access.next()
    try await render(access, "access")

    let (dia, _) = await model()
    dia.choose(ImportFixtures.dia)
    try await render(dia, "choose-dia")
    dia.step = .dia
    for status in [DiaStatus.checking, .notInstalled, .notRunning, .notDetermined, .denied, .granted] {
      dia.diaStatus = status
      try await render(dia, "dia-\(status.rawValue)")
    }
    await dia.refreshDia()
    try await render(dia, "dia-profiles")

    let (progress, services) = await model { $0.holdRun = true; $0.unlocked = ["chrome"] }
    progress.sourceProfiles = ["Default", "Profile 1"]
    progress.goBack(to: .profiles)
    let running = Task { await progress.next() }
    while services.requests.isEmpty { await Task.yield() }
    progress.take(ImportProgressUpdate(runId: progress.runId!, preparing: 2, status: [.bookmarks: .done, .history: .done, .passwords: .active, .cookies: .pending, .autofill: .pending, .tabs: .failed]))
    try await render(progress, "progress")
    services.release(ImportRunOutcome(
      status: [:],
      failures: [ImportFailure(kind: .passwords, profiles: ["Person 1", "Work"]), ImportFailure(kind: .cookies, profiles: ["Work"])],
      counts: ImportCounts(bookmarks: 312, history: 4210, tabs: 18),
      notes: ["2 cookies couldn't be decrypted."],
      extensionsProfile: "default",
      extensions: [
        ImportedExtension(id: "a", name: "uBlock Origin Lite", webStoreUrl: "https://chromewebstore.google.com/detail/a"),
        ImportedExtension(id: "b", name: "1Password", webStoreUrl: "https://chromewebstore.google.com/detail/b"),
      ]
    ))
    await running.value
    try await render(progress, "done-partial")

    let (done, doneServices) = await model { $0.unlocked = ["brave"]; $0.arcHolders = 1 }
    doneServices.outcome = ImportRunOutcome(
      counts: ImportCounts(bookmarks: 312, history: 4210, tabs: 18, passwords: 64, cookies: 950, addresses: 2, cards: 1),
      notes: ["40 links in Work's folders weren't imported: each folder brings up to 500 links."],
      extensionsProfile: "default",
      extensions: [ImportedExtension(id: "a", name: "uBlock Origin Lite", webStoreUrl: "https://chromewebstore.google.com/detail/a")]
    )
    done.choose(ImportFixtures.brave)
    await done.next()
    try await render(done, "done")
    done.openInWebStore()
    try await render(done, "done-extensions-opened")

    let (nothing, nothingServices) = await model { $0.unlocked = ["brave"] }
    nothingServices.outcome = ImportRunOutcome(counts: ImportCounts())
    nothing.choose(ImportFixtures.brave)
    await nothing.next()
    try await render(nothing, "done-nothing")

    let (failed, failedServices) = await model { $0.unlocked = ["brave"] }
    failedServices.outcome = ImportRunOutcome(failures: [ImportFailure(kind: .bookmarks), ImportFailure(kind: .history)])
    failed.choose(ImportFixtures.brave)
    await failed.next()
    try await render(failed, "done-failed")
  }
}
