// swift-tools-version: 6.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "gobo-core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GoboCore", targets: ["GoboCore"]),
        .library(name: "GoboKit", targets: ["GoboKit"]),
        .executable(name: "gobo-cli", targets: ["gobo-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "GoboCore"),
        .target(name: "GoboKit", dependencies: ["GoboCore"]),
        .executableTarget(
            name: "gobo-cli",
            dependencies: [
                "GoboCore",
                "GoboKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "GoboCoreTests", dependencies: ["GoboCore"]),
    ]
)
