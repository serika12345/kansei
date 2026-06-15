// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KanseiMissionClose",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "KanseiMissionClose", targets: ["KanseiMissionClose"]),
    ],
    targets: [
        .target(
            name: "PrivateAX",
            path: "Sources/PrivateAX",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "KanseiMissionClose",
            dependencies: ["PrivateAX"],
            path: "Sources/KanseiMissionClose",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
