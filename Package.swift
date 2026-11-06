// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenPaste",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenPaste", targets: ["ClipShelf"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ClipboardCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ClipShelf", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipShelfTests", dependencies: ["ClipShelf", "ClipboardCore"])
    ],
    swiftLanguageModes: [.v5]
)
