// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CyberpunkLauncher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CyberpunkLauncher", targets: ["CyberpunkLauncher"]),
        .executable(name: "launcher-check", targets: ["launcher-check"]),
    ],
    targets: [
        .target(name: "LauncherCore", exclude: ["Resources"]),
        .executableTarget(name: "CyberpunkLauncher", dependencies: ["LauncherCore"]),
        .executableTarget(name: "launcher-check", dependencies: ["LauncherCore"]),
    ]
)
