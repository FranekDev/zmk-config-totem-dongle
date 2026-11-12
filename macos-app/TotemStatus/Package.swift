// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TotemStatus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TotemStatus",
            path: "Sources/TotemStatus",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
