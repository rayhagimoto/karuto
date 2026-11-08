// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "Karuto",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Karuto", targets: ["Karuto"])],
    targets: [
        .systemLibrary(name: "CStitcher", path: "Sources/CStitcher"),
        .executableTarget(
            name: "Karuto", dependencies: ["CStitcher"],
            linkerSettings: [
                .unsafeFlags(["-L", root + "/stitcher/target/release"]),
                .linkedLibrary("karuto_stitcher"), .linkedLibrary("z"),
                .linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"), .linkedFramework("Carbon")
            ]
        ),
        .testTarget(name: "KarutoTests", dependencies: ["Karuto"])
    ]
)
