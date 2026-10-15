// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "bodycam-app",
  platforms: [.macOS(.v14)],
  targets: [.executableTarget(name: "bodycam-app", path: "Sources/bodycam-app")]
)
