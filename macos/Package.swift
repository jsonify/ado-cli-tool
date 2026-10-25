// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ADODesk",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ADODesk",
            path: "Sources/ADODesk"
        ),
        .testTarget(
            name: "ADODeskTests",
            dependencies: ["ADODesk"],
            path: "Tests/ADODeskTests"
        ),
    ]
)
