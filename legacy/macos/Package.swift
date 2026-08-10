// swift-tools-version: 6.2

import PackageDescription


let package = Package(
    name: "AssignmentNative",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "AssignmentNative", targets: ["AssignmentNative"]),
    ],
    targets: [
        .executableTarget(
            name: "AssignmentNative",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "AssignmentNativeTests",
            dependencies: ["AssignmentNative"]
        ),
    ]
)
