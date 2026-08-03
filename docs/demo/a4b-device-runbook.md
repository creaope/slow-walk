# A4b 真机与 RC 录屏 Runbook

## 1. 前置设备条件

iOS 17+ 且带后置相机的 iPhone；沿用现有签名，不改 team、bundle ID 或 profile。保证电量与存储充足，并在相册预置一张经负责人批准的合成演示标签图。
仓库当前没有批准图片。图片须清晰、高对比、正向，不含患者、处方、姓名或真实健康信息；标签文字由负责人从 bundled synthetic demo catalog 中选定并审批，审批前不得录制成功结论。

## 2. 推荐系统设置

使用竖屏、专注模式、合适亮度和较长自动锁定；录屏优先 PhotosPicker，Camera 只做真机验收。进入 Capture 前和返回 result 后，分别确认 `DEMO DATA — NOT FOR CLINICAL USE` 标识可见。

## 3. 首次相机权限

重装 App 或重置相机权限；启动后切到“陪伴”，点“开始陪伴”。Capture 出现时不得提前弹权限框；点“使用相机”后只请求一次，快速连点不重复；允许后等待预览，再点一次白色快门。

## 4. Camera 真机验收

分别验收首次允许和已允许：预览稳定、快门一次、processing 无输入按钮、每张图只进入一次 OCR/canonical assessment。另开 Capture 后取消或关闭，不得假成功、重复结果或崩溃；无相机/source 时显示中文说明并保留相册。

## 5. PhotosPicker 稳定录屏

启动后切到“陪伴”并点“开始陪伴”；不点 Camera，直接“从相册选择”固定批准图片，确认不触发相机权限。等待读取/处理进入 canonical confirmation/result；result 实际显示后再展示“继续陪伴”或“完成用药检查”。

## 6. 预期页面与状态

`MedicineCapture -> 读取照片 -> 处理药品图片 -> canonical confirmation/result`。accepted 后 Capture 自动关闭；result 未实际展示前无完成资格、无 `careActionShown`，实际展示后同一 request 只确认一次。

## 7. 取消与重试

在读取、拍摄或 accepted 前 processing 中取消/关闭，应停止未完成 Runner 且不留 spinner；旧回调不能关闭后来重开的 Capture。“重拍”须创建新 processing lifecycle；accepted 后关闭 Capture 不代表取消 assessment。

## 8. denied / restricted / unavailable

denied 显示权限已关闭，可用时给“前往设置”，并保留相册；restricted 不给重新请求，说明设备不可用并保留相册；unavailable 不调用 Camera source、不崩溃并保留相册。从设置返回不自动开 Camera，由用户再次点击。

## 9. 前后台切换

Camera 未拍摄或 PhotosPicker 未选图时切后台，不产生取消/成功，回前台可重试且不自动开 Camera；processing 中保持同一 processing/OCR；accepted 后 assessment 继续，result 回前台可恢复展示。

## 10. 重置权限或演示状态

删除 App 后重装可清除授权与内存 session；也可在“设置 -> 隐私与安全性 -> 相机”切换 SlowWalk 权限。denied 后返回无需杀 App；restricted 需受管理或家长控制设备，不能用重复权限框代替。

## 11. 已知限制

仓库没有批准图片，录制前必须人工准备并审批。模拟器只能验收 unavailable 与 PhotosPicker；Camera、系统授权和中断需真机。assessment 使用 bundled synthetic demo data，不代表真实数据库或临床能力。

## 12. 录屏表述边界

不得表达为真实临床建议、诊断、剂量、疗程、停药或处方意见；只能说明这是由真实 Capture/OCR 进入既有 canonical demo assessment 的 RC 演示，全部数据为 `DEMO DATA — NOT FOR CLINICAL USE`。
