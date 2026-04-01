# Recording 参数来源说明（当前 P0 + P1 + 样例对齐项）

本文说明：**在一次会话目录里，哪些字段属于「拍摄或系统 API 直接得到」**，哪些属于**轻量封装/时间对齐**，哪些属于**占位或启发式**（需要后续标定或更复杂管线才能逼近真值）。

- **范围**：与 [`MVP开发优先级.md`](MVP开发优先级.md) 中 **P0 / P1 / P2（双机位与 `data2`）** 一致：磁力计、广角 RGB、**可选 `data2.mov`（深度灰度或超广角 RGB）**、双路 `frames`、附件内参、`calibration.json` 单路或双路；**不包含**原始 Float 深度侧车文件、完整畸变真值等（见 [`Spectacular样例对齐差距说明.md`](Spectacular样例对齐差距说明.md)）。
- **应用层**：[`lib/app/spatial_data_recorder_app.dart`](../lib/app/spatial_data_recorder_app.dart) 仅负责 UI 与调用原生录制；**不生成** recording 参数。实际写入由 iOS **`SlamRecordingSession`**（`ios/Runner/SlamRecordingSession.swift`）完成。

下文「直接」指：**无需离线 SLAM、BA、深度估计、张正友标定等算法**；可能仍包含简单的减法归一化、顺序计数或 JSON 序列化。

**对照表**（设备/API 能力与 recording 落盘项一览）：[`Recording采集与落盘对照表.md`](Recording采集与落盘对照表.md)。

---

## 一、可直接视为「采集链路产出」的

| 产物/字段 | 说明 |
|-----------|------|
| **`data.mov` 视频内容** | 广角主路：来自 `AVCaptureVideoDataOutput` 的实时帧，经 `AVAssetWriter` 编码为 H.264；无麦克风轨。 |
| **`data2.mov`（若存在）** | **深度模式**：LiDAR/深度 `AVDepthData` 转 **8bit 灰度 BGRA** 再 H.264，与样例「第二路 gray」语义一致（灰度为**可视化归一化**，非原始 Float 深度文件）。**MultiCam 回退**：超广角 RGB，第二路 `colorFormat` 为 `rgb`。 |
| **视频宽高** | `data.mov` 由首帧广角 `CVPixelBuffer` 决定；`data2.mov` 由深度图或超广角首帧决定。 |
| **JSONL：`sensor.type: gyroscope` 的 `values`** | `CMDeviceMotion.rotationRate`（**rad/s**），Core Motion 在回调中直接给出。 |
| **JSONL：`sensor.type: accelerometer` 的 `values`** | 由 `gravity` 与 `userAcceleration` 分量相加得到的三轴加速度（**m/s²**，含重力，与设备运动参考系一致）；仍为运行时 API 输出，**非**自建滤波器或优化器结果。 |
| **JSONL：`sensor.type: magnetometer` 的 `values`** | `CMMagnetometerData.magneticField`（**μT**，与 Spectacular DATA_FORMAT 一致）；与陀螺/加速度**同一相对时间轴**；采样率约 **60 Hz**（与设备运动回调独立）。 |
| **JSONL：帧行的 `time`** | 由 `CMSampleBuffer` 的 `presentationTimeStamp` 相对**首帧视频 PTS** 换算为秒；来源是采集管线时间戳，仅做相对首帧的归一化。 |
| **JSONL：帧行的 `number`** | 按收到并写入视频的帧顺序递增，与 `data.mov` 中帧顺序一致。 |
| **JSONL：`frames[0]`** | **`cameraInd`: 0**；**`colorFormat`: `rgb`**；**`exposureTimeSeconds`**；**`calibration`**（内参矩阵附件，若可用）。 |
| **JSONL：`frames[1]`（若双机位）** | **`cameraInd`: 1**；深度模式：**`colorFormat`: `gray`**、**`depthScale`**（当前固定 **0.001**，与样例字段一致）、**`aligned`: true**、**`time`: 0**、**`calibration`**（优先深度 `AVCameraCalibrationData` 内参）。MultiCam 回退：**`colorFormat`: `rgb`**、**`exposureTimeSeconds`**、超广角内参。 |
| **`metadata.json`：`device_model` / `platform`** | 机型代号与固定 `"ios"`。 |
| **`metadata.json`：`imu_temperature_status`** | **`unavailable_no_public_api_ios`**：不写入伪造 `imuTemperature` 行。 |
| **`metadata.json`：`intrinsics_source`** | **`cmsamplebuffer_attachment`** 或 **`heuristic_fallback`**，表示 `calibration.json` 主来源。 |
| **`metadata.json`：`p1` / `spectacular_sample_alignment` / `dual_capture_mode`** | P1 行为、样例对齐开关、**`depth_gray_data2` / `wide_ultrawide_rgb_data2` / `single_wide`**。 |

---

## 二、需代码做「对齐/封装」、但不属于复杂算法的

| 字段/行为 | 说明 |
|-----------|------|
| **IMU / 磁力计行的 `time`** | 使用 `CACurrentMediaTime()` 减去与视频首帧对齐的 `timeOriginMedia`，使传感器与录制段落在同一相对时间轴上。 |
| **JSONL 落盘顺序** | 会话结束后按根级 **`time` 升序**写出；同一时间戳下稳定次序为：**陀螺仪 → 加速度计 → 磁力计 → 视频 `frames` 行**。 |
| **缓冲刷盘** | 录制中内存缓冲，结束时一次写入 `data.jsonl`。 |
| **对焦 / 曝光 / 白平衡锁定** | 见 [`Flutter-iOS-SLAM数据采集应用开发指南.md`](Flutter-iOS-SLAM数据采集应用开发指南.md) §4.1。 |
| **`calibration.json`** | **单路**：同上。**双路**：`cameras` 两项，分辨率与焦距主点对应广角与第二路（深度或超广角）；`imuToCamera` 仍为占位。 |

---

## 三、部分真值、部分仍属占位

| 字段 | 说明 |
|------|------|
| **`calibration.json`：焦距 / 主点** | **优先**为内参矩阵附件解析结果（与当前编码分辨率一致时可靠）；**否则**为经验比例与中心点。 |
| **`calibration.json`：畸变** | **未**写入与 `AVCameraCalibrationData` 或离线标定一致的畸变系数/查找表；`model` 仍为 **`pinhole`**。 |
| **`calibration.json`：`imuToCamera`** | **4×4 单位矩阵** 占位，非手眼标定或出厂外参。 |

若需完整几何真值与双路标定，见 [`标定真值缺口与可行方案.md`](标定真值缺口与可行方案.md)、[`Spectacular样例对齐差距说明.md`](Spectacular样例对齐差距说明.md)。

---

## 四、本应用当前**不会**直接产出项

- **原始 Float 深度侧车**（非 `data2.mov` 灰度视频）：未写入独立深度文件。
- **`imuTemperature` JSONL 行**：无公开 iOS API。
- **GNSS / 真值** 等：未接入。

---

## 五、小结

| 类别 | 内容 |
|------|------|
| **偏「直接」** | 视频流（一或两路）、陀螺/加速度/磁力、帧时间戳与内参附件、机型 metadata。 |
| **偏「工程对齐」** | 相对时间轴、JSONL 排序与缓冲、对焦曝光锁定、深度同步器或 MultiCam PTS 配对。 |
| **偏「占位或未接入」** | `imuToCamera`、畸变真值、原始深度文件。 |

修订录制管线时，建议同步更新本文、[`MVP开发优先级.md`](MVP开发优先级.md) 与 [`Spectacular样例对齐差距说明.md`](Spectacular样例对齐差距说明.md)。
