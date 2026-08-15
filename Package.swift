// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HarnessLauncher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "HarnessLauncher",
            targets: ["HarnessLauncher"]
        )
    ],
    targets: [
        .executableTarget(
            name: "HarnessLauncher",
            path: "App"
        ),
        .testTarget(
            name: "HarnessLauncherTests",
            dependencies: ["HarnessLauncher"],
            path: "Tests"
        )
    ]
)
