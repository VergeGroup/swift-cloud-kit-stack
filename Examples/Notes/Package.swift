// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Notes",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "Notes",
      dependencies: [
        .product(name: "CloudKitData", package: "swift-cloud-kit-stack"),
        .product(name: "CloudKitDataStack", package: "swift-cloud-kit-stack"),
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
