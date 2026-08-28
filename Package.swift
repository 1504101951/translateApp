// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranslateApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranslateCore", targets: ["TranslateCore"]),
        .executable(name: "TranslateApp", targets: ["TranslateApp"]),
    ],
    targets: [
        .target(
            name: "TranslateCore",
            path: "Sources/TranslateCore"
        ),
        .executableTarget(
            name: "TranslateApp",
            dependencies: ["TranslateCore"],
            path: "TranslateApp",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "TranslateCoreTests",
            dependencies: ["TranslateCore"],
            path: "Tests/TranslateCoreTests"
        ),
    ]
)
