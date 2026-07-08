// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FloatingTerminal",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "FloatingTerminal",
            targets: ["FloatingTerminal"]
        )
    ],
    targets: [
        .executableTarget(
            name: "FloatingTerminal"
        )
    ],
    swiftLanguageModes: [.v5]
)
