// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftMon",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SMCBridge",
            path: "Sources/SMCBridge",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "SwiftMon",
            dependencies: ["SMCBridge"],
            path: "Sources/SwiftMon",
            linkerSettings: [
                .linkedLibrary("IOReport"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
