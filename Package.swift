// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Set JSCE_PATH to a local checkout to test a fix; otherwise this uses upstream main.
let jsce: Package.Dependency =
  if let path = ProcessInfo.processInfo.environment["JSCE_PATH"] {
    .package(name: "javascript-core-extras", path: path)
  } else {
    .package(url: "https://github.com/mhayes853/javascript-core-extras", branch: "main")
  }

let package = Package(
  name: "LeakRepro",
  platforms: [.macOS(.v13)],
  dependencies: [jsce],
  targets: [
    .executableTarget(
      name: "LeakRepro",
      dependencies: [.product(name: "JavaScriptCoreExtras", package: "javascript-core-extras")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
