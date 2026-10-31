// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "SolaraShellCore",
  platforms: [.macOS(.v14)],
  products: [.library(name: "SolaraShellCore", targets: ["SolaraShellCore"])],
  targets: [
    .target(name: "SolaraShellCore", path: "ios/Core"),
    .testTarget(name: "SolaraShellCoreTests", dependencies: ["SolaraShellCore"], path: "tests"),
  ]
)
