// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProxyBar",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ProxyBar",
            path: "Sources/ProxyBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
