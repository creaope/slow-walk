# SlowWalk A5 Synthetic Medicine Assets

此目录是 SlowWalk A5 的固定离线药品演示资产包。全部图片均由仓库中的确定性
Python 标准库脚本生成，不包含网络图片、真实药盒、商标、厂商包装、处方标签、
患者信息、处方号、地址、电话或二维码。

这些图片不是药品说明书，也不用于临床用途。图片中的 `500 mg` 只是 OCR 可见文字
证据，不是剂量、频次、适用人群或风险建议。原图和 Manifest 都不得被当作真实医学
来源。

## Assets

| ID | 用途 | 可读 | 歧义 | 正式录屏 |
| --- | --- | --- | --- | --- |
| `acetaminophen-clean-v1` | 主录屏固定合成标签 | 是 | 否 | **批准** |
| `acetaminophen-angle-v1` | 固定角度变形测试 | 是 | 否 | 不批准 |
| `acetaminophen-lowlight-v1` | 固定低亮度测试 | 是 | 否 | 不批准 |
| `cold-relief-ambiguous-v1` | 多成分与局部遮挡降级测试 | 是 | 是 | 不批准 |

正式录屏只能使用 `approvedForRecording: true` 的 clean 图片。其余图片只用于离线测试
不确定、歧义和降级路径。

Acetaminophen 图片的 `expectedCanonicalMedicineID` 是现有 bundled demo catalog 中的
`demo-acetaminophen`。歧义图片包含多个成分证据，字段为 `null`；Manifest 不创建、
修改或替代 catalog 身份。

## Responsibility Boundaries

- Apple Vision 只负责在设备上从像素提取候选文字。
- 远程 Vision（若由其他独立功能提供）只负责受限的图像转文字或结构化识别；本资产包
  不接入、配置或模拟任何远程 API。
- canonical pipeline 负责用正式 catalog 解析候选文字并产生 canonical 身份与后续
  评估。Manifest 中的预期 ID 只是离线测试 oracle，不得作为生产 pipeline 输入。
- Vision 输出、Manifest 和原始图片都不是可信医学来源，也不能单独生成用药或风险建议。

## Generate And Validate

在仓库根目录运行：

```bash
python3 scripts/demo-assets/generate_medicine_demo_assets.py --check
python3 scripts/demo-assets/validate_medicine_demo_assets.py
```

需要有意更新资产时，先运行不带 `--check` 的生成命令，再运行以上两项校验。`--check`
只在内存中重建图片和 Manifest 并做字节比较，不覆盖现有文件。图片使用固定 RGB 像素、
固定字形和确定性 PNG 编码，不需要 Pillow、ImageMagick、系统字体或任何第三方包。
