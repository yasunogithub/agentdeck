// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "AgentDeck",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/AgentDeck",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
