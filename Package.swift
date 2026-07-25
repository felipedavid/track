// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Track",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .executableTarget(
            name: "Track",
            dependencies: ["CSQLite"],
            path: "Sources/Track",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
