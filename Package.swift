// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SayKey",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SayKey", targets: ["SayKey"])
    ],
    targets: [
        .executableTarget(
            name: "SayKey",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
