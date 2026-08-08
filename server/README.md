# SlowWalk Server

Swift 6 + Hummingbird 2 的最小 API 服务，业务风险判断复用本地
`../swift-packages/SlowWalkCore` 中的 `MedicationRiskEngine`。

## 运行

以下命令仅供具备受支持 Swift 工具链的 Linux/macOS 环境使用；当前 Windows
工作区不执行它们。仓库的真实构建与测试结果以 `Swift Server` GitHub Actions
工作流为准。

```bash
swift run SlowWalkServer
```

默认监听 `127.0.0.1:8080`。测试：

```bash
swift test
```

## API

- `GET /health`
  - `200 application/json`
  - `{"status":"ok","service":"slow-walk-server","apiVersion":"v1"}`
- `POST /api/v1/medicine/search`
  - 只检索白名单 mock/demo knowledge source
  - 返回来源、冲突、`knowledgeCacheStatus` 与
    `KnowledgeGovernanceVerdict`
- `POST /api/v1/medicine/resolve`
  - 接收模拟 OCR 的 `MedicineRecognitionInput`
  - 只解析服务端 SwiftPM resource 中的演示目录
  - 歧义、未找到和证据不足使用稳定的 `APIErrorDTO` 错误码
- `POST /api/v1/medicine/recognize`
  - 接收一个 Base64 编码的 `image/jpeg`、`image/png` 或 `image/webp`
  - JSON 请求体上限为 6 MiB，解码后的单图上限为 4 MiB
  - 智谱只提取受限包装证据；canonical identity 仍由现有受控目录和
    `MedicineResolver` 决定，不执行风险判断
  - 无凭据、429、Provider 5xx、网络失败和超时返回稳定的
    `provider_unavailable` 结果，并允许客户端使用本地 fallback
  - 上游响应正文、图片、凭据和 Authorization 不进入响应或日志
  - `requestID` 只用于关联请求和日志；当前端点不提供幂等缓存或重放语义，
    相同 ID 的两次提交会分别执行识别
- `POST /api/v1/medicine/assess`
  - 完成归一化、候选解析、当前档案/历史风险重评估和 `ActionCard` 生成
  - canonical request 使用严格 `UserHealthProfileDTO`；Server 显式映射 Domain
  - 无法确认药品时仍返回保守行动卡，不返回剂量或频次
  - 响应分别包含 `resolutionCacheStatus` 与 `knowledgeCacheStatus`
  - 缓存命中不代表医学安全，assessment 每次重新计算
- `POST /api/v1/location/assess`
  - 处理位置数据质量、距离趋势、geofence 与演示行为风险
  - 使用共享 `RiskLevel`，位置 reason/action 保持独立
  - 数据质量 orange 不参与 family-attention red 计数

旧 `POST /api/v1/risk/assess` 默认路由已关闭，raw request/response DTO 已移除。
客户端不能提交完整 `Medicine`、ingredient 或 `SourceReference` 绕过
`MedicinePipeline`、`SourcePolicy` 和 health preflight。

所有 POST route 只接受 `Content-Type: application/json`；日期由
`SlowWalkJSONCoding` 统一编码为 ISO 8601。错误统一返回 `APIErrorDTO`，
`code` 类型为 `APIErrorCode`，Server 只输出 canonical
`UPPER_SNAKE_CASE`。`apiVersion`、`/api/v1` route prefix 与 path/body version
映射集中在 `SlowWalkAPI`。

演示目录明确标注 `DEMO DATA — NOT FOR CLINICAL USE`，所有剂量字段均为空。
当前所有 knowledge source 也都是 mock/demo 数据，尚未验证真实药品来源。
完整设计和限制见 `docs/MEDICINE_PIPELINE.md`。

Hummingbird 为每个传输请求写入 `hb.request.id` 日志元数据；API DTO
中的 UUID 请求 ID 会作为 `slowwalk.api_request_id` 进入结构化日志。
日志不会记录药品、健康档案或请求正文。

未配置 `ZHIPU_API_KEY` 时服务仍可启动，药品识别端点返回可恢复的 Provider
不可用结果。只有运行环境成功加载凭据和合法 Provider 配置时才创建 live
Vision client；其他 API 不依赖该凭据。
