// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "See",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "See", targets: ["See"])],
    targets: [.executableTarget(name: "See")]
)
