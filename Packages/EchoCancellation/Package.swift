// swift-tools-version: 5.9
import PackageDescription

// FORK: local package (fork-only, spec docs/fork/designs/02-aec-core.md).
//
// CSpeexDSP vendors the echo canceller (mdf.c) and the preprocessor used for
// residual echo suppression from Xiph's SpeexDSP (BSD-3-Clause); see
// Sources/CSpeexDSP/VENDORED.md. EchoCancellation is the Swift API: the
// backend protocol, the Speex backend, and the timestamp-aligning stage.

let package = Package(
    name: "EchoCancellation",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EchoCancellation", targets: ["EchoCancellation"]),
    ],
    targets: [
        .target(
            name: "CSpeexDSP",
            exclude: ["COPYING", "VENDORED.md"],
            cSettings: [
                // Every vendored file does `#ifdef HAVE_CONFIG_H #include "config.h"`;
                // config.h (hand-written, next to the sources) selects the float build.
                .define("HAVE_CONFIG_H"),
                // SwiftPM compiles C at -O0 in debug builds; the echo canceller is ~8x
                // slower there, which would make `swift test` (a debug build) crawl.
                // Local path package, so unsafeFlags are allowed.
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "EchoCancellation",
            dependencies: ["CSpeexDSP"]
        ),
        .testTarget(
            name: "EchoCancellationTests",
            dependencies: ["EchoCancellation"]
        ),
    ]
)
