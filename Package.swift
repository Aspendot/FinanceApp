// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinanceApp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FinanceCore", targets: ["FinanceCore"]),
        .executable(name: "finance-feed", targets: ["finance-feed"]),
    ],
    targets: [
        .target(name: "FinanceCore"),
        .executableTarget(name: "finance-feed", dependencies: ["FinanceCore"]),
        .testTarget(name: "FinanceCoreTests", dependencies: ["FinanceCore"]),
    ]
)
