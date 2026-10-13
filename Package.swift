// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomeControl",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "HomeControl", targets: ["HomeControl"])],
    dependencies: [.package(url: "https://github.com/emqx/CocoaMQTT.git", exact: "2.1.6"), .package(url: "https://github.com/Bouke/HAP.git", revision: "51e3505a34eb842f7491fda48bb4ef873b16b68c")],
    targets: [
        .executableTarget(name: "HomeControl", dependencies: [.product(name: "CocoaMQTT", package: "CocoaMQTT"), .product(name: "HAP", package: "HAP")], path: "HomeControl", exclude: ["Info.plist"], resources: [.copy("Resources/AppIcon.icns"), .copy("Resources/HueRootCA.pem"), .copy("Resources/DysonTP07.png"), .copy("Resources/Localizable.xcstrings")]),
        .testTarget(name: "HomeControlTests", dependencies: ["HomeControl"], path: "HomeControlTests")
    ]
)
