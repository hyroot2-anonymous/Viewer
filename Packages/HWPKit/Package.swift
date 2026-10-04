// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HWPKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HWPKit", targets: ["HWPKit"]),
    ],
    targets: [
        .target(name: "HWPKit"),
        .testTarget(
            name: "HWPKitTests",
            dependencies: ["HWPKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
