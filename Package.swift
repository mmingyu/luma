// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Luma",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Luma", targets: ["Luma"])
    ],
    targets: [
        .executableTarget(
            name: "Luma",
            path: "Sources/Luma"
        )
    ]
)
