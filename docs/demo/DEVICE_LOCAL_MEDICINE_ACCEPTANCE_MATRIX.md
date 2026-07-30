# 端侧本地 Medicine Assessment 验收矩阵与集成契约审计

## 审计元信息

| 项目 | 值 |
| --- | --- |
| 仓库 | `/Users/xiazihan/Developer/slow-walk-medicine-matrix` |
| 分支 | `docs/medicine-assessment-acceptance-matrix` |
| HEAD | `1068f18012a2f093720b1514fd7807138bb8eb38` |
| 基线 | `origin/develop`（`git rev-list --left-right --count origin/develop...HEAD` → `0 0`，与 origin/develop 同步） |
| 审计日期 | 2026-07-30（本文件为第二轮审计，第一轮基线落后 1 个提交，已在此轮修正） |
| 性质 | 只读审计。本轨道只修改本文件，不修改 `ios/**`、`swift-packages/**`、`server/**`、`demo-fixtures/**`、`.github/**` |
| 已合入基线 | PR #19（`1068f18`）：`fix(ios): gate medicine flow until assessment succeeds`。本文件第二轮审计以合入 PR #19 后的 develop 为事实来源 |
| 参照分支 | `origin/feature/canonical-medicine-presentation`（PR #17，`4130cc9`），通过 `git show` 只读读取，未 checkout、未 merge |

本文件所有字段值均来自当前分支生产源码、当前分支测试或 `demo-fixtures/` 的
canonical fixture。**没有任何一项由场景名推断。** 每行结论都给出可定位路径。
本文件不复制 DTO 定义、风险枚举定义或业务规则实现，只引用它们的路径与字段名。

---

## 一、当前正式链路

### 1.1 链路顺序

```text
识别输入        MedicineTextRecognizing → MedicineRecognitionInputMapper
候选与解析      MedicineResolving（normalizer + resolver）
知识治理        MedicineKnowledgeSearching → KnowledgeGovernanceVerdict
风险与卡片      MedicinePipeline.assess → RiskAssessing → ActionCardFactory.makeCard
canonical 响应  MedicineAssessmentResponseDTO
调用缝          MedicineAssessmentRequesting.assess
客户端状态机    MedicineAssessmentCoordinator → MedicineAssessmentViewState
展示映射        MedicineStateMapper → MedicineDisplayState → MedicineAssessmentView
App 状态        CompanionFlowState → awaitingMedicineAssessment → (future) assessment success → Presentation
关怀记录        CareRecordStoring.append → CareRecordEventKind
```

### 1.2 每一环的真实存在状态

| 环节 | 类型 / 路径 | 状态 |
| --- | --- | --- |
| OCR 协议 | `MedicineTextRecognizing`，`swift-packages/SlowWalkCore/Sources/SlowWalkClientCore/OCRContracts.swift:106` | **已存在（协议）**；唯一实现是 `NetworkMocks.swift:14` 的 mock。仓库内 `import Vision` 零命中，真实 OCR adapter **不存在** |
| 输入映射 | `MedicineRecognitionInputMapper` | 已存在，Coordinator 构造参数 |
| 请求构造 | `MedicineAssessmentRequestBuilding`，Coordinator `:17`、`:32` | 已存在，有默认实现 |
| 解析与知识 | `MedicinePipeline.resolve`，`Sources/SlowWalkMedicinePipeline/MedicinePipeline.swift:203-310` | 已存在 |
| 知识确认改写 | `applyingKnowledgeConfirmation`，同文件 `:312-337` | 已存在 |
| 知识安全改写 | `applyKnowledgeSafety`，同文件 `:354-401` | 已存在 |
| 卡片工厂 | `ActionCardFactory.makeCard`，`Sources/SlowWalkMedicinePipeline/ActionCardFactory.swift:8-71` | 已存在 |
| canonical 响应 | `MedicineAssessmentResponseDTO`（`SlowWalkAPIContracts`） | 已存在 |
| **调用缝** | `MedicineAssessmentRequesting`，`Sources/SlowWalkClientCore/AssessmentRequestContracts.swift:5` | **协议已存在，非 mock 实现不存在**。全仓库 `grep MedicineAssessmentRequesting` 只命中协议、Coordinator、`NetworkMocks.swift:60` 与两个测试替身 |
| 客户端状态机 | `MedicineAssessmentCoordinator`，`Sources/SlowWalkClientCore/MedicineAssessmentCoordinator.swift:9` | 已存在（actor，`generation` 代际防串） |
| 视图状态 | `MedicineAssessmentViewState`，`Sources/SlowWalkClientCore/ClientViewStates.swift:104-116` | 已存在 |
| 展示映射 | `MedicineStateMapper` | **只在 PR #17 分支存在**，当前分支 `swift-packages/` 下只有 `SlowWalkCore` 一个包 |
| 展示视图 | `MedicineAssessmentView` / `MedicineActionCardView` / `RiskLevelBadge` | 只在 PR #17 分支存在 |
| App 工程引用 | `ios/SlowWalkApp.xcodeproj/project.pbxproj:179`、`:513-515` | **只引用 `../swift-packages/SlowWalkCore`**，产品为 `SlowWalkAPIContracts`/`SlowWalkClientCore`/`SlowWalkDomain`。无 `SlowWalkPresentation` 引用，`ios/` 下 `import SlowWalkPresentation` 零命中 |
| App 组装根 | `ios/SlowWalkApp/App/AppEnvironment.swift:15-57` | 装配 `clock` / `TodayPlan` / `InMemoryCareRecordStore` / `CompanionSessionModel` / **`CapabilityCatalog`**（统一由 `AppEnvironment` 注入）。**未装配 Coordinator，未装配任何 requester** |
| App 安全门 | `MedicineAssessmentGate`，`ios/SlowWalkApp/Features/Companion/CompanionFlowState.swift:107-118` | **PR #19 新增**。`confirmMedicine` 后进入 `awaitingMedicineAssessment`，不会进入任何显示关怀动作的状态。`showingRiskAction(ConfirmedMedicine)` 已被删除 |
| App 卡片位 | 原 `CareActionPresentationSlot.swift` | **PR #19 已删除**。当前无占位卡片视图。未来由 PR #17 `MedicineActionCardView` 接替 |
| 关怀记录 | `CareRecordEventKind`，`ios/SlowWalkApp/Features/CareRecords/CareRecordEvent.swift:36-61` | 已存在，8 个 case（含 `medicineAssessmentDidNotSucceed`），不携带风险等级与用药结论 |

### 1.3 已接入 / 未接入的明确分界

**已经打通（当前分支可编译路径）**：识别 → 请求 → `MedicineAssessmentRequesting`
→ Coordinator → `MedicineAssessmentViewState`。服务端一侧 Pipeline → canonical 响应
同样打通，并由 `server/Tests/SlowWalkServerTests/MedicineDemoFixtureGoldenTests.swift:34`
与 `:49` 两个 golden 测试以真实 composition root 驱动。

**尚未接入 App 的四处断点**：

1. `SlowWalkPresentation` 包不在当前分支，也不在 App 工程的 package 引用里。
2. App 组装根没有 Coordinator，也没有任何 `MedicineAssessmentRequesting` 实现。
3. `MedicineTextRecognizing` 只有 mock 实现，端侧真实识别器不存在。
4. App 内无可展示 assessment 结果的视图——原 `CareActionPresentationSlot.swift`
   已被 PR #19 删除，`showingRiskAction(ConfirmedMedicine)` 状态已被移除，
   取而代之的是 `awaitingMedicineAssessment(MedicineAssessmentGate)` 安全门。

**App 侧当前实际链路（已从生产源码确认）**：

```
candidate confirmation（CompanionSessionModel.swift:151-173）
→ 写入 medicineConfirmed（confirmMedicine 自身直接追加）
→ beginMedicineAssessment() → capability 为 unavailable
→ 写入 medicineAssessmentDidNotSucceed(.capabilityNotAvailableYet)
→ 一次确认最终形成两条真实过程记录。当前不会写入 careActionShown
→ beginMedicineAssessment()（:212-231）
→ capabilities.availability(of: .medicineRiskAssessment).isImplemented == false
→ 写入 medicineAssessmentDidNotSucceed(.capabilityNotAvailableYet)
→ 状态停留在 awaitingMedicineAssessment（gate progress = .couldNotAssess(.notWiredUpYet)）
→ recovery: reconsiderMedicineChoice / retakeMedicinePhoto / endEarly
（CompanionFlowReducer.swift:116-129）
```

**关键事实（PR #19 已实施）**：

- `confirmMedicine` 自身直接追加 `medicineConfirmed`，随后 `beginMedicineAssessment()` 因 capability 为 `.unavailable` 再追加 `medicineAssessmentDidNotSucceed(.capabilityNotAvailableYet)`。一次确认形成两条真实过程记录。**不再写 `careActionShown`**
  （`CompanionSessionModel.swift:157-168`，源码注释明确 "No `careActionShown` record is written here, and none may be"）
- `showingRiskAction(ConfirmedMedicine)` 状态**已被删除**
  （`CompanionFlowState.swift:132-137` 注释记录了删除理由）
- `awaitingMedicineAssessment(MedicineAssessmentGate)` 是**新增安全门**
  （`CompanionFlowState.swift:145`）
- `travelling` 状态仍存在但**当前不可达**——从 `awaitingMedicineAssessment`
  没有进入 `travelling` 的 transition（`CompanionFlowReducer.swift:131-136`）
- `canDepart` **恒为 false**——`MedicineAssessmentProgress` 的两个 case
  （`notStarted`、`couldNotAssess`）均不携带 assessment result
  （`CompanionSessionModel.swift:90-96`）
- `CareActionPresentationSlot.swift` **已被删除**
- `CapabilityCatalog` 统一由 `AppEnvironment` 组装并注入
  （`AppEnvironment.swift:29`、`:35`、`:47`），不再有第二处默认值

---

## 二、六场景验收矩阵

### 2.1 公共前置条件（六场景一致）

| 项目 | 值 | 来源 |
| --- | --- | --- |
| `request.apiVersion` | `v1` | 五个 JSON fixture 均为 `v1` |
| `input.capturedAt` | `2026-07-25T07:59:00Z` | 五个 fixture 一致 |
| `input.rawConfidence` | `0.98` | 五个 fixture 一致 |
| `recentRecords` | 空数组 | 五个 fixture 一致 |
| `resolution.evidence.matcherVersion` | `slowwalk-resolver-v1` | 五个 fixture 一致，由 `DemoFixtureContractTests.swift:286` 冻结 |
| `sourceDataVersion` | `mock-authoritative-medicine-source=demo-authoritative-v1;mock-secondary-medicine-source=demo-secondary-v1` | 五个 fixture 一致 |
| 免责标签 | `DEMO DATA — NOT FOR CLINICAL USE` | `DemoFixtureContractTests.swift:432` 冻结在 fixture、medicine.warnings、resolved 场景的 card.warnings 与 configurationNotices 上 |
| 剂量字段 | 所有 medicine 的 `dosageTextFromSource` 均为 `nil` | 同上测试断言 |

Coordinator 判定顺序（`MedicineAssessmentCoordinator.swift`，六场景全部走这一条链）：
`:85` 识别文本为空 → `:120` `status == .ambiguous` → `:132` `status != .resolved`
→ `:144` `requiresUserConfirmation` → `:157` `.result` → `:162` 取消 → `:166` 失败。
**只有走到 `:157` 才是 `result`。**

---

### 2.2 场景 `normal`

| 验收项 | 期望值 | 来源 |
| --- | --- | --- |
| 输入文件 | `demo-fixtures/medicine-normal.json` | `demo-fixtures/README.md:27` |
| 识别 / 确认前置 | `recognizedTexts = ["Acetaminophen"]`；`bodyMetrics.measuredAt = 2026-07-25T07:55:00Z`；`allergies = []` | fixture `request` |
| 关键请求字段 | `requestID = …0101` | fixture |
| Coordinator ViewState | `result` | `README.md:27`；`resolution.status = resolved` 且 `requiresUserConfirmation = false`，命中 `Coordinator:157` |
| 允许最终 ActionCard | **是**，且是唯一允许"普通用药说明"的形态之一（`allowsOrdinaryExplanation = true`） | fixture `expectation`；`DemoFixtureContractTests.swift:152` |
| RiskLevel | `green` | fixture `actionCard.riskLevel` 与 `assessment.level` |
| title | `Acetaminophen` | fixture（= `selectedMedicine.canonicalName`，`ActionCardFactory.swift:54`） |
| primaryInstruction | `Review the verified source information before use.` | fixture；`ActionCardFactory.swift:100-101` green 分支 |
| warnings | 1 条：`DEMO DATA — NOT FOR CLINICAL USE` | fixture |
| recommendedActions | `[follow_verified_source_information]` | fixture；`DemoFixtureContractTests.swift:198` 冻结内容与顺序 |
| sourceReferences | 2 条：`Mock Authoritative Medicine Source@demo-authoritative-v1`、`Mock Secondary Medicine Source@demo-secondary-v1` | fixture |
| mustConfirmMedicine | `false` | fixture |
| 健康完整度 | `assessment.evidenceCompleteness = complete`；`healthContextValidation.status = valid`，`warnings = []` | fixture；`DemoFixtureContractTests.swift:361` 冻结 `complete ⟺ warnings 为空` |
| 知识完整度 / 治理 | `completeness = 0.95`；`sourceStatus = corroborated`；`isOffline = false`；`requiresConservativeAction = false`；`allowsDosageDisplay = true`；`freshnessStatus = current`；`provenanceStatus = verified`；`cacheStatus = miss`，`resolutionCacheStatus = miss` | fixture `medicineKnowledge` |
| 页面允许的按钮 | 无。`requiresMedicineConfirmation = false`，PR #17 `MedicineActionCardView` 的确认区块受 `:62` 门控；失败区块不进入 | PR #17 `MedicineActionCardView.swift:62`、`:283-287` |
| 页面禁止的按钮 | 「确认药物」、「重试」 | 同上 + `MedicineAssessmentView.swift:160-174` 只在 failure 分支渲染重试 |
| 必须写入的 Care Record | `medicineReadStarted(attemptNumber:)`；成功展示卡片后 `careActionShown(medicineName:)` | `CareRecordEvent.swift:38`、`:59` |
| 禁止写入的 Care Record | `medicineReadDidNotSucceed`、`medicineConfirmed`（本场景无用户确认动作） | `CareRecordEvent.swift:39`、`:43` |
| 禁止的医疗表述 | 剂量、诊断、停药、处方；不得把 `follow_verified_source_information` 改写成任何服用指示 | `RecommendedAction` 定义（`Sources/SlowWalkDomain/RiskAssessment.swift:39-49`）本身不含剂量语义 |

---

### 2.3 场景 `healthWarning`

| 验收项 | 期望值 | 来源 |
| --- | --- | --- |
| 输入文件 | `demo-fixtures/medicine-health-warning.json` | `README.md:29` |
| 识别 / 确认前置 | `recognizedTexts = ["Acetaminophen"]`；**`bodyMetrics.measuredAt = 2026-06-20T08:00:00Z`（过期）**；`allergies = []` | fixture `request` |
| 关键请求字段 | `requestID = …0103`；触发点只有 `measuredAt` 一项与 `normal` 不同 | 与 `normal` 逐字段比对 |
| Coordinator ViewState | `result`（`status = resolved`、`requiresUserConfirmation = false`） | `README.md:29` + fixture |
| 允许最终 ActionCard | **是**，`allowsOrdinaryExplanation = true` | fixture `expectation` |
| RiskLevel | `yellow` | fixture。**成因是 `evidenceCompleteness = partial` 走 `ActionCardFactory.swift:26-30` 的 `max(.yellow, …)` 与风险规则本身**，不是页面判定 |
| title | `Acetaminophen` | fixture |
| primaryInstruction | `Pause and review the available information.` | fixture；`ActionCardFactory.swift:102-103` yellow 分支 |
| warnings | 5 条：demo 标签、`The measurement is older than the demo recency limit.`、`Body metrics are older than the configured demo age limit.`、`Health-context data-quality warnings require review.`、`Available information is incomplete or internally inconsistent.` | fixture |
| recommendedActions | `[consult_healthcare_professional, review_medicine_sources, remeasure_body_metrics]`（卡片）；`assessment.recommendedActions` 为 `[consult_healthcare_professional, remeasure_body_metrics]` | fixture；差集由 `ActionCardFactory.swift:37-43` 的非完整证据分支追加 |
| sourceReferences | 与 `normal` 相同 2 条 | fixture |
| mustConfirmMedicine | `false`（知识治理未要求保守动作） | fixture |
| 健康完整度 | `evidenceCompleteness = partial`；`healthContextValidation.status = valid_with_warnings`，唯一 warning `STALE_BODY_METRICS`（field `bodyMetrics.measuredAt`，rule `body-metrics-recency`）；`assessment.reasons` 码为 `body_metrics_stale` / `health_context_warning` / `missing_evidence` | fixture |
| 知识完整度 / 治理 | 与 `normal` 完全相同（`0.95` / `corroborated` / 非离线 / 非保守 / 允许剂量位 / `current` / `verified` / `miss`） | fixture |
| 页面允许的按钮 | 无 | 同 `normal` |
| 页面禁止的按钮 | 「确认药物」、「重试」 | 同 `normal` |
| 必须写入的 Care Record | `medicineReadStarted`；展示卡片后 `careActionShown` | `CareRecordEvent.swift:38`、`:59` |
| 禁止写入的 Care Record | `medicineConfirmed`、`medicineReadDidNotSucceed` | — |
| 禁止的医疗表述 | 剂量、诊断、停药、处方；不得把体征过期改写成任何身体状况判断；不得把 `remeasure_body_metrics` 表述成检查建议之外的内容 | `RiskAssessment.swift:39-49` |

---

### 2.4 场景 `knowledgeWarning`

| 验收项 | 期望值 | 来源 |
| --- | --- | --- |
| 输入文件 | `demo-fixtures/medicine-source-warning.json`（**文件名与 fixtureID 不同名**） | `README.md:30` |
| 识别 / 确认前置 | 请求与 `normal` 同形，`requestID = …0104`；差异全部来自运行环境：知识源离线、缓存 stale | fixture；golden 测试 `MedicineDemoFixtureGoldenTests.swift:49` 用 online `08:00:00Z` → staleOffline `08:20:00Z` 切换 transport 复现 |
| 关键请求字段 | `response.generatedAt = 2026-07-25T08:20:00Z`（六场景中唯一非 `08:00:00Z`） | fixture |
| Coordinator ViewState | **`requiresMedicineConfirmation`**，reason `serverRequiresConfirmation`。`status` 确实是 `resolved`，但 `requiresUserConfirmation = true` 让判定在 `Coordinator:144` 提前返回，走不到 `:157` | `README.md:30`、`:34`；`Coordinator.swift:144`；改写点 `MedicinePipeline.swift:312-337` |
| 允许最终 ActionCard | **不允许作为已结算结果**。响应确实携带 `actionCard`，PR #17 会渲染，但 `allowsOrdinaryExplanation = false`，卡片是确认门控卡而非最终结论 | fixture `expectation`；`DemoFixtureContractTests.swift:152` |
| RiskLevel | `yellow`。成因是 `applyKnowledgeSafety` 强制 `max(.yellow, …)`，**不得由页面推导** | `MedicinePipeline.swift:383-401` |
| title | `Acetaminophen` | fixture |
| primaryInstruction | `Pause and review the available information.` | fixture |
| warnings | 5 条：demo 标签、`Offline cached data is stale and is not current authoritative data.`、`A whitelisted source was unavailable.`、`Live sources were unavailable. Stale cached demo data is being used and is not current authoritative data.`、`Medicine knowledge requires source review, so a green result is not permitted.` | fixture；最后一条由 `MedicinePipeline.swift:366-377` 生成 |
| recommendedActions | `[do_not_take_until_medicine_confirmed, consult_healthcare_professional, review_medicine_sources]`（卡片）；`assessment.recommendedActions` 为 `[consult_healthcare_professional, review_medicine_sources]` | fixture；`do_not_take…` 由 `ActionCardFactory.swift:44-51` 的知识确认分支追加 |
| sourceReferences | 2 条，与 `normal` 相同 | fixture |
| mustConfirmMedicine | **`true`**，直接来自 `requiresKnowledgeConfirmation` | fixture；`ActionCardFactory.swift:67-68` |
| 健康完整度 | `evidenceCompleteness = insufficient`（`applyKnowledgeSafety` 在 `isOffline` 时取 `min(…, .insufficient)`）；`healthContextValidation.status = valid_with_warnings`，2 条 warning 均 field `medicineKnowledge`、rule `medicine-knowledge-source-safety`：`KNOWLEDGE_SOURCE_UNAVAILABLE`、`OFFLINE_CACHE_USED`；`assessment.reasons` 只有 `knowledge_source_warning` | fixture；`MedicinePipeline.swift:395-400`、`:403-444` |
| 知识完整度 / 治理 | `completeness = 0.5`；`sourceStatus = stale_offline`；`isOffline = true`；`requiresConservativeAction = true`；`requiresConfirmation = true`；**`allowsDosageDisplay = false`**；`freshnessStatus = stale`；`provenanceStatus = verified`；`knowledgeCacheStatus = stale_offline`；`resolutionCacheStatus = expired` | fixture；派生规则 `Sources/SlowWalkMedicineKnowledge/MedicineKnowledgeModels.swift:449-529`；`stale_offline → expired` 见 `MedicinePipeline.swift:347-348`；联合一致性由 `DemoFixtureContractTests.swift:386` 冻结 |
| 页面允许的按钮 | 「确认药物」（`requiresMedicineConfirmation = true` 打开确认区块，且宿主传入 `confirmAction` 时才渲染） | PR #17 `MedicineActionCardView.swift:62`、`:283-287` |
| 页面禁止的按钮 | 「重试」（result 路径不渲染重试）；任何"按剂量服用"「继续」类按钮 | `MedicineAssessmentView.swift:60-70`、`:160-174` |
| 必须写入的 Care Record | `medicineReadStarted`；**只有在正式确认真正发生后**才写 `medicineConfirmed(medicineName:origin:)` | `CareRecordEvent.swift:38`、`:43` |
| 禁止写入的 Care Record | **`careActionShown`**（未确认前不得记录"已展示关怀动作"） | `CareRecordEvent.swift:59` |
| 禁止的医疗表述 | 剂量（`allowsDosageDisplay = false` 明确禁止）、诊断、停药、处方；不得把 stale 缓存表述为现行权威数据 | fixture 治理裁决 + fixture warnings 原文 |

---

### 2.5 场景 `redRisk`

| 验收项 | 期望值 | 来源 |
| --- | --- | --- |
| 输入文件 | `demo-fixtures/medicine-red-risk.json` | `README.md:31` |
| 识别 / 确认前置 | `recognizedTexts = ["Acetaminophen"]`；**`allergies = ["acetaminophen"]`**；`bodyMetrics.measuredAt = 2026-07-25T07:55:00Z` | fixture `request` |
| 关键请求字段 | `requestID = …0105`；与 `normal` 的唯一差异是 `allergies` | 与 `normal` 逐字段比对 |
| Coordinator ViewState | `result`（`resolved` 且 `requiresUserConfirmation = false`） | `README.md:31` + fixture |
| 允许最终 ActionCard | **是**，但 `allowsOrdinaryExplanation = false` —— 红色卡片不得作为普通用药说明呈现 | fixture；`DemoFixtureContractTests.swift:152` 断言"红色卡片永不读作普通说明" |
| RiskLevel | `red` | fixture |
| title | `Acetaminophen` | fixture |
| primaryInstruction | `Do not take this medicine until a healthcare professional confirms the next step.` | fixture；`ActionCardFactory.swift:106-107` red 分支 |
| warnings | 2 条：demo 标签、`The medicine label matches information in the allergy profile.` | fixture |
| recommendedActions | `[do_not_take_until_medicine_confirmed, consult_healthcare_professional, notify_family_member]`（卡片与 assessment 内容一致，顺序由 `stableActions` 决定） | fixture；`ActionCardFactory.swift:128-150` |
| sourceReferences | 2 条，与 `normal` 相同 | fixture |
| mustConfirmMedicine | **`false`** —— 红色风险与"必须确认药物"是两个互不决定的维度 | fixture；PR #17 `PresentationStateTests` 第 12 项显式冻结这一独立性 |
| 健康完整度 | `evidenceCompleteness = complete`；`healthContextValidation.status = valid`，`warnings = []`；`assessment.reasons` 只有 `allergy_match`；`requiresProfessionalAdvice = true`，`requiresFamilyAttention = true` | fixture |
| 知识完整度 / 治理 | 与 `normal` 完全相同（`0.95` / `corroborated` / 非离线 / 非保守 / `current` / `verified` / `miss`） | fixture |
| 页面允许的按钮 | 无。`notify_family_member` 是卡片内的动作条目，不是按钮 | PR #17 `MedicineActionCardView.swift:193-201` 渲染动作列表 |
| 页面禁止的按钮 | 「确认药物」（`requiresMedicineConfirmation = false`）、「重试」 | 同 `normal` |
| 必须写入的 Care Record | `medicineReadStarted`；展示卡片后 `careActionShown` | `CareRecordEvent.swift:38`、`:59` |
| 禁止写入的 Care Record | `medicineConfirmed`；记录中不得夹带风险等级（`CareRecordEventKind` 本身不含该字段，实现不得绕过） | `CareRecordEvent.swift:36-61` |
| 禁止的医疗表述 | 剂量、诊断、停药、处方。特别地：`primaryInstruction` 是既有 canonical 文案，**不得改写、不得扩写成停药或换药建议** | fixture 原文 |

---

### 2.6 场景 `ambiguous`

| 验收项 | 期望值 | 来源 |
| --- | --- | --- |
| 输入文件 | `demo-fixtures/medicine-ambiguous.json` | `README.md:28` |
| 识别 / 确认前置 | **`recognizedTexts = ["Cold Relief"]`**（非药名，可匹配多条）；**`bodyMetrics` 为 `null`**；`allergies = []` | fixture `request` |
| 关键请求字段 | `requestID = …0102` | fixture |
| Coordinator ViewState | **`requiresMedicineConfirmation`**，reason `ambiguousMedicine`，命中 `Coordinator:120` | `README.md:28`；`Coordinator.swift:120`；`MedicineAssessmentCoordinatorTests.swift:53` 冻结该 reason |
| 允许最终 ActionCard | **否**。`assessment` 字段在响应中根本不存在（`response` 顶层键无 `assessment`），只有 `ActionCardFactory` 的 `confirmationCard` | fixture `response` 键集合；`MedicinePipeline.swift:169-172` 令 assessment 为 `nil`；`ActionCardFactory.swift:16-24` 转入确认卡 |
| RiskLevel | `yellow`，但这是 `confirmationCard` 的**常量**（`ActionCardFactory.swift:92` 硬编码），不是风险结论。页面不得把它当作评估出的风险等级呈现 | 同上 |
| title | `Unable to confirm the medicine` | fixture；`ActionCardFactory.swift:79` |
| primaryInstruction | `Retake a clear photo of the front of the medicine box.` | fixture；`ActionCardFactory.swift:80-81` |
| warnings | 4 条：`Do not take this medicine until its identity is confirmed.`、`More than one medicine matched the recognized text.`、`No body-metrics record was supplied.`、`The profile contains limited health-context evidence.` | fixture；前两条来自 `ActionCardFactory.swift:82-85`、`:118`，后两条来自健康校验 |
| recommendedActions | `[do_not_take_until_medicine_confirmed, retake_medicine_photo, consult_healthcare_professional]` | fixture；`ActionCardFactory.swift:86-90` |
| sourceReferences | **空数组**（`ActionCardFactory.swift:92` 显式给空） | fixture |
| mustConfirmMedicine | **`true`**（`ActionCardFactory.swift:93` 常量 `true`） | fixture |
| 健康完整度 | **无 `assessment`，因此没有 `evidenceCompleteness`**；`healthContextValidation.status = valid_with_warnings`，warnings 为 `BODY_METRICS_MISSING`（field `bodyMetrics`，rule `body-metrics-presence`）与 `PROFILE_EVIDENCE_INCOMPLETE`（rule `profile-evidence-completeness`） | fixture |
| 知识完整度 / 治理 | `completeness = 0.95`；`sourceStatus = corroborated`；`isOffline = false`；`requiresConservativeAction = false`；`allowsDosageDisplay = true`；`freshnessStatus = current`；`provenanceStatus = verified`；`cacheStatus = miss` —— **知识侧完全健康，歧义只来自解析层**，不得把本场景描述成知识源问题 | fixture `medicineKnowledge` |
| 候选集 | `candidates = [demo-chlorpheniramine, demo-dextromethorphan]`，`selectedMedicine = null` | fixture；一致性由 `DemoFixtureContractTests.swift:313` 冻结 |
| 页面允许的按钮 | 「确认药物」（仅当宿主传入 `confirmAction`）。App 侧另允许重拍与从常用列表选择 | PR #17 `MedicineActionCardView.swift:62`、`:283-287`；App `CompanionFlowReducer.swift:65-73`、`CompanionSessionModel.swift:132`、`:137` |
| 页面禁止的按钮 | 「重试」（result 路径不渲染）；任何"确认无误可服用"类按钮 | `MedicineAssessmentView.swift:160-174` |
| 必须写入的 Care Record | `medicineReadStarted`；`medicineReadFoundCandidates(candidateCount: 2)` | `CareRecordEvent.swift:38`、`:42` |
| 禁止写入的 Care Record | **`careActionShown`**；正式确认发生前**禁止 `medicineConfirmed`** | `CareRecordEvent.swift:43`、`:59` |
| 禁止的医疗表述 | 剂量、诊断、停药、处方；禁止把两个候选之一说成"很可能是" | — |

---

### 2.7 场景 `timeout`

| 验收项 | 期望值 | 来源 |
| --- | --- | --- |
| 输入文件 | `demo-fixtures/medicine-timeout.md`（**散文，无 JSON**） | `README.md:32`、`:73-78` |
| 识别 / 确认前置 | 与 `normal` 同形请求，只改 `requestID = …0106`；OCR 输入 `["Acetaminophen"]` | `medicine-timeout.md:12-29` |
| 关键请求字段 | `requestID` **不可观测**：超时映射后 `requestID` 为 `nil`，演示叙述不得声称失败页显示或关联该 ID | `medicine-timeout.md:15-18`；`Sources/SlowWalkClientCore/ClientFailures.swift:130-136` |
| Coordinator ViewState | **`failed`**，`kind = .timeout`，`endpoint = .medicineAssess`，`isRecoverable = true` | `medicine-timeout.md:35`；`ClientFailures.swift:130-136`；`MedicineAssessmentCoordinatorTests.swift:230` 冻结三项 |
| 允许最终 ActionCard | **否，绝对不允许**。响应从未到达 | `medicine-timeout.md:37`；PR #17 `MedicineStateMapper.swift:85-99` 硬性 `actionCard: nil` |
| RiskLevel | **无**。客户端不得发明风险结果 | `medicine-timeout.md:33-34` |
| title | 无卡片，故无 title。页面只显示 `failureName(.timeout)` 与 `noResultAvailableText` | PR #17 `MedicinePresentationCopy.swift:186-192`、`:206`；`MedicineAssessmentView.swift:141-158` |
| primaryInstruction | **无**。不得渲染任何用药指示 | 同上 |
| warnings | 无 canonical warnings。不得编造 `APIErrorDTO`、风险等级或用药指示 | `medicine-timeout.md:44-52` |
| recommendedActions | **空**。建议联系家人：否；建议联系专业人员：否 | `medicine-timeout.md:38-40` |
| sourceReferences | 无 | 无卡片 |
| mustConfirmMedicine | 不适用（无卡片） | — |
| 健康完整度 | 不适用（无 `assessment`、无 `healthContextValidation`） | 无响应 |
| 知识完整度 / 治理 | 不适用（未产生 `medicineKnowledge`） | 无响应 |
| 页面允许的按钮 | 「重试」，仅当 `allowsRetry == true`（由 `failure.isRecoverable` 决定）且宿主传入 `retryAction` | PR #17 `MedicineDisplayState.swift:68`；`MedicineAssessmentView.swift:160-174` |
| 页面禁止的按钮 | 「确认药物」（failure 路径不渲染确认区块） | `MedicineAssessmentView.swift:60-61` 走 `failureContent`，不经过卡片 |
| 必须写入的 Care Record | `medicineReadStarted`；`medicineReadDidNotSucceed(MedicineReadSetback)` | `CareRecordEvent.swift:38-39` |
| 禁止写入的 Care Record | **`careActionShown`**、**`medicineConfirmed`**、`medicineReadFoundCandidates` | `CareRecordEvent.swift:42`、`:43`、`:59` |
| 禁止的医疗表述 | 全部。超时页面上任何剂量、诊断、停药、处方或风险表述都是无源头的发明 | `medicine-timeout.md:44-52` |

---

### 2.8 六场景一页速查

| fixtureID | ViewState | 卡片 | RiskLevel | mustConfirm | evidenceCompleteness | 知识保守动作 | 允许按钮 | 允许 `careActionShown` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `normal` | `result` | 最终卡 | `green` | `false` | `complete` | 否 | 无 | 是 |
| `healthWarning` | `result` | 最终卡 | `yellow` | `false` | `partial` | 否 | 无 | 是 |
| `knowledgeWarning` | `requiresMedicineConfirmation` | 门控卡 | `yellow` | `true` | `insufficient` | **是** | 确认药物 | 确认后才可 |
| `redRisk` | `result` | 最终卡（非普通说明） | `red` | `false` | `complete` | 否 | 无 | 是 |
| `ambiguous` | `requiresMedicineConfirmation` | 确认卡（无 assessment） | `yellow`（常量） | `true` | 无 | 否 | 确认药物 | **否** |
| `timeout` | `failed` | **无** | **无** | 不适用 | 无 | 不适用 | 重试 | **否** |

---

## 三、`ambiguous` 边界

### 3.1 只允许进入候选确认或待定状态

`ambiguous` 只能落在 `MedicineAssessmentViewState.requiresMedicineConfirmation`
（`ClientViewStates.swift:110-112`），reason 为 `ambiguousMedicine`
（`ClientViewStates.swift:66` 起的 `MedicineConfirmationReason`）。

PR #17 把 `noRecognizedText` / `ambiguousMedicine` / `unresolvedMedicine` 三个 reason
统一映射到展示变体 `.ambiguous` 并置 `requiresMedicineConfirmation = true`
（`MedicineStateMapper.swift:118-137`）。因此**下一阶段的 App 状态只能是
"待确认"，不得进入任何已结算态**。

### 3.2 正式确认前不得产出最终 ActionCard

`ambiguous` 的响应里没有 `assessment` 键。`ActionCardFactory.swift:16-24`
在 `status != .resolved` 或缺少 `selectedMedicine` 或缺少 `assessment` 时一律转入
`confirmationCard`。App 若在确认前展示任何带风险结论的卡片，就是在
Core 从未产出该结论的情况下自造结论。

PR #17 的 `MedicineAssessmentView.swift:85-120` 已给出正确姿态：卡片缺失时只渲染
"确认要求"标题与 `noResultAvailableText`，源码注释明确"must not fabricate a card,
a level, or an instruction"。

### 3.3 不得把候选名重新伪装成 OCR 文本

`request.input.recognizedTexts` 是 `["Cold Relief"]`——识别到的包装文字，
不是任何候选药名。两个候选是 `demo-chlorpheniramine` 与 `demo-dextromethorphan`。
把候选 `displayName` 写回 `recognizedTexts` 再次调用 assessment，会让
`MedicineResolver` 面对一个从未被识别过的输入，`resolution.evidence` 与
`MedicineScanEvent.recognizedText`（`MedicinePipeline.swift:469-488`）都会记录一段
用户从未拍到的文字。**这条路径必须禁止。**

（PR #17 的测试替身 `CoordinatorHarness` 由 `request.input.recognizedTexts` 反向重建
observation，是测试内的受控做法，不是生产确认通道。）

### 3.4 不得硬编码风险等级

`ambiguous` 卡片的 `yellow` 来自 `ActionCardFactory.swift:92` 的确认卡常量，
`mustConfirmMedicine` 的 `true` 来自 `:93` 的常量。它们描述的是"药物身份未确认"，
不是"评估出黄色风险"。PR #17 的 `MedicineDisplayState.swift:127` 只做
`actionCard?.riskLevel` 直读，从不从变体反推等级——下一阶段的 App 必须沿用这一姿态。

### 3.5 缺失的正式确认命令（阻塞项）

**已从生产源码确认：Core 目前没有提交用户确认结果的通道。**

- `MedicineAssessmentCoordinator` 的公开方法只有
  `assess(imageInput:userProfile:recentRecords:requestID:)`（`:49`）、
  `cancelCurrentAssessment()`（`:188`）、`reset()`（`:195`）。
- `MedicineConfirmationRequirement`（`ClientViewStates.swift:80-88`）只有
  `reason`、`recognitionInput`、`response` 三个字段，**没有任何字段可以承载
  用户选中的候选**。

缺失的命令需要具备三项能力，缺一不可：

1. 接收 `MedicineConfirmationRequirement` 中某个候选的**稳定标识**
   （如 `resolution.candidates[i].medicine.id`），而不是显示名或文本。
2. 携带确认来源，使 `CareRecordEventKind.medicineConfirmed(medicineName:origin:)`
   的 `origin` 有真实取值，而不是由 App 猜测。
3. 复用 Coordinator 的 `generation` 代际机制（`:26`、`:56-57`），
   使一次过期确认无法覆盖新一轮 assessment 的状态。

在该命令进入 `SlowWalkClientCore` 之前，**下一阶段不得为 `ambiguous` 或
`knowledgeWarning` 写入 `medicineConfirmed`**，因为"确认"这件事在 Core 里还不存在。

---

## 四、`timeout` 边界

### 4.1 它是调用失败态，不是结果态

`ClientTransportError.timedOut`（`ClientFailures.swift:25`）经
`ClientFailureMapper` 映射为 `kind = .timeout`、`requestID = nil`、
`endpoint = .medicineAssess`、`isRecoverable = true`（`:130-136`）。
Coordinator 在 `:166` 落入 `.failed(ClientFailure)`。整个过程**没有任何响应到达**。

`MedicineDemoFixtureGoldenTests` 不覆盖本场景——它没有 canonical JSON 可比。
它由 `MedicineAssessmentCoordinatorTests.swift:230` 与 PR #17 的
`PresentationStateTests` 第 14 项覆盖。

### 4.2 不得显示上一次成功的风险卡

PR #17 `MedicineStateMapper.swift:85-99` 在 `.failed` 分支硬性写入
`actionCard: nil`，源码注释"No risk level, instruction, or action card is invented"。
`MedicineAssessmentView.swift:60-61` 把 `.timeout` 与 `.failed` 一起导向
`failureContent`，该分支根本不引用 `state.actionCard`。

**下一阶段的 App 必须做到同一件事：超时时清空已渲染的卡片，而不是保留上一次
成功结果。** 保留旧卡片会让使用者以为这一次拍照也得到了结论。

### 4.3 不得写入 `careActionShown`

`careActionShown(medicineName:)`（`CareRecordEvent.swift:59`）的语义是
"关怀动作已经展示给使用者"。超时场景下没有任何关怀动作可展示，写入即失实。

**当前 App 已不存在此处风险（PR #19 已关闭）**：
`CompanionSessionModel.confirmMedicine`（`:151-173`）已不再写入 `careActionShown`。
`beginMedicineAssessment()`（`:212-231`）在当前 capability 为 `.unavailable` 时写入
`medicineAssessmentDidNotSucceed`，同样不写 `careActionShown`。
`careActionShown` 的唯一可达写入路径是**未来真实展示 assessment result 之后**——当前 build
中该路径不存在。

**下一阶段接入时的注意事项**：一旦把真实 assessment 接入流程，必须确保超时路径不经过任何
写入 `careActionShown` 的代码。`careActionShown` 只能由实际渲染了 canonical `ActionCard`
的代码路径写入。

### 4.4 必须保留重试 / 取消 / 退出路径

| 路径 | 现有支撑 | 状态 |
| --- | --- | --- |
| 重试 | `isRecoverable = true`（`ClientFailures.swift:136`）→ `allowsRetry`（PR #17 `MedicineDisplayState.swift:68`）→ 「Try again」按钮（`MedicineAssessmentView.swift:160-174`）；App 侧 `retryMedicineRead()`（`CompanionSessionModel.swift:132`） | 已存在，但按钮只在宿主传入 `retryAction` 时渲染 |
| 取消 | `cancelCurrentAssessment()`（`Coordinator.swift:188`）→ `.cancelled`，与 `.failed` 是不同状态（`MedicineAssessmentCoordinatorTests.swift:195` 覆盖） | 已存在，App 未接线 |
| 退出 | `endEarly()`（`CompanionSessionModel.swift:190-196`）→ `CompanionFlowReducer.swift:33-35` 从任何进行中状态返回 `.completed(.endedEarly)`，并写 `companionFinished(.endedEarly)` | 已存在，纯本地 |

重试必须由**显式用户动作**触发（`medicine-timeout.md:41-42`），不得自动重发。

---

## 五、下一阶段完成定义（PR 可勾选）

### 5.1 功能完成

- [ ] App 在**不启动 Server** 的前提下完成一次本地 Medicine Assessment：新增一个
      `MedicineAssessmentRequesting` 的端侧实现，直接驱动 `MedicinePipeline`，
      不经过 HTTP。（当前该协议的非 mock 实现为零）
- [ ] App 工程新增 `SlowWalkPresentation` 的 package 引用；
      `ios/SlowWalkApp.xcodeproj/project.pbxproj` 中出现该引用，
      `ios/` 下出现 `import SlowWalkPresentation`。
- [ ] App 组装根装配 `MedicineAssessmentCoordinator`；
      `AppEnvironment` 不再只有 demo 数据。
- [ ] App 接入 PR #17 的 `MedicineActionCardView`（`CareActionPresentationSlot` 已被 PR #19 删除，当前无可展示 assessment 结果的视图）。

### 5.2 五个场景真实跑通

- [ ] `normal`：`result` / `green` / `follow_verified_source_information` 单动作。
- [ ] `healthWarning`：`result` / `yellow` / `evidenceCompleteness = partial` /
      卡片含 `remeasure_body_metrics`。
- [ ] `knowledgeWarning`：`requiresMedicineConfirmation` /
      `mustConfirmMedicine = true` / `allowsDosageDisplay = false` /
      页面不出现任何剂量位。
- [ ] `redRisk`：`result` / `red` / `notify_family_member` 在卡片内 /
      不作为普通用药说明呈现。
- [ ] `timeout`：`failed` / `kind = .timeout` / `actionCard == nil` /
      重试按钮可见 / 无 `careActionShown`。

### 5.3 `ambiguous` 不越过确认边界

- [ ] `ambiguous` 只到达 `requiresMedicineConfirmation`，reason 为 `ambiguousMedicine`。
- [ ] 确认前页面不出现任何风险等级徽标与用药指示。
- [ ] 候选 `displayName` 从未被写回 `recognizedTexts`。
- [ ] 若正式确认命令尚未进入 `SlowWalkClientCore`，本轮**不写入**
      `medicineConfirmed`，并在 PR 描述中明示该阻塞。

### 5.4 View 不自行计算风险

- [ ] 风险等级只由 `actionCard.riskLevel` 直读，不由展示变体或 fixtureID 反推。
- [ ] 不新增第二处 `RiskLevel` → 颜色 / 严重度映射；沿用
      `RiskPresentation`（`ClientViewStates.swift:13-16`）与 PR #17 的 `RiskLevelBadge`。
- [ ] 不匹配任何人类可读警告句子作为判定依据。
- [ ] App 本地不出现任何 `max(.yellow, …)` 之类的等级提升逻辑；
      提升只发生在 `ActionCardFactory.swift:26-30` 与
      `MedicinePipeline.swift:383` 两处既有位置。

### 5.5 Care Record 只记录真实发生的事

- [x] ~~`CompanionSessionModel` 中"确认即写两条记录"的耦合~~ **PR #19 已拆开**。
      `confirmMedicine`（`:151-173`）自身追加 `medicineConfirmed`；随后 `beginMedicineAssessment()`（`:212-231`）因 capability 为 `.unavailable` 再追加 `medicineAssessmentDidNotSucceed(.capabilityNotAvailableYet)`。一次确认形成两条真实过程记录。当前不写 `careActionShown`。
- [ ] `careActionShown` 只在 canonical `ActionCard` 真正渲染后写入。
- [ ] `medicineConfirmed` 只在用户确认动作真正发生后写入，`origin` 为真实取值。
- [ ] `medicineReadDidNotSucceed` 只在读取确实失败（含 `timeout`）时写入。
- [x] ~~`medicineAssessmentDidNotSucceed` 记录~~ **PR #19 已接入**。
      当前 capability 为 `.unavailable` 时正确写入（`CompanionSessionModel.swift:226-230`）。
- [ ] `CareRecordEventKind` 仍不携带风险等级与用药结论
      （`CareRecordEvent.swift:36-61` 的既有约束不被绕过）。

### 5.6 安全表述

- [ ] 页面与记录中零剂量、零诊断、零停药、零处方表述。
- [ ] `DEMO DATA — NOT FOR CLINICAL USE` 在所有结果页可见。
- [ ] 既有 canonical 文案（`ActionCardFactory.swift:98-109` 四条
      `primaryInstruction`）逐字沿用，不改写、不扩写。

---

## 六、已发现的契约缺口

### 6.1 当前仍存在的缺口

| # | 缺口 | 证据 | 影响 | 状态 |
| --- | --- | --- | --- | --- |
| G1 | 无正式确认命令。Coordinator 只有 assess / cancel / reset；`MedicineConfirmationRequirement` 无字段承载用户选择 | `Coordinator.swift:49`、`:188`、`:195`；`ClientViewStates.swift:80-88` | `ambiguous` 与 `knowledgeWarning` 两个场景**无法完成闭环** | **仍存在** |
| G2 | 无非 mock 的 `MedicineAssessmentRequesting` 实现 | 全仓库 grep 只命中协议、Coordinator、mock、两个测试替身 | 端侧本地评估无入口 | **仍存在** |
| G3 | 无非 mock 的 `MedicineTextRecognizing` 实现；`import Vision` 零命中 | `OCRContracts.swift:106`；`NetworkMocks.swift:14` | 真实拍照识别不存在 | **仍存在** |
| G4 | App 工程未引用 `SlowWalkPresentation`，且该包不在当前分支 | `project.pbxproj:179`、`:513-515`；`swift-packages/` 只有 `SlowWalkCore` | 展示层与 App 之间无编译期连接 | **仍存在** |
| G6 | App 本地 `MedicineCandidate` 与 Domain 同名类型重名 | `CompanionFlowState.swift:45-50` | 接入时易误用；建议改名或显式模块限定 | **仍存在** |
| G7 | `CareRecordEventKind` 没有"已解析但未经用户确认"的事件形态 | `CareRecordEvent.swift:36-61` | `normal` / `healthWarning` / `redRisk`（候选唯一、直接 resolved）找不到语义正确的记录 case | **仍存在** |
| G8 | PR #17 定义了展示变体 `elevatedRisk`，但 `demo-fixtures/` 无对应 fixture | PR #17 `MedicineDisplayState.swift:41`（源码自述无 canonical fixture）；`PresentationStateTests` 第 7 项靠改写 `normal` 为 `orange` 构造 | `orange` 等级在端侧没有 canonical 验收样本 | **仍存在** |
| G9 | PR #17 把 `unresolvedMedicine` 映射到展示变体 `.ambiguous` | `MedicineStateMapper.swift:125-137` | `notFound` / `insufficientEvidence` / `recognitionFailed` 三种成因在页面上不可区分 | **仍存在** |
| G10 | `MedicineConfirmationRequirement.response` 可为 `nil`（空 OCR 场景） | `Coordinator.swift:85-90`；`MedicineAssessmentCoordinatorTests.swift:275` 断言 `response` 为 `nil` | App 必须能渲染"无卡片的确认要求"，否则空 OCR 直接崩或空白 | **仍存在** |

### 6.2 已由 PR #19（Phase 0）关闭的历史缺口

| # | 原缺口 | 关闭方式 | 证据 |
| --- | --- | --- | --- |
| G5 | `confirmMedicine` 在无 assessment 参与时同时写 `medicineConfirmed` 与 `careActionShown` | **PR #19 已删除 `careActionShown` 写入**。`confirmMedicine`（`CompanionSessionModel.swift:151-173`）自身追加 `medicineConfirmed`；随后 `beginMedicineAssessment()`（`:212-231`）因 capability 为 `.unavailable` 再追加 `medicineAssessmentDidNotSucceed`。一次确认形成两条真实过程记录。源码注释："No `careActionShown` record is written here, and none may be." | `CompanionSessionModel.swift:157-168`；`MedicineAssessmentGateTests.swift:163-198` 断言 `careActionShown` 不出现 |
| — | `showingRiskAction(ConfirmedMedicine)` 状态允许未评估即显示关怀动作 | **PR #19 已删除该状态**，替换为 `awaitingMedicineAssessment(MedicineAssessmentGate)` | `CompanionFlowState.swift:132-137`（注释记录删除理由）；`CompanionFlowReducer.swift:86-102` |
| — | 未评估即可出发（`travelling` 从 confirmation 可达） | **PR #19 切断入口**。`awaitingMedicineAssessment` → `travelling` 无 transition | `CompanionFlowReducer.swift:131-136`；`MedicineAssessmentGateTests.swift:114-148` |
| — | `CapabilityCatalog` 存在多个默认值来源 | **PR #19 统一到 `AppEnvironment`**。`CompanionCopy` 不再持有自己的 catalog；所有视图从 session 的 capabilities 读取 | `AppEnvironment.swift:29`、`:35`、`:47`；`CapabilitySourceOfTruthTests.swift:207-248` |
| — | `CareActionPresentationSlot` 占位视图暗示存在卡片位 | **PR #19 已删除该文件** | 文件不再存在于仓库 |

---

## 七、下一阶段风险分级

### P0（阻塞，必须先解决）

1. **G1 缺失正式确认命令。** 两个 `requiresMedicineConfirmation` 场景无法闭环。
   若绕过它在 App 本地伪造确认，就等于把"药物身份已确认"这件事在 Core
   没有记录的情况下写进关怀记录。
2. **G2 无端侧 requester。** 这是"不启动 Server 完成评估"的唯一入口。
   当前 `beginMedicineAssessment()` 在 capability 为 `.unavailable` 时立即报告
   `notWiredUpYet` 并写入 `medicineAssessmentDidNotSucceed`——
   接入 `LocalMedicineAssessmentRequester` 后必须将 capability 改为 `.deviceLocal`
   并实现真实的 assessment 调用路径。
3. **无 assessment success 到 Presentation 的 App 状态。**
   `MedicineAssessmentProgress` 当前只有 `notStarted` 和 `couldNotAssess`，
   没有 success case。`canDepart` 的 exhaustive switch 恒返回 `false`。
   下一阶段需新增 success case，携带 assessment result，使 `canDepart` 在
   评估成功时返回 `true`，并从 `awaitingMedicineAssessment` 打开到
   `travelling` 或 Presentation 展示的 transition。
4. **G4 SlowWalkPresentation 未接入 App。** 展示层代码在另一分支，App 工程无
   `SlowWalkPresentation` 引用，当前 App 内无可展示 assessment 结果的视图。

### P1（影响验收质量）

5. **G3 无真实识别器。** 若本轮仍用 mock 识别，验收结论只能覆盖
   "响应 → 状态 → 展示"，不能覆盖"拍照 → 识别"。必须在 PR 中明示这一边界。
6. **G7 记录语义缺口。** 直接 resolved 的三个场景目前只能借用
   `medicineReadFoundCandidates`，语义不实。
7. **G10 空响应确认态。** 渲染路径必须先支持它，再接真实流程。

### P2（可后续处理，但需记录）

8. **G6 类型重名。** 编译期可区分，评审期易误读。
9. **G8 `elevatedRisk` 无 fixture。** 建议在补 fixture 前不宣称该变体已验收。
10. **G9 `unresolvedMedicine` 归并。** 当前对 demo 六场景无影响
    （`ambiguous` 走的是 `ambiguousMedicine`），但会掩盖真实失败成因。

---

## 八、Fixture 与 Presentation 是否存在不一致

**结论：未发现语义不一致。** 逐项核对如下（全部已从 fixture 与 PR #17 源码确认）：

| 检查项 | 结果 |
| --- | --- |
| 六个 `expectedViewState` 与 Coordinator 判定顺序 | 一致。`resolved && !requiresUserConfirmation → result`，否则 `requiresMedicineConfirmation`；`timeout → failed`。由 `DemoFixtureContractTests.swift:152` 冻结 |
| 六个 `expectedPresentationVariant` 与 `MedicineStateMapper` 输出 | 一致。`classifyResponse` 优先级 `red → knowledgeWarning → healthWarning → elevatedRisk → fallback`（`MedicineStateMapper.swift:170-192`）对六个 fixture 分别落到 `normal` / `healthWarning` / `knowledgeWarning` / `redRisk` / `ambiguous` / `timeout` |
| `expectedRiskLevel` 与 `actionCard.riskLevel` | 五个 JSON 逐一相等；`timeout` 无等级 |
| `expectedActionCardTitle` / `expectedActionCardPrimaryInstruction` | 五个 JSON 与 `ActionCardFactory` 分支逐字相符 |
| `allowsOrdinaryExplanation` | 与 `result && !mustConfirmMedicine && riskLevel != .red` 完全对应：仅 `normal`、`healthWarning` 为 `true` |
| `recommendContactHealthcareProfessional` | `normal` 为 `false`，其余四个 JSON 为 `true`，与卡片是否含 `consult_healthcare_professional` 一致 |
| `recommendContactFamily` | 仅 `redRisk` 为 `true`，与 `notify_family_member` 及 `requiresFamilyAttention` 一致 |
| `PresentationFixtureLoader` 是否复制 fixture | 未复制。它向上搜索 `demo-fixtures/README.md` 锚点后读原文件，并把 `response` 解码为 canonical `MedicineAssessmentResponseDTO`（`PresentationFixtureLoader.swift:14-42`、`:139-145`）。DTO 变更会直接打破 Presentation 测试 |

**两处需要在下一阶段 PR 中明确说明、但不构成不一致的事实**：

1. `knowledgeWarning` 的文件名是 `medicine-source-warning.json`，与 fixtureID 不同名。
   `DemoFixtureContractTests.swift:152` 断言的是
   `expectedPresentationVariant == fixtureID`，不是文件名。
2. `ambiguous` 的 `yellow` 与 `mustConfirmMedicine = true` 是确认卡常量，
   不是评估结论。任何把它读作"黄色风险"的展示或叙述都是错的。

---

## 九、证据来源与验证状态

### 9.1 实际读取的生产源码

`swift-packages/SlowWalkCore/Sources/` 下：
`SlowWalkClientCore/MedicineAssessmentCoordinator.swift`、
`ClientViewStates.swift`、`ClientFailures.swift`、
`AssessmentRequestContracts.swift`、`NetworkMocks.swift`、`OCRContracts.swift`；
`SlowWalkMedicinePipeline/MedicinePipeline.swift`、`ActionCardFactory.swift`；
`SlowWalkMedicineKnowledge/MedicineKnowledgeModels.swift`；
`SlowWalkDomain/RiskAssessment.swift`。

`ios/SlowWalkApp/` 下：`App/AppEnvironment.swift`、
`Features/Capabilities/AppCapability.swift`、
`Features/CareRecords/CareRecordEvent.swift`、`CareRecordStore.swift`、
`Features/Companion/CompanionFlowState.swift`、`CompanionFlowReducer.swift`、
`CompanionSessionModel.swift`、`CompanionCopy.swift`、
`MedicineAssessmentPendingPanel.swift`、`CompanionView.swift`；
`Features/Today/TodayStatusSummary.swift`；
`ios/SlowWalkApp.xcodeproj/project.pbxproj`（只读 package 引用段）。
（原 `CareActionPresentationSlot.swift` 已被 PR #19 删除。）

`demo-fixtures/`：`README.md`、五个 JSON、`medicine-timeout.md`。

PR #17（`git show`，未 checkout）：`Package.swift`、
`Sources/Logic/MedicineStateMapper.swift`、`MedicinePresentationCopy.swift`、
`Sources/Models/MedicineDisplayState.swift`、
`Sources/Views/MedicineAssessmentView.swift`、`MedicineActionCardView.swift`、
`Tests/` 全部 7 个文件。

### 9.2 实际读取的测试

| 文件 | `func test` 计数 | 用途 |
| --- | --- | --- |
| `swift-packages/SlowWalkCore/Tests/SlowWalkClientCoreTests/MedicineAssessmentCoordinatorTests.swift` | 11 | 冻结 Coordinator 六条分支与超时映射 |
| `server/Tests/SlowWalkServerTests/MedicineDemoFixtureGoldenTests.swift` | 2 | 4 个在线 fixture + 1 个 stale-offline fixture 的全量 DTO golden equality |
| `server/Tests/SlowWalkServerTests/DemoFixtureContractTests.swift` | 11 | 冻结 viewState 映射、动作内容与顺序、版本串、候选一致性、证据完整度、知识/缓存联合状态、免责边界 |
| PR #17 `PresentationStateTests.swift` | 13 | 等级不塌缩、歧义不被吞、超时无卡片 |
| PR #17 `FixtureContractTests.swift` | 7 | 六项 expectation 与 canonical 语义对齐 |
| PR #17 `FixtureMappingTests.swift` | 7 | 五个 fixture 经真实 Coordinator 驱动的变体映射 |
| PR #17 `CanonicalContentTests.swift` | 11 | 文案与 canonical 值对齐 |
| PR #17 `AccessibilityValueTests.swift` | 23 | 无障碍朗读值 |
| `ios/SlowWalkAppTests/MedicineAssessmentGateTests.swift` | 13 | **PR #19 新增**：安全门 transition、departure 不可达、careActionShown 不写入、gate copy |
| `ios/SlowWalkAppTests/StaleReadAtAssessmentGateTests.swift` | 6 | **PR #19 新增**：stale read 不覆盖 gate、重复确认不会重复记录 |
| `ios/SlowWalkAppTests/CompanionFlowStateCoverageTests.swift` | 7 | **PR #19 新增**：exhaustive sweep fixture 覆盖率校验 |
| `ios/SlowWalkAppTests/CapabilitySourceOfTruthTests.swift` | 10 | **PR #19 新增**：CapabilityCatalog 单源真理、注入与 wording 一致性 |
| `ios/SlowWalkAppTests/CapabilityStatusTests.swift` | 15 | **PR #19 新增**：CapabilityStatus 展示值与边界 |
| `ios/SlowWalkAppTests/CompanionFlowReducerTests.swift` | 8 | 伴随流程 reducer（已有，行号已随 develop 更新） |
| `ios/SlowWalkAppTests/CompanionSessionModelTests.swift` | 12 | 伴随流程会话模型（已有） |
| `ios/SlowWalkAppTests/CareRecordStoreTests.swift` | 8 | 关怀记录存储（已有） |
| `ios/SlowWalkAppTests/` 合计 | **79**（8 文件） | **PR #19 新增 5 个测试文件（51 个 @Test）** |

上述计数由本次 `grep -c` 得出，属**已由实际命令验证（源码计数）**。

### 9.3 验证状态标记

**已从生产源码确认**：第一、二、三、四、六、八节的全部字段值、分支顺序、
按钮门控条件、Care Record 语义、以及各缺口与断点的存在性。
第二轮审计确认了 PR #19 对 App 状态机、Care Record 写入、CapabilityCatalog
组装的全部修改。

**已由实际命令验证**：环境信息（`pwd` / `git branch --show-current` /
`git rev-parse HEAD` / `git status --short --branch` /
`git rev-list --left-right --count`）、`jq` 对五个 JSON 的字段投影、
`grep` 计数与全仓库 `MedicineAssessmentRequesting` / `import Vision` /
`import SlowWalkPresentation` 命中情况。

**合理推断**：第五节完成定义与第七节风险分级的优先级排序。

**尚未验证**：
- 本次审计**没有运行任何测试、没有执行任何构建**。
  本文件中的任何测试计数都只表示源码中存在多少测试方法，
  **不表示它们通过**。
- PR #17 的 `SlowWalkPresentation` 包在本机是否可编译、其 61 个测试方法
  是否通过——均未在本轨道执行。
- `docs/demo/test-results.md` 记录的 Core 281 项、Server 80 项与
  两条 CI run 属于更早提交的历史记录，本次未复跑，不作为本文件的通过证明。
- 端侧本地评估链路本身尚不存在，因此第五节全部勾选项当前均为未完成。

### 9.4 修改范围自审

本轨道（第二轮）只修改 `docs/demo/DEVICE_LOCAL_MEDICINE_ACCEPTANCE_MATRIX.md` 一个文件
（第一轮新增，第二轮修正 PR #19 相关过时内容）。
未修改 `ios/**`、`swift-packages/**`、`server/**`、`demo-fixtures/**`、
`.github/**`、`.claude/**`；未 checkout、未 merge、未 rebase PR #17 分支；
未触碰 `main` / `develop`；未进入 Phase 0 worktree
（`/Users/xiazihan/Developer/slow-walk-phase0`）。
本文件不含 DTO 定义、风险枚举定义或业务规则实现代码，
不新增任何剂量、诊断、停药或处方表述。
