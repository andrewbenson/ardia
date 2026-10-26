// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "SolaraKit",
  platforms: [.macOS("26.0"), .iOS("26.0")],
  products: [
    .library(name: "SolaraModel", targets: ["SolaraModel"]),
    .library(name: "SolaraStore", targets: ["SolaraStore"]),
    .library(name: "SolaraPersistence", targets: ["SolaraPersistence"]),
    .library(name: "SolaraBridgeCore", targets: ["SolaraBridgeCore"]),
    .library(name: "SolaraOmnibox", targets: ["SolaraOmnibox"]),
    .library(name: "SolaraSync", targets: ["SolaraSync"]),
    .library(name: "SolaraImport", targets: ["SolaraImport"]),
    .library(name: "SolaraEngine", targets: ["SolaraEngine"]),
    .library(name: "SolaraUI", targets: ["SolaraUI"]),
    .library(name: "SolaraSignposts", targets: ["SolaraSignposts"]),
    .executable(name: "solara-store", targets: ["SolaraStoreCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
  ],
  targets: [
    .target(name: "SolaraModel"),
    .target(name: "SolaraStore", dependencies: ["SolaraModel"]),
    .target(name: "SolaraPersistence", dependencies: ["SolaraModel", "SolaraStore", .product(name: "GRDB", package: "GRDB.swift")]),
    .target(name: "SolaraBridgeCore", dependencies: ["SolaraModel", "SolaraStore", "SolaraPersistence", "SolaraOmnibox"]),
    .target(name: "SolaraOmnibox", dependencies: ["SolaraModel"]),
    .target(name: "SolaraSync", dependencies: ["SolaraModel", "SolaraStore", "SolaraPersistence"]),
    .target(name: "SolaraImport", dependencies: ["SolaraModel"]),
    .target(name: "SolaraEngine", dependencies: ["SolaraStore", "SolaraOmnibox"]),
    .target(name: "SolaraUI", dependencies: ["SolaraModel", "SolaraOmnibox"]),
    .target(name: "SolaraSignposts"),
    .executableTarget(name: "SolaraStoreCLI", dependencies: ["SolaraModel", "SolaraStore", "SolaraPersistence", "SolaraBridgeCore", "SolaraSync"]),
    .testTarget(name: "SolaraModelTests", dependencies: ["SolaraModel"]),
    .testTarget(name: "SolaraStoreTests", dependencies: ["SolaraModel", "SolaraStore"], exclude: ["Cases"]),
    .testTarget(name: "SolaraPersistenceTests", dependencies: ["SolaraModel", "SolaraStore", "SolaraPersistence"]),
    .testTarget(name: "SolaraBridgeCoreTests", dependencies: ["SolaraModel", "SolaraStore", "SolaraPersistence", "SolaraBridgeCore"]),
    .testTarget(name: "SolaraOmniboxTests", dependencies: ["SolaraOmnibox", "SolaraModel"], exclude: ["Fixtures"]),
    .testTarget(name: "SolaraImportTests", dependencies: ["SolaraImport"], exclude: ["Fixtures"]),
    .testTarget(name: "SolaraUITests", dependencies: ["SolaraUI"]),
    .testTarget(name: "SolaraSignpostsTests", dependencies: ["SolaraSignposts"]),
    .testTarget(name: "SolaraSyncTests", dependencies: ["SolaraModel", "SolaraSync"], exclude: ["Scenarios"]),
  ],
  swiftLanguageModes: [.v6]
)
