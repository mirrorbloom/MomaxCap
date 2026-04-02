# Spectacular Rec 样例对齐：已实现项与剩余差距

本文说明本应用（`SlamRecordingSession`）与仓库内 **Spectacular Rec 风格样例**（`docs/recording_2026-03-18_19-14-19/`）及 **Spectacular DATA_FORMAT** 的**对齐程度**：哪些已在代码中实现，哪些**仍无法与样例一致**或需要**更高成本**才能完成。

**关联文档**：[MVP开发优先级.md](MVP开发优先级.md)、[标定真值缺口与可行方案.md](标定真值缺口与可行方案.md)、[Recording参数来源说明.md](Recording参数来源说明.md)、[Spectacular*AI_DATA_FORMAT*中文.md](Spectacular_AI_DATA_FORMAT_中文.md)。

**说明**：`docs/recording_2026-03-18_19-14-19/` 内文件为**冻结参考样例**，应用新录制不落在此目录；见该目录下 [README.md](recording_2026-03-18_19-14-19/README.md)。

---

## 一、已实现、与样例 / 规范高度接近的部分

| 能力                            | 说明                                                                                                                                                                                                                                                         |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **传感器行**                    | `gyroscope`、`accelerometer`、`magnetometer`（μT），根级 `time` + `sensor.type` / `sensor.values`，与规范及样例字段一致。                                                                                                                                    |
| **JSONL 时间序**                | 停止录制后按 `time` 升序写出；同时间戳下次序为陀螺 → 加速度 → 磁力计 → 帧行。                                                                                                                                                                                |
| **主路视频**                    | `data.mov`（H.264），广角 RGB，对应 **`cameraInd`: 0**。                                                                                                                                                                                                     |
| **第二路视频 `data2.mov`**      | **已实现**：见下文「双机位策略」。                                                                                                                                                                                                                           |
| **逐帧深度图 `frames2/*.png`**  | **已实现（深度模式）**：会话目录新增 `frames2/`，按 8 位补零文件名（如 `00000000.png`）导出每帧灰度深度图，与样例目录结构一致。                                                                                                                              |
| **双路 `frames`（与样例形态）** | 每条帧行含 **`frames[0]`**（`colorFormat: rgb`，`cameraInd: 0`）与 **`frames[1]`**（`cameraInd: 1`）；深度模式下 **`colorFormat: gray`**、**`depthScale`: 0.001**、**`aligned`: true**、**`time`: 0**（与样例字段一致）；MultiCam 回退时第二路为 **`rgb`**。 |
| **`calibration.json`**          | **双机位时** `cameras` 为两项：广角内参 + 第二路内参（深度来自 `AVCameraCalibrationData` 时优先；否则与广角或超广角附件一致）；单路时仍为单项。                                                                                                              |
| **元数据**                      | `metadata.json` 含 `dual_capture_mode`（`depth_gray_data2` / `wide_ultrawide_rgb_data2` / `single_wide`）、`spectacular_sample_alignment` 等。                                                                                                               |

### 双机位策略（`ios/Runner/SlamRecordingSession.swift`）

1. **优先（与样例「RGB + 深度灰度」一致）**  
   **`AVCaptureSession`** + **`AVCaptureVideoDataOutput`**（广角）+ **`AVCaptureDepthDataOutput`**（需机身支持 **带深度的 `activeFormat`**，如带 LiDAR 的 Pro 机型），**`AVCaptureDataOutputSynchronizer`** 同步 RGB 与深度。  
   深度 **`AVDepthData`** 转为 **8bit 灰度 BGRA** 后写入 **`data2.mov`**，并导出 **`frames2/*.png`**；JSONL 第二路为 **gray + `depthScale`**。

2. **回退（无双路深度时）**  
   **`AVCaptureMultiCamSession`**：**广角 + 超广角** 双路 RGB，时间戳就近配对（约 50ms 内），写入 **`data2.mov`**；JSONL 第二路 **`colorFormat: rgb`**（与样例「第二路为 gray」在语义上为回退模式，`metadata.dual_capture_mode` 会标明）。

3. **再回退**  
   仅单广角，无 `data2.mov`。

---

## 二、与样例仍不一致或存在差异的项

### 1. `imuTemperature`（JSONL，单位 K）

- **本应用**：不写入；见 `metadata.imu_temperature_status`。
- **原因**：iOS 无对应公开 API。

### 2. `imuToCamera` 真值

- **本应用**：主路 `imuToCamera` 使用拍摄期坐标系约定矩阵；深度模式第二路优先融合 `AVCameraCalibrationData.extrinsicMatrix` 组合估计；无深度时复制主路估计。
- **原因**：iOS 无工厂外参 API；当前实现对齐的是“拍摄可得效果”，仍不是手眼标定后的外参真值。

### 3. 畸变模型与系数

- **本应用**：`model: pinhole`，无 **Kannala-Brandt** 等畸变系数行；深度路径可使用 `AVCameraCalibrationData` 的针孔内参主项。

### 4. 深度灰度视频与「真深度」

- **第二路 `data2.mov`** 为 **可视化归一化灰度**（便于 H.264 与回放），**不是**原始 Float 深度文件；下游若需原始深度需另行扩展（例如侧车写 `.depth` / 二进制）。

### 5. MultiCam 与样例第二路语义

- 回退模式下第二路为 **超广角 RGB**，**不是**样例中的 **gray+depthScale**；以 **`metadata.dual_capture_mode`** 区分。

---

## 三、仍需复杂能力才能进一步对齐的方向（摘要）

| 方向                               | 说明                                   |
| ---------------------------------- | -------------------------------------- |
| **原始深度侧车 / 逐帧 Float 深度** | 需自定义文件格式或工具链，而非仅 MOV。 |
| **逐帧完整畸变模型**               | 深度/多摄标定流或离线标定。            |
| **`imuToCamera` 真值**             | 手眼标定或联合优化。                   |

---

## 四、小结

- 应用已支持 **`data.mov` + `data2.mov`**、**双 `frames`**、**深度优先时与样例一致的 gray / depthScale / aligned**；无深度时 **MultiCam 双 RGB** 回退。
- 剩余差异主要在 **IMU 温度**、**外参真值**、**畸变**、**原始深度文件**。

---

## 五、历史：实现前曾列出的采集层要点（归档）

以下为设计双机位时曾参考的 iOS 要点，现已大部分落地于 `SlamRecordingSession`；保留作架构备忘。

1. **格式层**：会话目录含 `data.jsonl`、`data.mov`、`data2.mov`、`calibration.json`、`metadata.json`。
2. **采集层**：MultiCam 或 视频+深度同步器；双 `AVAssetWriter`；内参附件与曝光时间。
3. **风险**：发热、带宽、两路 PTS 配对。

修订采集逻辑时，请同步更新本文与 [Recording参数来源说明.md](Recording参数来源说明.md)。
