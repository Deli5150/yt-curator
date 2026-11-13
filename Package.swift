// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YTCurator",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "YTCurator", targets: ["YTCurator"]),
    ],
    targets: [
        .executableTarget(
            name: "YTCurator",
            path: "Sources/YTCurator",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
        .testTarget(
            name: "YTCuratorTests",
            dependencies: ["YTCurator"],
            path: "Tests/YTCuratorTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
    ]
)
