// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SlowWalkPresentation",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../SlowWalkCore"),
    ],
    targets: [
        .target(
            name: "SlowWalkPresentation",
            dependencies: [
                .product(name: "SlowWalkDomain", package: "SlowWalkCore"),
                .product(name: "SlowWalkAPIContracts", package: "SlowWalkCore"),
                .product(name: "SlowWalkClientCore", package: "SlowWalkCore"),
            ]
        ),
        .testTarget(
            name: "SlowWalkPresentationTests",
            dependencies: [
                "SlowWalkPresentation",
                .product(name: "SlowWalkDomain", package: "SlowWalkCore"),
            ]
        ),
    ]
)
