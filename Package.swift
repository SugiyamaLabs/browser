// swift-tools-version: 6.0
import PackageDescription

// The only Swift package of this repository: BrowserKit, what a host app imports to show the
// browser's pages (docs/kit.md). It lives at the root because SwiftPM takes a remote package only
// from the root of a repository; the code is in kit/apple/BrowserKit.
let package = Package(
  name: "BrowserKit",
  platforms: [.macOS(.v14)],
  products: [.library(name: "BrowserKit", targets: ["BrowserKit"])],
  targets: [
    .target(name: "BrowserKit", path: "kit/apple/BrowserKit/Sources/BrowserKit"),
    .testTarget(name: "BrowserKitTests", dependencies: ["BrowserKit"], path: "kit/apple/BrowserKit/Tests/BrowserKitTests"),
  ]
)
