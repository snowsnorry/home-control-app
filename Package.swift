// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomeControl",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "HomeControl", targets: ["HomeControl"])],
    dependencies: [.package(url: "https://github.com/emqx/CocoaMQTT.git", exact: "2.1.6")],
    targets: [
        .executableTarget(name: "HomeControl", dependencies: [.product(name: "CocoaMQTT", package: "CocoaMQTT")], path: "HomeControl", exclude: ["Info.plist"], resources: [.copy("Resources/HueRootCA.pem"), .copy("Resources/Localizable.xcstrings")]),
        .testTarget(name: "HomeControlTests", dependencies: ["HomeControl"], path: "HomeControlTests")
    ]
)
