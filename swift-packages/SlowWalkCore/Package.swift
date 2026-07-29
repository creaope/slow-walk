// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SlowWalkCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SlowWalkDomain", targets: ["SlowWalkDomain"]),
        .library(name: "SlowWalkRiskEngine", targets: ["SlowWalkRiskEngine"]),
        .library(name: "SlowWalkAPIContracts", targets: ["SlowWalkAPIContracts"]),
        .library(name: "SlowWalkDataInterfaces", targets: ["SlowWalkDataInterfaces"]),
        .library(
            name: "SlowWalkMedicinePipeline",
            targets: ["SlowWalkMedicinePipeline"]
        ),
        .library(
            name: "SlowWalkMedicineKnowledge",
            targets: ["SlowWalkMedicineKnowledge"]
        ),
        .library(
            name: "SlowWalkLocationRisk",
            targets: ["SlowWalkLocationRisk"]
        ),
        .library(
            name: "SlowWalkClientCore",
            targets: ["SlowWalkClientCore"]
        ),
    ],
    targets: [
        .target(name: "SlowWalkDomain"),
        .target(
            name: "SlowWalkRiskEngine",
            dependencies: ["SlowWalkDomain"]
        ),
        .target(
            name: "SlowWalkAPIContracts",
            dependencies: [
                "SlowWalkDomain",
                "SlowWalkLocationRisk",
                "SlowWalkMedicineKnowledge",
            ]
        ),
        .target(
            name: "SlowWalkDataInterfaces",
            dependencies: ["SlowWalkDomain"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "SlowWalkMedicineKnowledge",
            dependencies: [
                "SlowWalkDomain",
                "SlowWalkDataInterfaces",
            ]
        ),
        .target(
            name: "SlowWalkMedicinePipeline",
            dependencies: [
                "SlowWalkDomain",
                "SlowWalkRiskEngine",
                "SlowWalkDataInterfaces",
                "SlowWalkMedicineKnowledge",
            ]
        ),
        .target(
            name: "SlowWalkLocationRisk",
            dependencies: ["SlowWalkDomain"]
        ),
        .target(
            name: "SlowWalkClientCore",
            dependencies: [
                "SlowWalkDomain",
                "SlowWalkAPIContracts",
                "SlowWalkLocationRisk",
            ]
        ),
        .testTarget(
            name: "SlowWalkDomainTests",
            dependencies: ["SlowWalkDomain"]
        ),
        .testTarget(
            name: "SlowWalkRiskEngineTests",
            dependencies: ["SlowWalkDomain", "SlowWalkRiskEngine"]
        ),
        .testTarget(
            name: "SlowWalkAPIContractsTests",
            dependencies: [
                "SlowWalkDomain",
                "SlowWalkLocationRisk",
                "SlowWalkMedicineKnowledge",
                "SlowWalkAPIContracts",
            ]
        ),
        .testTarget(
            name: "SlowWalkDataInterfacesTests",
            dependencies: ["SlowWalkDomain", "SlowWalkDataInterfaces"]
        ),
        .testTarget(
            name: "SlowWalkMedicineKnowledgeTests",
            dependencies: [
                "SlowWalkDomain",
                "SlowWalkDataInterfaces",
                "SlowWalkMedicineKnowledge",
            ],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SlowWalkMedicinePipelineTests",
            dependencies: [
                "SlowWalkDomain",
                "SlowWalkRiskEngine",
                "SlowWalkDataInterfaces",
                "SlowWalkMedicineKnowledge",
                "SlowWalkMedicinePipeline",
            ]
        ),
        .testTarget(
            name: "SlowWalkLocationRiskTests",
            dependencies: [
                "SlowWalkDomain",
                "SlowWalkLocationRisk",
                "SlowWalkAPIContracts",
            ],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SlowWalkClientCoreTests",
            dependencies: [
                "SlowWalkDomain",
                "SlowWalkAPIContracts",
                "SlowWalkLocationRisk",
                "SlowWalkClientCore",
            ]
        ),
    ]
)
