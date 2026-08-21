// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "trueface_liveness",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(
            name: "trueface-liveness",
            targets: ["trueface_liveness"]
        )
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(
            url: "https://github.com/trueface-dev/ios-artifact.git",
            from: "0.2.8"
        )
    ],
    targets: [
        .target(
            name: "trueface_liveness",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "TrueFaceLiveness", package: "ios-artifact")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Vision")
            ]
        )
    ]
)