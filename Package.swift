// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "gpucomm-core",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "GPUCommCore", targets: ["GPUCommCore"]),
        .executable(name: "gpucomm", targets: ["gpucomm"]),
    ],
    targets: [
        .target(
            name: "GPUCommCore",
            resources: [
                // Copy, do not process. SwiftPM's .process compiles .metal
                // sources into default.metallib and does not keep the source,
                // but KernelLibrary loads Kernels.metal as text and compiles it
                // at runtime. With .process the binary failed at startup with a
                // missing resource error.
                .copy("Resources/Kernels/Kernels.metal"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
            ]
        ),
        .executableTarget(
            name: "gpucomm",
            dependencies: ["GPUCommCore"],
            linkerSettings: [
                .linkedFramework("Metal"),
            ]
        ),
    ]
)
