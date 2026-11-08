// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VirtualLocation",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VirtualLocation", targets: ["VirtualLocation"])],
    targets: [
        .executableTarget(name: "VirtualLocation")
    ],
    swiftLanguageModes: [.v5]
)
