// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KongFetch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KongFetch", targets: ["KongFetch"])
    ],
    targets: [
        // Pure logic: no AppKit. Everything here is covered by unit tests.
        .target(name: "KongFetchCore", path: "Sources/KongFetchCore"),
        // The menu-bar app: panels, hot keys, event tap, Spotlight, pasteboard.
        .executableTarget(
            name: "KongFetch",
            dependencies: ["KongFetchCore"],
            path: "Sources/KongFetch"
        ),
        .testTarget(
            name: "KongFetchCoreTests",
            dependencies: ["KongFetchCore"],
            path: "Tests/KongFetchCoreTests"
        )
    ]
)
