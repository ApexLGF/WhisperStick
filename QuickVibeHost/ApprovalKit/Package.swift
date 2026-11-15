// swift-tools-version:5.9
// ApprovalKit — REQ-022 审批协议 v1 Mac 侧基础模块(纯 Foundation,零第三方依赖)
// 权威规格:docs/approval-protocol-v1.md
import PackageDescription

let package = Package(
    name: "ApprovalKit",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "ApprovalKit", targets: ["ApprovalKit"])
    ],
    targets: [
        .target(
            name: "ApprovalKit",
            path: "Sources/ApprovalKit"
        ),
        .testTarget(
            name: "ApprovalKitTests",
            dependencies: ["ApprovalKit"],
            path: "Tests/ApprovalKitTests"
        ),
    ]
)
