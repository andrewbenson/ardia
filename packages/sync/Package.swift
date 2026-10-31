// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ArdiaSyncCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "ArdiaSyncCore", targets: ["ArdiaSyncCore"]),
  ],
  targets: [
    .target(name: "ArdiaSyncCore", path: "ios/Core"),
    .testTarget(name: "ArdiaSyncCoreTests", dependencies: ["ArdiaSyncCore"], path: "tests", exclude: ["fixtures"]),
  ]
)
