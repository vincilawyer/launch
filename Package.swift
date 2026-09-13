// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "启动台",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Launch", targets: ["Launch"])
    ],
    targets: [
        .executableTarget(
            name: "Launch",
            path: "Sources/Launch"
        )
    ],
    swiftLanguageVersions: [.v5]
)
