// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SignatureKeeper",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SignatureKeeper", targets: ["SignatureKeeper"])],
    targets: [.executableTarget(name: "SignatureKeeper")]
)
