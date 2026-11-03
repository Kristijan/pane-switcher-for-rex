// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaneSwitch",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PaneSwitchCore", targets: ["PaneSwitchCore"]),
        .executable(name: "PaneSwitch", targets: ["PaneSwitch"]),
    ],
    targets: [
        .target(name: "PaneSwitchCore"),
        .executableTarget(name: "PaneSwitch", dependencies: ["PaneSwitchCore"]),
        .testTarget(name: "PaneSwitchCoreTests", dependencies: ["PaneSwitchCore"]),
        .testTarget(name: "PaneSwitchTests", dependencies: ["PaneSwitch", "PaneSwitchCore"]),
    ],
    swiftLanguageModes: [.v5]
)
