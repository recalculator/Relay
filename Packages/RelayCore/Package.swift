// swift-tools-version: 6.0
// Tools version 6.0 means this package compiles in the Swift 6 language mode,
// which turns on complete compile-time data-race checking.

import PackageDescription

let package = Package(
    name: "RelayCore",
    platforms: [
        // CKSyncEngine and the Observation framework both require these minimums.
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RelayCore", targets: ["RelayCore"]),
    ],
    targets: [
        .target(name: "RelayCore"),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
        // Performance measurements, kept apart from the correctness tests. Uses only
        // RelayCore's public API, isolated temporary databases, and synthetic notes.
        // See BENCHMARKS.md. Run with Scripts/benchmark.sh (release build).
        .executableTarget(name: "RelayBench", dependencies: ["RelayCore"], path: "Benchmarks/RelayBench"),
    ]
)
