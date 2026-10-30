// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentDesk", targets: ["AgentDesk"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "AgentDeskCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgentDesk",
            dependencies: ["AgentDeskCore", .product(name: "GRDB", package: "GRDB.swift"),
                           .product(name: "MarkdownUI", package: "swift-markdown-ui")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentDeskCoreTests",
            dependencies: ["AgentDeskCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
