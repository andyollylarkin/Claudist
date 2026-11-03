// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Claudist",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Claudist", targets: ["Claudist"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "ClaudistCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Claudist",
            dependencies: ["ClaudistCore", .product(name: "GRDB", package: "GRDB.swift"),
                           .product(name: "MarkdownUI", package: "swift-markdown-ui")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudistCoreTests",
            dependencies: ["ClaudistCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
