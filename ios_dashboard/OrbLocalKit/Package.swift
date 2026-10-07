// swift-tools-version:6.0
// Platform-neutral core of the Orb iOS local agent runtime. Everything here is
// pure Swift + Foundation so it is unit tested on Linux CI as well as compiled
// into Orb.app; UIKit/ReplayKit/Vision glue lives in the app target.
import PackageDescription

let package = Package(
    name: "OrbLocalKit",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [.library(name: "OrbLocalKit", targets: ["OrbLocalKit"])],
    targets: [
        .target(name: "OrbLocalKit"),
        .testTarget(name: "OrbLocalKitTests", dependencies: ["OrbLocalKit"]),
    ]
)
