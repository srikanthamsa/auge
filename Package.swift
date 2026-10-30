// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Auge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Auge", targets: ["Auge"])],
    targets: [.executableTarget(name: "Auge", path: "Sources/Auge")]
)
