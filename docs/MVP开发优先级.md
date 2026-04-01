# SLAM 数据采集：开发优先级与 MVP 说明

本文与 `Flutter-iOS-SLAM数据采集应用开发指南.md` 配套，结合仓库内 **Spectacular Rec 风格样例**（`docs/recording_2026-03-18_19-14-19/`）约定可测试的 MVP 范围与实现顺序。

## 一、为什么建议按这个顺序做

1. **数据格式是“合同”**：先保证 `data.jsonl` + `data.mov` + `calibration.json` 能被后处理工具读入，再优化质量，避免后期大改流水线。
2. **相机 + IMU 是主路径**：没有稳定视频与时间对齐的 IMU，其它传感器（磁力计、多摄）价值有限。
3. **真机-only**：传感器与相机必须在 iPhone 上验证；模拟器只能做 UI 与假数据联调。

## 二、参考样例与 MVP 的差异

| 项目 | `docs/recording_2026-03-18_19-14-19/` 样例 | **MVP 目标（首版可测）** |
|------|---------------------------------------------|-------------------------|
| 视频 | `data.mov`（+ 样例可有 `data2`） | ✅ **`data.mov`**；支持时 **`data2.mov`**（深度灰度或超广角 RGB，见 P2） |
| JSONL | 含陀螺仪、加速度计、**磁力计**、**双相机帧**（含 depth 元数据） | ✅ **加速度计 + 陀螺仪 + 磁力计** + **`frames`（单路或双路，含 depthScale/gray 或双 RGB）** |
| `calibration.json` | 双相机 `pinhole` + `imuToCamera` | ✅ **一或两项** `cameras`；内参优先附件；**`imuToCamera`** 仍为占位 |
| `metadata.json` | `device_model`、`platform` | ✅ 建议 MVP 就写入，便于区分机型 |

MVP 不要求与样例逐字段一致（例如样例中的双机位、磁力计、每帧内嵌标定），但应满足主文档引用的 **Spectacular DATA_FORMAT** 中 **单目 VIO 必需字段**；后续迭代再对齐样例的完整字段。

## 三、推荐实现顺序（从先做 → 后做）

### P0 — 可跑通的“最小闭环”（建议最先完成）

**目标**：真机一次录制结束后，沙盒（或应用文档目录）里出现可拷贝的：

- `data.mov`（仅视频，**不采集麦克风**）
- `data.jsonl`（至少含 `accelerometer`、`gyroscope` 与单目 `frames` 行，时间轴一致）
- `calibration.json`（单相机、`pinhole` 或文档约定模型 + 合理占位内参）
- `metadata.json`（可选但强烈建议）

**技术要点**：

- Swift：`AVCaptureSession` + `AVAssetWriter` 写 MOV；`CMMotionManager` 采 IMU；统一时间基准（如 `CACurrentMediaTime`）并在 JSONL 中**归一化到从 0 起的秒**（便于与指南示例一致）。
- Flutter：`startRecording` / `stopRecording` 传会话目录；UI 展示状态与导出路径。

**验收**：把生成的目录拷到 PC，用脚本或下游工具能做**粗跑**（不要求重建效果多好）。

### P1 — 质量与可复现

**目标摘要**：录制参数稳定、JSONL 可复现解析、与 Spectacular 单位一致；可选补充 IMU 温度（若系统可提供）。

**实现位置**：iOS 原生 `ios/Runner/SlamRecordingSession.swift`（对焦/曝光、缓冲与排序、传感器行）；说明见 `Flutter-iOS-SLAM数据采集应用开发指南.md` §4.1、`Spectacular_AI_DATA_FORMAT_中文.md`。

**子任务（可勾选）**：

- [x] **对焦 / 曝光锁定**：会话开始后约 **0.2 s** 再链式调用 `setFocusModeLocked` → `setExposureModeCustom` →（若支持）白平衡锁定，见指南 §4.1；实现见 `SlamRecordingSession.applyFocusExposureLockIfPossible()`。
- [x] **JSONL 按 `time` 排序**：缓冲各行，**停止录制后**按 `time` 升序写入；同一时间戳下次序为陀螺 → 加速度 → `frames`。
- [x] **缓冲刷盘**：录制中仅内存追加，结束时一次性写入 `data.jsonl`。
- [x] **`imuTemperature`**：iOS Core Motion **无**公开芯片温度 API；`metadata.json` 中 `imu_temperature_status` 为 `unavailable_no_public_api_ios`，**不写入**伪造 JSONL 行。
- [x] **单位与语义核对**：代码注释与本文档写明陀螺 **rad/s**、加速度 **m/s²**（含重力）；`CMSampleBuffer` 连接在支持时开启内参矩阵投递，供后续迭代。

**验收建议**：脚本检查 `data.jsonl` 中 `time` 整体有序；人工或抽帧检查曝光/对焦稳定性；对照 `Spectacular_AI_DATA_FORMAT_中文.md` 核对字段与单位。

### P2 — 与样例进一步对齐（按需）

- [x] **磁力计行**：`sensor.type: magnetometer`，单位 μT；与 IMU 共用时间轴（见 `SlamRecordingSession`）。
- [x] **帧行贴近样例（单目）**：`frames[0]` 含 `colorFormat: rgb`、`calibration`（由内参矩阵附件解析）、`exposureTimeSeconds`；`calibration.json` 单路优先使用附件内参。
- [x] **多相机 / 深度 / `data2`**：优先 **同步器 + 深度输出**（LiDAR 等）→ `data2.mov` 灰度 + JSONL **gray/depthScale**；否则 **MultiCam 广角+超广角** 双 RGB；见 [`Spectacular样例对齐差距说明.md`](Spectacular样例对齐差距说明.md)。

### P3 — 同步与工程化

- 压缩上传、`dio` 队列、失败重试（`pubspec` 已预留依赖）。
- 后台上传、省电策略等。

## 四、MVP 定义（给你测试用的版本）

**MVP = P0 完成 + 明确“非目标”边界。**

| 包含 | 不包含（本阶段不做） |
|------|----------------------|
| `data.mov` + 可选 `data2.mov`（无麦克风） | 原始 Float 深度侧车文件、非 H.264 深度裸流 |
| `data.jsonl`：IMU + 单路或双路 `frames` | 与 Spectacular 官方采集器逐字段完全一致（受设备与回退模式影响） |
| `calibration.json`：一或两项；内参优先附件 | 畸变系数真值、外参真值、精密现场标定 |
| 基础时间对齐 | 亚毫秒级硬件同步（后续优化） |
| `metadata.json`（推荐） | 云端账号体系（可后接） |

**测试方式建议**：

1. iPhone 上录制 10～30 秒，步行与小转动。
2. 检查文件是否齐全、JSONL 能否用 `jq`/Python 解析、视频能否播放。
3. 再交给你的 NeRF/3DGS/Spectacular 工具链试跑（允许初版轨迹一般）。

## 五、不建议作为第一步的工作

- 先做复杂 UI、上传、账号，而**没有**落地文件格式（容易返工）。
- 在模拟器上验证 SLAM 数据（IMU 不可用，见主文档）。

## 六、权限与麦克风

- **MVP 不采集麦克风**：不写音频轨；`Info.plist` 中不声明麦克风用途（避免多余敏感权限与审核说明）。
- 若未来 `AVAssetWriter` 因配置误开音频，需在编码层显式**仅视频**。

---

**总结**：建议**从 P0 闭环开始**——先让 `data.mov` + `data.jsonl` + `calibration.json`（单目占位）在真机稳定产出，再迭代 P1 质量与 P2 与样例字段对齐。这样你能尽快拿到可测 MVP，再按需加深。
