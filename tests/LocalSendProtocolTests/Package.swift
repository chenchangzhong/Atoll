// swift-tools-version:5.9
import PackageDescription

// The byte-level LocalSend protocol code is exercised here through a symlink to
// the file the app compiles, so the tests cannot drift from the shipped logic.
let package = Package(
    name: "LocalSendProtocol",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LocalSendProtocol", path: "Sources/LocalSendProtocol"),
        .testTarget(name: "LocalSendProtocolTests", dependencies: ["LocalSendProtocol"], path: "Tests/LocalSendProtocolTests"),
    ]
)
