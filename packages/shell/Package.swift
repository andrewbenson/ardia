// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ArdiaShellCore",
  platforms: [.macOS(.v14)],
  products: [.library(name: "ArdiaShellCore", targets: ["ArdiaShellCore"])],
  targets: [
    .target(name: "ArdiaShellCore", path: "ios/Core"),
    .testTarget(name: "ArdiaShellCoreTests", dependencies: ["ArdiaShellCore"], path: "tests"),
  ]
)
