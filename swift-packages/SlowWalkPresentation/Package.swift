// swift-tools-version: 6.0

import PackageDescription

// The platform floor matches SlowWalkCore so this module never forces a
// higher deployment target on the app shell.
let package = Package(
    name: "SlowWalkPresentation",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "SlowWalkPresentation",
            targets: ["SlowWalkPresentation"]
        ),
    ],
    dependencies: [
        .package(path: "../SlowWalkCore"),
    ],
    targets: [
        // `path: "Sources"` keeps Models/, Logic/, and Views/ as plain
        // subdirectories that SwiftPM discovers automatically. No file is
        // enumerated by hand, so adding a view cannot silently drop it and a
        // case-sensitive filesystem cannot break the build.
        .target(
            name: "SlowWalkPresentation",
            dependencies: [
                .product(
                    name: "SlowWalkDomain",
                    package: "SlowWalkCore"
                ),
                .product(
                    name: "SlowWalkAPIContracts",
                    package: "SlowWalkCore"
                ),
                .product(
                    name: "SlowWalkMedicineKnowledge",
                    package: "SlowWalkCore"
                ),
                .product(
                    name: "SlowWalkClientCore",
                    package: "SlowWalkCore"
                ),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "SlowWalkPresentationTests",
            dependencies: [
                "SlowWalkPresentation",
                .product(
                    name: "SlowWalkDomain",
                    package: "SlowWalkCore"
                ),
                .product(
                    name: "SlowWalkAPIContracts",
                    package: "SlowWalkCore"
                ),
                .product(
                    name: "SlowWalkMedicineKnowledge",
                    package: "SlowWalkCore"
                ),
                .product(
                    name: "SlowWalkClientCore",
                    package: "SlowWalkCore"
                ),
            ]
        ),
    ]
)
