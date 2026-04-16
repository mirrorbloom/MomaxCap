# Spectacular Rec 对齐：差异说明与修复清单（以样例为准）

## 1. 目标与对齐基线

目标：让本项目（`spatial_data_recorder`）录制输出在**文件结构、编码参数、时间行为、标定/内参写法**上尽可能与 **Spectacular Rec** 产物一致，便于下游工具/脚本“直接替换输入”。

本仓库内置一份 Spectacular Rec 风格参考样例，可作为**对齐基线**：

- `docs/recording_2026-03-18_19-14-19/`

后文以该样例（记为 `spec`）与本应用录制输出（记为 `ours`）进行逐项对齐说明。

---

## 2. Spec（样例）关键参数摘要（建议作为验收标准）

### 2.1 文件结构（会话目录）

- `data.mov`：H.264 视频，**无音轨**
- `data.jsonl`：IMU + 帧元数据（JSON Lines）
- `calibration.json`：相机标定（两路时 `cameras` 为 2 项）
- `metadata.json`：最小元数据（样例只有 `device_model` / `platform`）
- `frames2/*.png`：深度逐帧 PNG（16-bit gray）

### 2.2 深度帧序列 `frames2/*.png`

样例特征（可以用 PNG 头部直接验证）：

- Color type：0（grayscale）
- Bit depth：16
- 分辨率：**256×192**
- 像素语义：以 **mm** 存储（与 `data.jsonl` 的 `depthScale = 0.001` 对应，`depthMeters = pngValue * 0.001`）

### 2.3 `data.mov`（容器/编码）

样例特征：

- 仅 1 条 H.264 视频流（**无 44.1kHz PCM 音轨**）
- `nominal r_frame_rate`：约 **30/1**
- `avg_frame_rate`：约 30fps，帧间隔稳定在 ~33.3ms

### 2.4 `metadata.json`（schema）

样例 `metadata.json` 极简：

```json
{"device_model":"iPhone13,4","platform":"ios"}
```

即：**不包含** `audio_*`、`capture_mode`、`depth_mode_required` 等扩展字段。

### 2.5 `calibration.json`（两路时的关键点）

样例特征（重点）：

- `camera0` / `camera1` 的内参（`focalLengthX/Y`、`principalPointX/Y`）在样例里一致
- `camera1.imuToCamera` 相对 `camera0` 多了一个平移占位：`x = 0.1`（矩阵的 `[0][3]`）

### 2.6 `data.jsonl`（帧行 / 内参写法 / 排序行为）

样例特征（重点）：

- `frames[1]`（深度灰度）：
  - `colorFormat: "gray"`
  - `depthScale: 0.001`
  - `aligned: true`
  - **逐帧内参写法：与 `frames[0]` 完全一致**
- **行顺序不是严格按 `time` 全局递增**（这是 Spectacular 样例的“原始流行为”，不是 schema 差异）

---

## 3. Ours vs Spec：已知差异与含义（来自对比结论）

### 3.1 深度 PNG 分辨率不一致（关键）

- `spec/frames2`：256×192
- `ours/frames2`：320×240

这通常不是“时长差异”，而是**深度流格式（activeDepthDataFormat）未对齐**导致的。

### 3.2 `data.mov` 多出音轨（关键）

- `spec/data.mov`：仅 H.264 视频
- `ours/data.mov`：额外包含 44.1kHz 单声道 PCM 音轨

对齐目标是 **移除音轨**，保持与样例一致。

### 3.3 `data.mov` 标称帧率 / 帧间隔抖动（关键）

现象：

- `spec`：`r_frame_rate = 30/1`，帧间隔 ~33.336ms 稳定
- `ours`：容器层 `r_frame_rate = 60/1`，但平均仍接近 30fps，且出现 16.67ms / 50ms 的短长帧

这通常意味着**实际采集或 activeFormat 锁到了 60fps**，但写入端丢帧导致平均帧率接近 30。

### 3.4 `metadata.json` schema 不一致（关键）

`ours` 写入了 `audio_*`、`capture_mode`、`depth_mode_required` 等字段，`spec` 没有。

如果目标是“完全复刻样例”，应将 `metadata.json` 收敛到样例 schema（或把扩展字段写到另一个文件）。

### 3.5 两路内参与 aligned 行为不一致（关键）

现象：

- `spec`：逐帧 `camera1` 内参与 `camera0` 一致
- `ours`：虽写了 `aligned:true`，但 `camera1` 内参仍有稳定偏差（cx/cy 偏移、fx/fy 浮动）

如果深度已经对齐到 RGB，**`aligned:true` 对应的内参应与 RGB 主路一致**，否则下游会认为是“未对齐”或“仍是另一相机模型”。

### 3.6 `calibration.json` 数值差异（较关键）

常见表现：

- 焦距/主点数值偏差（可能来自分辨率/取参来源不同）
- `camera1.imuToCamera` 平移占位缺失（样例是 `x=0.1`，ours 变成 0.0）

### 3.7 传感器采样率差异（较关键）

常见表现：

- gyro / accel：两边都 ~100 Hz（OK）
- magnetometer：`spec` ~100 Hz，`ours` ~50–60 Hz

需要提高磁力计 update interval（设备层仍可能被系统限制）。

### 3.8 JSONL 写出顺序差异（可选对齐）

- `spec`：不是严格按 `time` 全局递增
- `ours`：严格单调递增

这不是 schema 变化，但如果目标是“字节级复刻样例”，需要决定是否模拟样例的“原始顺序”。

---

## 4. 修复清单（按优先级，映射到本项目代码模块）

### P0（必须先修，直接导致格式不对齐）

1. **深度 `frames2/*.png` 分辨率固定到 256×192**
   - 模块：`ios/Runner/SlamRecordingSession.swift`
   - 重点：优先选择 `activeDepthDataFormat` 中 **256×192** 的 depth format

2. **去掉 `data.mov` 的音轨**
   - 模块：`ios/Runner/RecorderFlutterBridge.swift` / Flutter 启动参数
   - 重点：录制时不要创建/写入 `AVAssetWriterInput(mediaType: .audio)`

3. **确保视频采集锁到 30fps，避免 60fps 丢帧**
   - 模块：`ios/Runner/SlamRecordingSession.swift`
   - 重点：选 `activeFormat` 时优先选支持 30fps 的 format，并锁 `activeVideoMin/MaxFrameDuration`

4. **`aligned:true` 时第二路（深度）内参写法与第一路完全一致**
   - 模块：`ios/Runner/SlamRecordingSession.swift`（写 JSONL 帧行 / 写 calibration.json）

### P1（强烈建议，影响下游一致性）

5. **磁力计采样率提升到 ~100 Hz**
   - 模块：`ios/Runner/SlamRecordingSession.swift`
   - 重点：`magnetometerUpdateInterval = 1/100`

6. **`calibration.json` 的 `camera1.imuToCamera` 平移占位与样例一致（x=0.1）**
   - 模块：`ios/Runner/SlamRecordingSession.swift`

7. **`metadata.json` 收敛到样例 schema（仅保留最小字段集）**
   - 模块：`ios/Runner/SlamRecordingSession.swift`

### P2（可选：追求“样例行为复刻”）

8. **JSONL 行写出顺序不再按 time 全局排序**
   - 模块：`ios/Runner/SlamRecordingSession.swift`
   - 说明：写出顺序按“回调到达顺序”保留，更接近样例的 raw stream 行为

---

## 5. 验收/自检建议（不依赖业务代码）

1. **检查 frames2 PNG 规格**
   - 任取 `frames2/00000000.png`，校验 IHDR：`256x192`、`bitDepth=16`、`colorType=0`

2. **检查 data.mov 是否无音轨**
   - 用 `ffprobe -hide_banner -show_streams data.mov`（或你们内部脚本）
   - 期望仅有 1 条 video stream，且 `codec_name=h264`

3. **检查帧率与抖动**
   - `r_frame_rate` 期望 30/1
   - `avg_frame_rate` 约 30fps
   - 相邻帧 PTS 间隔应集中在 ~33.3ms，不应出现大量 16.7ms / 50ms

4. **检查 JSONL 两路内参一致**
   - 对所有帧行：`frames[0].calibration` 与 `frames[1].calibration`（当 `aligned:true` 且 `gray`）应完全一致

5. **检查 metadata.json 字段集合**
   - 期望只有样例的最小字段（或至少不包含 `audio_*` / `capture_mode` 等扩展字段）

---

## 6. 备注：关于坐标系/符号

仅凭一次录制中 `accelerometer` 的正负号与样例不同，不能直接判定坐标系错误：手机姿态差异会改变重力在设备坐标系下的分量符号。

更像“实现偏差”的通常是：

- `aligned:true` 但两路内参未贴齐
- `imuToCamera` 的平移占位丢失
- 深度分辨率不匹配
- 采样率配置不一致

