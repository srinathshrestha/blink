// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blink",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "Blink", path: "Sources/Blink")]
)
