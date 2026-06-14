// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JianLu",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "JianLuCore", targets: ["JianLuCore"]),
        .executable(name: "JianLuCoreChecks", targets: ["JianLuCoreChecks"]),
        .executable(name: "JianLuBundleChecks", targets: ["JianLuBundleChecks"]),
        .executable(name: "JianLu", targets: ["JianLu"])
    ],
    targets: [
        .target(
            name: "JianLuCore",
            path: "Sources/JianLuCore"
        ),
        .executableTarget(
            name: "JianLu",
            dependencies: ["JianLuCore"],
            path: "Sources/JianLu"
        ),
        .executableTarget(
            name: "JianLuCoreChecks",
            dependencies: ["JianLuCore"],
            path: "Tests/JianLuCoreChecks"
        ),
        .executableTarget(
            name: "JianLuBundleChecks",
            path: "Tests/JianLuBundleChecks"
        )
    ]
)
