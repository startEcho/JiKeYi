// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "JiKeYiTrans",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "jikeyi-trans", targets: ["JiKeYiTrans"])
  ],
  dependencies: [
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1")
  ],
  targets: [
    .executableTarget(
      name: "JiKeYiTrans",
      dependencies: [
        .product(name: "MarkdownUI", package: "swift-markdown-ui")
      ],
      path: "Sources/JiKeYiTrans"
    )
  ]
)
