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
        .target(
            name: "MacKVMNativeDDC",
            path: "Sources/MacKVMNativeDDC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreDisplay"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(name: "MacKVMCore"),
        .executableTarget(
            name: "MacKVM",
            dependencies: ["MacKVMCore", "MacKVMNativeDDC"]
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
