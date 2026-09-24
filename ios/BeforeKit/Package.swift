// swift-tools-version: 5.10
import PackageDescription

/// BeforeKit — the part of BEFORE that has no UI and no network.
///
/// Models, scoring, and formatting live here so they can be exercised with
/// `swift test` on any machine with a Swift toolchain, without Xcode, a
/// simulator, or a signing identity. The app target depends on this package;
/// nothing in this package depends on the app.
let package = Package(
    name: "BeforeKit",
    platforms: [
        // iOS 17 is the app's floor (see DECISIONS.md). macOS is listed only so
        // the test suite runs on a developer machine or in CI.
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BeforeKit", targets: ["BeforeKit"]),
    ],
    targets: [
        .target(
            name: "BeforeKit",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "BeforeKitTests",
            dependencies: ["BeforeKit"]
        ),
    ]
)
