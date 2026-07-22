// swift-tools-version:5.9
import PackageDescription

// SlurmBar is built with SwiftPM rather than a checked-in .xcodeproj so that the whole app —
// including its tests — builds and runs from the command line (`swift build`, `swift test`) as
// well as in Xcode (`xed app/`). `scripts/build-macos-app.sh` assembles the executable into a
// proper SlurmBar.app bundle, which is required for menu bar placement, notifications and
// launch-at-login.
let package = Package(
    name: "SlurmBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SlurmBar", targets: ["SlurmBar"]),
        .library(name: "SlurmBarKit", targets: ["SlurmBarKit"]),
    ],
    targets: [
        // All logic lives here: protocol decoding, SSH invocation, polling policy, formatting,
        // notification state machine. The executable target is views only, which is what makes
        // the app testable without a UI harness.
        .target(name: "SlurmBarKit"),
        .executableTarget(
            name: "SlurmBar",
            dependencies: ["SlurmBarKit"]
        ),
        .testTarget(
            name: "SlurmBarKitTests",
            dependencies: ["SlurmBarKit"]
        ),
    ]
)
