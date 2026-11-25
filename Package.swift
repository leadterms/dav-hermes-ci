// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DAVDrive",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        // xtool packs each library product into a bundle: the app, then its extensions (see xtool.yml).
        .library(name: "DAVDrive", targets: ["DAVDrive"]),
        .library(name: "DAVDriveFileProvider", targets: ["DAVDriveFileProvider"]),
    ],
    targets: [
        // Code shared by the app and the extension: the WebDAV client and the account store.
        .target(
            name: "DAVCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DAVDrive",
            dependencies: ["DAVCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DAVDriveFileProvider",
            dependencies: ["DAVCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Nothing references the extension's principal class by symbol (the system
                // looks it up by name), so keep the linker from dropping it.
                .unsafeFlags(["-Xlinker", "-ObjC"]),
            ]
        ),
    ]
)
