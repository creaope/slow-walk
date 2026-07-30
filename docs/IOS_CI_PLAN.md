# iOS CI 计划与现状

Ubuntu 上的 SwiftPM 工作流只验证 `swift-packages/SlowWalkCore` 和 `server`，
不能证明 SwiftUI 或任何 iOS 专属功能可以构建。因此 iOS 需要独立的 macOS
工作流。

## 启用条件（已全部满足）

1. 在 Mac 上使用 Xcode 创建并提交真实的 `.xcodeproj`。已提交
   `ios/SlowWalkApp.xcodeproj`。
2. 提交一个可供 CI 使用的 shared scheme。已提交
   `xcshareddata/xcschemes/SlowWalkApp.xcscheme`，其中 `SlowWalkAppTests`
   已登记为 testable。
3. 用 Xcode 确认项目引用 `SlowWalkCore` 的方式和最低 iOS 版本。工程以
   local package 方式引用 `SlowWalkCore`，`IPHONEOS_DEPLOYMENT_TARGET = 17.0`。
4. 确认模拟器构建不需要证书、描述文件或仓库中的私密配置。以
   `CODE_SIGNING_ALLOWED=NO` 与 `CODE_SIGNING_REQUIRED=NO` 验证通过。

## 当前实现

`.github/workflows/ios-app.yml`：

- 使用 `runs-on: macos-26`，而不是 `macos-latest`。`macos-latest` 在 2026 年
  7 月才迁移到 macos-26；它此前指向的 macos-15 镜像默认 Xcode 为 16.4，
  无法构建本工程。固定标签避免默认 Xcode 再次漂移导致构建失败。
- 使用 `xcodebuild` 和真实工程名与 scheme 名。
- 通过 `.github/scripts/select-ios-simulator.py` 在运行时选取实际存在的
  iPhone Simulator，而不是硬编码某个机型或 iOS 版本；镜像上的模拟器组合
  不由本仓库固定，且会随镜像更新变化。
- 找不到可用 iPhone Simulator 时直接失败，不退化为“仅构建”。
- 设置 `CODE_SIGNING_ALLOWED=NO` 和 `CODE_SIGNING_REQUIRED=NO`。
- 任何解析、编译或测试失败都会让工作流真实失败。

## Runner 事实（已由 GitHub runner 实际运行确认）

`macos-26` 镜像上实测：

- `xcodebuild -version` 输出 Xcode 26.6 (Build 17F113)，
  `swift --version` 输出 Apple Swift 6.3.3。与本地验证所用工具链一致。
  注意：actions/runner-images 镜像清单把默认 Xcode 记为 26.5，实际镜像已是
  26.6（对应清单公告 "Default Xcode on macOS 26 Tahoe will be set to
  Xcode 26.6 on 2026.07.21"）。默认版本会随镜像更新漂移，这正是 destination
  采用运行时探测的原因。
- 运行时探测选中 iPhone Air (iOS 26.5)。
- 工程 `IPHONEOS_DEPLOYMENT_TARGET = 17.0`、`SWIFT_VERSION = 6.0`，均在
  Xcode 26.x 支持范围内。

## 已验证

工作流已在 GitHub runner 上真实运行并通过：28 tests / 3 suites，
`** TEST SUCCEEDED **`。

## 边界

该工作流只证明模拟器上的构建与单元测试结果。它不覆盖真机、签名、权限、
推送、后台模式和发布验证。`generic/platform=iOS Simulator` 只能用于构建
验证，不得用于声称测试已真实执行。
