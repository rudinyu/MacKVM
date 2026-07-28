// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacKVM",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacKVM", targets: ["MacKVM"])
    ],
    targets: [
        .target(name: "MacKVMCore"),
        .executableTarget(
            name: "MacKVM",
            dependencies: ["MacKVMCore"]
        ),
        .testTarget(
            name: "MacKVMCoreTests",
            dependencies: ["MacKVMCore"]
        ),
        .testTarget(
            name: "MacKVMTests",
            dependencies: ["MacKVM", "MacKVMCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
