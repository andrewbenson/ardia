// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "SolaraLegacySyncCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "SolaraLegacySyncCore", targets: ["SolaraLegacySyncCore"]),
  ],
  targets: [
    .target(name: "SolaraLegacySyncCore", path: "ios/Core"),
    .testTarget(name: "SolaraLegacySyncCoreTests", dependencies: ["SolaraLegacySyncCore"], path: "tests", exclude: ["fixtures"]),
  ]
)
