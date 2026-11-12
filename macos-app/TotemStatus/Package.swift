// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TotemStatus",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "TotemStatus",
            path: "Sources/TotemStatus",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
