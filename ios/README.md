# SlowWalk iOS 客户端

此目录保存 Apple 平台专属源码。可由 Linux 验证的客户端 use-case protocol、
View state、request builder、协调器、mock 与 bounded location history 已统一放入
`SlowWalkClientCore`。正式 Xcode 工程已经落地。药品采集已接入 AVFoundation/
相册、Apple Vision 设备内文字识别、可选的在线包装识别客户端，以及既有
canonical 药品评估管线。Simulator 测试不代表已经验证 CoreLocation、SwiftData、
ActivityKit、相机权限弹窗或真机行为。

## 计划结构

```text
SlowWalkApp/
├── App/                 SwiftUI 入口与依赖组合
├── Features/
│   ├── MedicineScanner/
│   ├── RiskResult/
│   ├── HealthProfile/
│   ├── MedicationHistory/
│   └── LocationGuard/
├── Services/
│   ├── OCR/
│   ├── Network/
│   ├── Persistence/
│   ├── Speech/
│   └── Location/
└── Resources/
```

当前只添加少量有行为意义的协议和 app shell，不用空 Swift 文件机械填充目录。

## Xcode 工程

- 工程：`ios/SlowWalkApp.xcodeproj`
- Shared Scheme：`SlowWalkApp`
- 最低系统版本：iOS 17.0
- Bundle Identifier：`com.creaope.slowwalk`
  - provisional，尚未注册正式 App ID
- 本地 Package：`../swift-packages/SlowWalkCore`
- App Target 显式依赖：
  - `SlowWalkDomain`
  - `SlowWalkAPIContracts`
  - `SlowWalkClientCore`
- Swift Language Mode：Swift 6
- Strict Concurrency Checking：Complete
- 本阶段未配置真机签名。

无签名模拟器构建命令：

```bash
xcodebuild \
  -project ios/SlowWalkApp.xcodeproj \
  -scheme SlowWalkApp \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/slowwalk-ios-derived-data \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

## 在线药品包装识别配置

在线识别端点由 `AppEnvironment` 统一读取，不在 View 中创建客户端或读取 URL：

- 配置键：`SLOWWALK_MEDICINE_RECOGNITION_BASE_URL`
- 优先级：显式注入、进程环境、Info.plist
- 远程地址只接受 HTTPS；开发环境允许 `localhost`、`127.0.0.1` 和 `::1` 使用 HTTP
- 配置缺失或无效时不发起网络请求，直接使用设备内识别
- “仅在设备上识别”设置会在提交时快照；开启后不会尝试在线请求

在线请求只包含规范化后的药品包装图片与请求 ID，不包含用户健康档案或用药记录。
健康资料仅在识别完成后进入既有本地 `MedicinePipeline` 与风险引擎。在线结果为
`ambiguous`、`noCandidate`、`unreadable`、协议错误或 canonical identity 冲突时，
不会用本地模糊结果静默覆盖；只有离线、超时、限流、Server/Provider 不可用等明确
可恢复错误才进入 Apple Vision 本地兜底。

## 依赖边界

- `App/` 是 iOS 组合根，负责把平台实现注入 Feature。
- Feature 优先依赖 `SlowWalkClientCore` 的协调器与 View state；只有组合根和 adapter
  需要直接接触底层公开模块。
- `Services/` 在 Mac/Xcode 中实现 `SlowWalkClientCore` 定义的 OCR、网络和定位
  协议，以及 iOS 专属的持久化和语音协议。
- Feature/View 不直接创建 URLSession、Repository、Clock 或定位对象。
- 任何 Apple 平台类型都不得加入 `SlowWalkCore` 的跨平台 SwiftPM target。
- 风险等级由核心引擎或服务端计算，View 只显示结果，不复制规则。
- 在线包装识别 adapter 只实现 `OnlineMedicineRecognitionRequesting`，其请求类型在
  编译期不包含健康资料；本地评估仍使用既有 `MedicineAssessmentRequesting`。
- Location network adapter 只实现 `LocationAssessmentRequesting`；各 adapter 只传输
  自己边界内的 canonical API DTO。
- 旧 raw risk DTO 与 `/api/v1/risk/assess` 已关闭；iOS 不得构造或提交完整
  `Medicine`、ingredient 或 `SourceReference`。
- 错误分支统一按 typed `APIErrorCode` 处理；旧 lowercase code 只由 contracts
  中的单一兼容 decoder 接收。
- UI 分别解释 `resolutionCacheStatus` 与 `knowledgeCacheStatus`，不得把 cache hit
  当作 freshness 或医学安全结论。
- 药品与位置卡片共享 `SlowWalkDomain.RiskLevel`，但分别显示各自 reasons/actions。

## Canonical client flow

```text
OCRImageInput
  → RemoteFirstMedicineRecognitionRouter
      → configured remote recognition (image + request ID only)
      → approved recoverable failure: Apple Vision + local mapper
  → existing MedicineRecognitionInput
  → MedicineAssessmentRequestDTO
  → LocalMedicineAssessmentRequester
  → existing MedicinePipeline / MedicineResolver / MedicationRiskEngine
  → MedicineAssessmentViewState

LocationSampleProviding
  → bounded [LocationSample]
  → LocationAssessmentRequestBuilder
  → LocationAssessmentRequestDTO
  → LocationAssessmentRequesting
  → LocationAssessmentViewState
```

旧的 `imageData → MedicineScanEvent` OCR 协议、`LocationSnapshotProviding` 单点协议
和 raw risk network 协议不再是正式接口，也不在 `ios/` 保留并行定义。

## Mac/Xcode 集成清单

1. 已在 Xcode 中创建正式 iOS App 工程，未手写 `pbxproj`。
2. 已以本地 Package 方式添加 `../swift-packages/SlowWalkCore`。
3. 已将 `SlowWalkApp/` 源码加入 iOS target，并将 deployment target 设为 iOS 17.0。
4. 已使用 Swift 6 Complete strict concurrency 完成 app shell 模拟器编译。
5. 配置相机、位置、语音等用途说明与最小权限。
6. 在 Mac/Xcode 中实现并验证：
   - `VisionMedicineTextRecognizer`
   - `CoreLocationSampleProvider`
   - `URLSessionMedicineAssessmentClient`
   - `URLSessionLocationAssessmentClient`
7. 另外提供受保护的 SwiftData/文件存储与 `AVSpeechSynthesizer` 实现。
8. 验证 Dynamic Type、VoiceOver、对比度、触控尺寸和非颜色风险表达。
9. 在模拟器和真机测试权限拒绝、离线、超时、低置信度与数据清除。
10. 为 arrived、approaching、progressing、trend indeterminate、low accuracy
   分别验证文案和无障碍标签，禁止用统一“已接近或到达”覆盖不同证据。

## 医疗与隐私

- 屏幕必须明确这是风险提示，不是诊断。
- 识别失败或证据不足不能显示绿色“安全”状态。
- 当前 JSON Repository **未加密且没有 Apple Data Protection**；正式 adapter
  完成受保护存储前，不得写入真实健康资料。
- 不把健康数据、完整位置轨迹、药名或来源详情写入日志/错误响应。
- 日后引入真实数据前必须完成隐私清单、保留期限和删除流程评审。
- 任何演示数据都标注 `DEMO DATA — NOT FOR CLINICAL USE`。

药品相机采集、Vision OCR 和在线包装识别 URLSession adapter 已有 Simulator
单元/组合测试。CoreLocation、受保护持久化、位置网络 adapter 与真机权限流程仍需
后续实现或验证；Simulator 构建不能替代真机验证。
