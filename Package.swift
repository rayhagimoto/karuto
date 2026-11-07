// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "ScreenshotX",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ScreenshotX", targets: ["ScreenshotX"])],
    targets: [
        .systemLibrary(name: "CStitcher", path: "Sources/CStitcher"),
        .executableTarget(
            name: "ScreenshotX", dependencies: ["CStitcher"],
            linkerSettings: [
                .unsafeFlags(["-L", root + "/stitcher/target/release"]),
                .linkedLibrary("screenshotx_stitcher"), .linkedLibrary("z"),
                .linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"), .linkedFramework("Carbon")
            ]
        ),
        .testTarget(name: "ScreenshotXTests", dependencies: ["ScreenshotX"])
    ]
)
