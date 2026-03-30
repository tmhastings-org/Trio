// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrioAnalyzer",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "TrioAnalyzer",
            targets: ["TrioAnalyzer"]
        )
    ],
    targets: [
        .target(
            name: "TrioAnalyzer",
            path: "Sources/TrioAnalyzer"
        )
    ]
)
