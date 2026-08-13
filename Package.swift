// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BuriedAnchor",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "BuriedAnchor",
            path: "Sources/BuriedAnchor"
        )
    ]
)
