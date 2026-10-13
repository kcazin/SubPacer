// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SubPacer",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "SubPacer",
            path: "Sources/SubPacer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
