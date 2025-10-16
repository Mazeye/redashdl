// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "redash-dl",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "redash-dl", targets: ["redash-dl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.3")
    ],
    targets: [
        .executableTarget(
            name: "redash-dl",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "RedashClient"
            ]
        ),
        .target(
            name: "RedashClient",
            dependencies: []
        )
    ]
)
