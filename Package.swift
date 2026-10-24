// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingJoiner",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MeetingJoinerCore", targets: ["MeetingJoinerCore"]),
        .executable(name: "MeetingJoinerApp", targets: ["MeetingJoinerApp"]),
    ],
    targets: [
        .target(name: "MeetingJoinerCore"),
        .executableTarget(name: "MeetingJoinerApp", dependencies: ["MeetingJoinerCore"]),
        .testTarget(name: "MeetingJoinerCoreTests", dependencies: ["MeetingJoinerCore"]),
    ]
)
