// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "swift-cloud-kit-stack",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "CloudKitData",
      targets: ["CloudKitData"]
    ),
    .library(
      name: "CloudKitDataStack",
      targets: ["CloudKitDataStack"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/swiftlang/swift-syntax.git",
      from: "602.0.0"
    )
  ],
  targets: [
    .macro(
      name: "CloudKitDataMacros",
      dependencies: [
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "CloudKitData",
      dependencies: ["CloudKitDataMacros"]
    ),
    .target(
      name: "CloudKitDataStack",
      dependencies: ["CloudKitData"]
    ),
    .target(
      name: "CloudKitDataConsumerFixture",
      dependencies: ["CloudKitData"],
      path: "Tests/Fixtures/CloudKitDataConsumerFixture"
    ),
    .target(
      name: "CloudKitDataStackConsumerFixture",
      dependencies: [
        "CloudKitData",
        "CloudKitDataConsumerFixture",
        "CloudKitDataStack",
      ],
      path: "Tests/Fixtures/CloudKitDataStackConsumerFixture"
    ),
    .testTarget(
      name: "CloudKitDataMacrosTests",
      dependencies: [
        "CloudKitDataMacros",
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
      ]
    ),
    .testTarget(
      name: "CloudKitDataTests",
      dependencies: [
        "CloudKitData",
        "CloudKitDataConsumerFixture",
      ]
    ),
    .testTarget(
      name: "CloudKitDataStackTests",
      dependencies: [
        "CloudKitData",
        "CloudKitDataConsumerFixture",
        "CloudKitDataStack",
        "CloudKitDataStackConsumerFixture",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
