// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iPaste",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "iPaste", targets: ["ClipShelf"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ClipboardCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ClipShelf", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipShelfTests", dependencies: ["ClipShelf", "ClipboardCore"])
    ],
    swiftLanguageModes: [.v5]
)
