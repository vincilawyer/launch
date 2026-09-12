// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Launch",
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
