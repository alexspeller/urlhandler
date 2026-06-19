// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "urlhandler",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "URLHandlerKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .executableTarget(
            name: "urlhandler",
            dependencies: ["URLHandlerKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tests run as a plain executable (`swift run urlhandler-selftest`). XCTest is not
        // installed with Command Line Tools, and swift-testing's standalone runner isn't wired
        // up by SwiftPM on a CLT-only macOS, so we exercise the public API with a small harness.
        .executableTarget(
            name: "urlhandler-selftest",
            dependencies: ["URLHandlerKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
