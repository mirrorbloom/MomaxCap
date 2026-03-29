# Flutter iOS SLAM 数据采集应用开发指南

> 基于 Spectacular Rec 数据产出能力的复刻实现方案

## 一、项目概述

### 1.1 目标

开发一款基于 Flutter 的 iOS 数据采集应用，通过 Swift 插件（MethodChannel）实现高精度同步录制，自动生成符合 Spectacular AI 规范的标准化 SLAM 数据包，并支持采集数据自动同步至服务器。

### 1.2 输出数据包结构

| 文件               | 说明                                                            |
| ------------------ | --------------------------------------------------------------- |
| `data.mov`         | 主相机视频（iOS 常用 MOV 容器，与 Spectacular 的 mkv/mp4 等效） |
| `data.jsonl`       | IMU 传感器数据与帧元数据（JSON Lines 格式）                     |
| `calibration.json` | 相机内参矩阵与外参（IMU-相机变换）                              |

可选扩展：`vio_config.yaml`（算法参数）、多相机场景下的 `data2.mov` 等。

### 1.3 重要说明：Spectacular AI iOS SDK 现状

根据 [Spectacular AI 官方文档](https://spectacularai.github.io/docs/sdk/wrappers/mobile.html)：

- **Spectacular AI SDK 目前不提供 iOS/macOS 原生支持**
- Spectacular Rec iOS 为独立 App Store 应用，内部实现不开放
- Android 端有商业授权的原生封装（Camera 2 API）

因此，本方案采用 **自研实现**，严格遵循 Spectacular AI 的 [数据格式规范](https://github.com/SpectacularAI/docs/blob/main/other/DATA_FORMAT.md)，确保产出数据可与 Spectacular 生态工具（如 NeRF、3DGS 重建）兼容。若未来 Spectacular 提供 iOS 商业 SDK，可考虑替换为官方实现。

### 1.4 效果对比：自研方案 vs Spectacular Rec

| 维度              | Spectacular Rec（官方）                 | 本自研方案                                                           | 差异程度                     |
| ----------------- | --------------------------------------- | -------------------------------------------------------------------- | ---------------------------- |
| **数据格式**      | 严格符合 Spectacular 规范               | 严格遵循同一规范                                                     | 无差异，后处理工具可直接复用 |
| **时间同步**      | 可能具备硬件级或深度优化的相机-IMU 同步 | 基于软件时间戳（`CACurrentMediaTime` 等），相机与 IMU 分别打戳后对齐 | 有差异，可能出现数毫秒级抖动 |
| **标定**          | 可能内置设备级或出厂标定                | 需自行标定或使用静态/默认内参                                        | 有差异，标定质量影响重建精度 |
| **相机控制**      | 对焦/曝光锁定等可能针对 SLAM 场景优化   | 使用 AVFoundation 标准 API 实现锁定                                  | 差异较小，功能可对齐         |
| **多相机/深度**   | 可能支持多摄、深度流                    | 基础实现通常为单目，扩展需额外开发                                   | 有差异，取决于实现范围       |
| **实时 VIO 预览** | 可能提供轨迹预览等                      | 仅录制原始数据，无实时 SLAM 预览                                     | 有差异，为功能取舍           |
| **视频容器**      | mkv / mp4                               | MOV（iOS 常用）                                                      | 无实质差异，内容兼容         |

**结论：**

- **数据格式与后处理兼容性**：若严格按 Spectacular AI 规范实现 `data.jsonl`、`calibration.json` 及视频，NeRF、3DGS 等后处理流程应能直接使用，**与 Spectacular Rec 的差异主要体现在数据质量，而非格式**。
- **主要差距**：时间同步精度、标定精度。Spectacular Rec 作为专业采集工具，在相机-IMU 对齐和标定上可能有更多优化；自研方案在常规室内场景、短时采集下通常可满足需求，但对高精度、长轨迹、复杂光照等场景，效果可能略逊。
- **适用场景**：本方案适合需要**自定义采集流程、集成到自有 App、对接自有服务器**的场景；若追求与 Spectacular Rec 完全一致的数据质量，可优先考虑使用官方 Spectacular Rec 采集，再在自有系统中做后续处理与同步。

---

## 二、开发环境搭建

### 2.1 必需工具

| 工具      | 版本要求       | 用途                      |
| --------- | -------------- | ------------------------- |
| Flutter   | ≥ 3.16         | 跨平台 UI 与插件调度      |
| Xcode     | ≥ 15.0         | iOS 编译、真机调试、签名  |
| macOS     | ≥ 13 (Ventura) | iOS 开发需在 macOS 上进行 |
| CocoaPods | ≥ 1.14         | iOS 依赖管理              |

### 2.2 Windows 开发 + iPhone 真机运行方案

若你主要在 **Windows** 上开发，没有 Mac，但希望将应用安装到 **iPhone 真机** 上运行，可采用以下方案。核心点：**iOS 构建必须在 macOS 上完成**，但可通过云端或远程 Mac 实现，无需本地 Mac。

| 方案 | 流程 | 成本 | 适用场景 |
|------|------|------|----------|
| **云端 CI + TestFlight** | Windows 写代码 → 推送到 Git → Codemagic/GitHub Actions 在云端 macOS 构建 → 上传 TestFlight → 在 iPhone 上通过 TestFlight App 安装 | Apple 开发者 $99/年；Codemagic 有免费额度 | 日常开发、迭代测试，无需 Mac |
| **云端 Mac 远程桌面** | 租用 MacinCloud、MacStadium 等 → 远程桌面连接 → 在云端 Mac 上完整开发、Xcode 真机调试 | 约 $20–50/月（按需计费） | 需要调试 Swift 插件、频繁真机测试 |
| **GitHub Actions** | 配置 `.github/workflows` → push 触发构建 → 产出 IPA，可配合 TestFlight 或自建分发 | 免费（公开仓库）或按分钟计费 | 熟悉 CI/CD，希望零额外成本 |

**推荐流程（无 Mac 时）：**

1. **开发**：在 Windows 上用 Android Studio / VS Code 写 Flutter 和 Dart 代码。
2. **构建**：使用 [Codemagic](https://codemagic.io/) 或 [GitHub Actions](https://github.com/actions) 配置 iOS 构建流水线（需 Apple 开发者账号、证书与描述文件）。
3. **安装**：构建完成后自动上传到 TestFlight，在 iPhone 上安装 TestFlight App，从 TestFlight 下载并运行你的应用。

**关于 USB 直连安装：**

- **有 Mac 时**：可用 USB 连接 iPhone，在 Xcode 或 `flutter run` 中直接构建并安装到真机，支持即时调试、Hot Reload。
- **仅 Windows 时**：**无法**通过 USB 将应用安装到 iPhone。Apple 未提供 Windows 端的安装工具，需通过 TestFlight 等无线方式安装。

**限制说明：**

- TestFlight 安装需要 **Apple Developer Program**（$99/年）。
- 首次配置证书、描述文件、CI 流水线需要一定学习成本。
- 无法像在 Mac 上那样直接 USB 连接真机做即时调试，每次修改需重新构建并等待 TestFlight 更新（通常几分钟到十几分钟）。

**关于在 Windows 上运行 macOS 虚拟机：**

在 Windows 上通过 VMware、VirtualBox 等运行 macOS 虚拟机，理论上可以在虚拟机内安装 Xcode 并构建 iOS 应用，但存在以下问题：

| 问题 | 说明 |
|------|------|
| **许可** | Apple 的 macOS 许可协议规定，macOS 仅可在 Apple 品牌硬件上运行。在非 Apple 电脑的虚拟机中运行 macOS 不符合许可要求。 |
| **真机调试** | 需将 iPhone 通过 USB 直连虚拟机，依赖 USB 透传，配置复杂且兼容性不稳定。 |
| **性能** | 虚拟机中运行 Xcode 编译较慢，开发体验较差。 |
| **架构** | 新版本 macOS 主要面向 Apple Silicon，在 x86 Windows 上只能运行较旧的 Intel 版 macOS，与最新 Xcode 兼容性有限。 |

综合来看，**不推荐**将 macOS 虚拟机作为主要开发方式。若需要完整 Mac 环境，更建议使用云端 Mac 租用（如 MacinCloud）或云端 CI + TestFlight 方案。

**关于在 Windows 上运行 iOS 模拟器（仅模拟器调试、不装真机）：**

Apple 的 **iOS Simulator** 随 Xcode 提供，**仅支持 macOS**，官方没有 Windows 版。若希望在 Windows 上通过模拟器调试 iOS 应用，可选方案如下：

| 方案 | 说明 | 成本 | 调试能力 |
|------|------|------|----------|
| **云端 Mac 远程桌面** | 租用 MacinCloud、MacStadium 等 → 远程连接后在云端 Mac 上启动 iOS Simulator → 在 Windows 上通过远程桌面操作模拟器 | 约 $20–50/月 | 完整：断点、Hot Reload、Flutter 调试 |
| **Appetize.io** | 将 IPA 上传至 [Appetize.io](https://appetize.io/)，在浏览器中运行 iOS 模拟器 | 免费额度有限，付费按分钟计 | 仅功能/界面测试，无断点、无 Hot Reload |
| **BrowserStack / Sauce Labs** | 云端真机/模拟器测试平台，在浏览器中操作 | 付费订阅 | 适合自动化测试、兼容性测试，交互式调试较弱 |

**重要限制：**

- **本方案（相机 + IMU 采集）** 依赖真实硬件：相机、陀螺仪、加速度计等。iOS Simulator 中**无法模拟这些传感器**，相机会显示占位画面，IMU 为模拟数据。
- 因此，即使能在云端或浏览器中跑起 iOS 模拟器，**SLAM 数据采集功能无法在模拟器中完整验证**，仍需真机测试。
- 模拟器适合：UI 布局、基础导航、非传感器相关逻辑的调试。

**关于「直接获取模拟器上的模拟数据」：**

在 **macOS + iOS Simulator** 环境下，情况如下：

| 数据源 | 模拟器是否提供 | 说明 |
|--------|----------------|------|
| **相机** | ✅ 部分支持 | 模拟器可调用 Mac 的摄像头（`AVFoundation`），得到真实视频流，可录制为 `data.mov` |
| **IMU（CoreMotion）** | ❌ 不提供 | `CMMotionManager` 在模拟器中通常返回 `nil` 或零值，**无法直接获取**加速度计、陀螺仪数据 |

因此，**不能**完全依赖模拟器「自带」的模拟数据。可行做法是**混合模式**：

1. **相机**：在模拟器中正常调用 `AVCaptureSession`，使用 Mac 摄像头录制视频。
2. **IMU**：在 Swift 插件中通过 `#if targetEnvironment(simulator)` 检测模拟器，当在模拟器运行时，改为从**代码生成的模拟数据**写入 `data.jsonl`（即前文「通过代码直接生成模拟数据」的逻辑），而不是调用 `CMMotionManager`。

这样在模拟器中运行应用时，可得到：**真实视频（Mac 摄像头）+ 代码生成的 IMU**，无需真机即可跑通完整采集与打包流程。若在 Windows 上开发，仍需通过云端 Mac 才能使用模拟器。

**关于「Windows 上的模拟器能否调用摄像头」：**

| 环境 | 模拟器类型 | 摄像头支持 |
|------|------------|------------|
| **Windows + Android 模拟器** | Android Studio 自带模拟器 | ✅ 支持。可配置为使用 PC 摄像头（Extended Controls → Camera → Webcam） |
| **Windows + Appetize.io** | 浏览器内 iOS 模拟器 | ❌ 不支持。Appetize 使用的 iOS Simulator 不提供摄像头等硬件传感器 |
| **Windows + BrowserStack 等** | 云端设备测试 | 视方案而定，多数为占位或虚拟摄像头，非真实 PC 摄像头 |
| **Windows + 远程 Mac** | 云端 Mac 上的 iOS Simulator | ⚠️ 取决于云端 Mac 是否配备摄像头；多数云 Mac 无物理摄像头 |

结论：在 **纯 Windows** 环境下，若需模拟器调用摄像头，可优先使用 **Android 模拟器**（Flutter 支持 Android，可先开发 Android 端采集逻辑）。iOS 端若要在模拟器中使用摄像头，需使用 **本地 Mac** 或配备摄像头的 **云端 Mac**。

### 2.3 环境检查

```bash
# Flutter 环境
flutter doctor -v

# 确认 iOS 工具链
flutter doctor -v | grep -A5 "iOS toolchain"

# CocoaPods
pod --version
```

### 2.4 项目初始化

```bash
# 创建 Flutter 项目
flutter create --org com.yourcompany slam_recorder
cd slam_recorder

# 创建 Swift 插件（若采用 FFI 或独立插件包）
flutter create --template=plugin --platforms=ios -a swift slam_recorder_native
```

### 2.5 iOS 权限配置

在 `ios/Runner/Info.plist` 中新增：

```xml
<key>NSCameraUsageDescription</key>
<string>用于 SLAM 数据采集的相机录制</string>
<key>NSMotionUsageDescription</key>
<string>用于采集 IMU 传感器数据以支持视觉惯性里程计</string>
<key>NSMicrophoneUsageDescription</key>
<string>录制视频时可能需要麦克风</string>
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>fetch</string>
</array>
```

若需后台上传，可增加 `fetch` 或 `processing` 等后台模式。

---

## 三、架构设计

### 3.1 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Flutter (Dart)                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ 录制控制 UI  │  │ 同步管理    │  │ MethodChannel 调用   │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
└─────────┼─────────────────┼───────────────────┼─────────────┘
          │                 │                   │
          ▼                 ▼                   ▼
┌─────────────────────────────────────────────────────────────┐
│              iOS 原生层 (Swift)                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  RecorderPlugin (MethodChannel Handler)               │   │
│  │  - startRecording / stopRecording / getStatus         │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ CameraRecorder│  │ IMURecorder   │  │ DataPackager     │   │
│  │ (AVFoundation)│  │(CoreMotion)   │  │ (JSONL+JSON)     │   │
│  └──────────────┘  └──────────────┘  └──────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 MethodChannel 接口设计

建议在 `AppDelegate.swift` 或独立 Plugin 中注册：

```swift
// Channel 名称
static let channelName = "com.yourcompany.slam_recorder/recorder"

// 方法列表
enum RecorderMethod: String {
    case startRecording = "startRecording"   // 参数: outputDir, resolution, fps
    case stopRecording = "stopRecording"
    case lockFocusExposure = "lockFocusExposure"
    case unlockFocusExposure = "unlockFocusExposure"
    case getRecordingStatus = "getRecordingStatus"
}
```

---

## 四、核心实现要点

### 4.1 相机对焦与曝光锁定

SLAM 采集要求相机参数稳定，需在开始录制前锁定对焦和曝光。

**实现步骤（AVFoundation）：**

1. 获取 `AVCaptureDevice` 并 `lockForConfiguration()`
2. 设置对焦：`setFocusModeLockedWithLensPosition(lensPosition:completionHandler:)`
3. 设置曝光：`setExposureModeCustomWithDuration(_:iso:completionHandler:)`
4. 完成后 `unlockForConfiguration()`

```swift
// 伪代码示例
device.lockForConfiguration()
device.setFocusModeLockedWithLensPosition(0.5) { _ in
    device.setExposureModeCustomWithDuration(CMTime(value: 1, timescale: 60), iso: 400) { _ in
        device.unlockForConfiguration()
    }
}
```

**注意：** 对焦、曝光、白平衡的修改需按顺序执行，建议在各自的 completion handler 中链式调用，避免冲突。

### 4.2 高精度时间同步

- 使用 `CACurrentMediaTime()` 或 `mach_absolute_time()` 作为统一时间基准
- 视频帧时间戳与 IMU 采样时间戳需转换到同一时间轴
- JSONL 中 `time` 字段单位为秒，建议从接近 0 开始，便于浮点精度处理

### 4.3 data.jsonl 格式实现

遵循 [Spectacular AI DATA_FORMAT](https://github.com/SpectacularAI/docs/blob/main/other/DATA_FORMAT.md)：

**IMU 行示例：**

```json
{"sensor":{"type":"accelerometer","values":[-0.038,9.12,-2.98]},"time":1.438}
{"sensor":{"type":"gyroscope","values":[0.003,-0.17,0.016]},"time":1.449}
{"sensor":{"type":"imuTemperature","values":[292.9]},"time":1.449}
```

**帧行示例（单目）：**

```json
{ "frames": [{ "cameraInd": 0 }], "number": 0, "time": 0.0 }
```

- `accelerometer` 单位：m/s²
- `gyroscope` 单位：rad/s
- `imuTemperature` 单位：K
- 整文件按 `time` 升序排列

### 4.4 calibration.json 结构

```json
{
  "cameras": [{
    "focalLengthX": 547.55,
    "focalLengthY": 547.47,
    "principalPointX": 672.66,
    "principalPointY": 490.44,
    "model": "kannala-brandt4",
    "distortionCoefficients": [-0.028, 0.002, -0.005, 0.0004],
    "imuToCamera": [[...], [...], [...], [0,0,0,1]],
    "imageWidth": 1344,
    "imageHeight": 972
  }]
}
```

- 内参可通过设备标定工具预先获得，或使用设备默认值
- `imuToCamera` 为 4×4 齐次变换矩阵，将 IMU 坐标系变换到相机坐标系

### 4.5 视频输出

- 使用 `AVAssetWriter` 写入 MOV
- 确保帧率与 JSONL 中 `frames` 条目一一对应
- 建议使用 `AVCaptureVideoDataOutput` 获取 `CMSampleBuffer`，以精确控制时间戳

---

## 五、服务器同步方案

### 5.1 同步时机

- 录制结束后自动触发
- 支持批量上传队列（多段录制）
- 可选：Wi-Fi 连接时自动同步，移动网络时提示用户

### 5.2 实现方式

| 方案                     | 适用场景 | 说明                           |
| ------------------------ | -------- | ------------------------------ |
| HTTP multipart/form-data | 通用     | 将数据包打包为 zip 后 POST     |
| 预签名 URL (S3/OSS)      | 云存储   | 服务端生成上传 URL，客户端直传 |
| WebSocket / gRPC         | 实时流式 | 适合边录边传，实现复杂         |

### 5.3 自动化逻辑建议

1. 录制完成 → 将 `data.mov`、`data.jsonl`、`calibration.json` 打包为 `session_<timestamp>.zip`
2. 加入上传队列，持久化队列状态（如 SQLite/Isar）
3. 后台任务（`BGTaskScheduler`）或 App 进入前台时检查队列并上传
4. 上传成功后删除本地副本，保留元数据供用户查看

### 5.4 服务端目录结构建议

```
/slam_data/
  ├── {user_id}/
  │   ├── {session_id_1}/
  │   │   ├── data.mov
  │   │   ├── data.jsonl
  │   │   └── calibration.json
  │   └── {session_id_2}/
  │       └── ...
```

---

## 六、应用分发与分享

应用开发完成后，可通过以下方式分发给他人使用：

| 方式 | 适用场景 | 要求 | 说明 |
|------|----------|------|------|
| **TestFlight** | 内测、小范围分发 | Apple 开发者 $99/年 | 邀请测试者邮箱，对方安装 TestFlight App 后下载；最多 1 万外部测试者；构建 90 天有效 |
| **App Store** | 公开发布 | Apple 开发者 $99/年 | 提交审核后上架，任何人可下载；需通过 App Store 审核 |
| **Ad Hoc** | 内部测试（≤100 台设备） | Apple 开发者 $99/年 | 需注册每台设备的 UDID；通过链接或文件分发 IPA，安装需用 Mac 或第三方工具 |
| **开发安装** | 仅自己或少数设备 | 免费账号或开发者账号 | USB 连接 Mac，用 Xcode 或 `flutter run` 直接安装；免费账号 7 天后需重装 |

**推荐流程：**

1. **小范围测试**：用 TestFlight 邀请同事、朋友，对方通过邮件链接加入测试。
2. **正式发布**：通过 App Store Connect 提交审核，审核通过后用户可在 App Store 搜索下载。
3. **若仅 iOS**：本应用为 iOS 专用，可同时发布 Android 版（Flutter 支持）以扩大分发范围。

**Android 分发**（若需跨平台）：可打包 APK/AAB，通过 Google Play、应用内更新或自建下载页分发。

---

## 七、开发建议与注意事项

### 7.1 性能与稳定性

- 录制时避免主线程阻塞，IMU 与视频写入均放在后台队列
- 控制 JSONL 写入频率，可缓冲后批量写入以减少 I/O
- 长时间录制注意内存与磁盘空间监控

### 7.2 测试策略

1. **单元测试**：JSONL 格式校验、calibration 结构校验
2. **集成测试**：短时录制 → 解析 data.jsonl → 验证帧数与 IMU 采样数
3. **真机测试**：不同 iPhone 型号的相机与 IMU 行为差异

### 7.3 模拟数据采集（开发调试用）

在无真机或模拟器无法提供真实传感器时，可通过以下方式**模拟数据采集**，用于开发 UI、上传逻辑、数据打包等非硬件依赖部分：

| 方案 | 实现方式 | 适用场景 |
|------|----------|----------|
| **Mock MethodChannel** | Flutter 侧注入 `MethodChannel` 的 mock 实现：`startRecording` 时复制预置的 `data.mov`、`data.jsonl`、`calibration.json` 到输出目录，模拟录制完成 | 在 Windows/模拟器上测试完整流程：打包、上传、UI 状态 |
| **预录制数据回放** | 用真机或 Spectacular Rec 录一段标准数据包，放入项目 `assets/` 或测试目录；开发模式下「录制」时直接复制该数据包，不调用真实相机/IMU | 验证数据格式、后处理兼容性、上传接口 |
| **合成 JSONL 生成** | 编写脚本或 Dart 代码，按 Spectacular 格式生成 `data.jsonl`：时间戳递增、IMU 数值符合物理范围（如加速度约 9.8 m/s²、角速度 rad/s）、帧条目与视频时长匹配 | 单元测试、CI 自动化测试 |
| **占位视频** | 使用任意短视频或纯色视频作为 `data.mov`，配合合成 JSONL 和静态 calibration.json | 快速验证打包与上传逻辑 |

**实现示例（Mock MethodChannel）：**

```dart
// 开发模式下使用 mock
if (kDebugMode && !Platform.isIOS) {
  // 或：kIsWeb、模拟器检测等
  recorder = MockRecorder();  // 内部复制预置数据包
} else {
  recorder = NativeRecorder(channel);  // 调用真实 Swift 插件
}
```

**预置数据包结构建议：**

```
test_fixtures/
  ├── sample_session/
  │   ├── data.mov      # 短样本视频（可来自 Spectacular Rec 或任意来源）
  │   ├── data.jsonl    # 合成或真实采样的 JSONL
  │   └── calibration.json
```

**通过代码直接生成模拟数据（含 IMU）：**

可在 Dart、Python 等语言中编写生成器，按 Spectacular 格式输出 `data.jsonl` 和 `calibration.json`，无需预置文件。示例逻辑如下：

| 数据类型 | 单位 | 模拟值范围/公式 |
|----------|------|-----------------|
| `accelerometer` | m/s² | 静止时约 `[0, 0, -9.8]`（z 轴向上）；可加小幅随机扰动 `±0.1` 模拟手持抖动 |
| `gyroscope` | rad/s | 静止时约 `[0, 0, 0]`；小幅运动可设 `±0.1` 量级 |
| `imuTemperature` | K | 约 293～298（20～25℃） |
| `frames` | — | 每帧一行，`time` 按帧率递增（如 30fps → 每帧 +1/30 秒） |

**Dart 示例：生成 data.jsonl**

```dart
import 'dart:io';
import 'dart:math';

void generateMockDataJsonl(String path, {double durationSec = 5.0, int fps = 30}) {
  final rand = Random();
  final frameInterval = 1.0 / fps;
  final imuInterval = 1.0 / 200;  // IMU 通常 200Hz
  final lines = <MapEntry<double, String>>[];

  for (var t = 0.0; t < durationSec; t += imuInterval) {
    final ax = 0.1 * (rand.nextDouble() - 0.5);
    final ay = 0.1 * (rand.nextDouble() - 0.5);
    final az = -9.8 + 0.1 * (rand.nextDouble() - 0.5);
    lines.add(MapEntry(t, '{"sensor":{"type":"accelerometer","values":[$ax,$ay,$az]},"time":$t}'));
    lines.add(MapEntry(t, '{"sensor":{"type":"gyroscope","values":[${0.05 * (rand.nextDouble() - 0.5)},${0.05 * (rand.nextDouble() - 0.5)},${0.05 * (rand.nextDouble() - 0.5)}]},"time":$t}'));
    lines.add(MapEntry(t, '{"sensor":{"type":"imuTemperature","values":[${293 + rand.nextDouble() * 5}]},"time":$t}'));
  }
  for (var i = 0; i < (durationSec * fps).floor(); i++) {
    final t = i * frameInterval;
    lines.add(MapEntry(t, '{"frames":[{"cameraInd":0}],"number":$i,"time":$t}'));
  }
  lines.sort((a, b) => a.key.compareTo(b.key));
  File(path).writeAsStringSync(lines.map((e) => e.value).join('\n'));
}
```

**calibration.json 静态模板（代码生成）：**

```dart
const calibrationJson = '''
{
  "cameras": [{
    "focalLengthX": 547.55,
    "focalLengthY": 547.47,
    "principalPointX": 672.66,
    "principalPointY": 490.44,
    "model": "kannala-brandt4",
    "distortionCoefficients": [-0.028, 0.002, -0.005, 0.0004],
    "imuToCamera": [
      [1,0,0,0], [0,1,0,0], [0,0,1,0], [0,0,0,1]
    ],
    "imageWidth": 1344,
    "imageHeight": 972
  }]
}
''';
```

将上述生成逻辑封装为 `MockDataGenerator`，在开发模式下调用即可得到完整模拟数据包，无需真机或预录文件。

这样可在 Windows 上完成大部分开发与联调，仅在验证真实采集质量时使用真机。

**关于「真机录视频 → 上传到电脑 → 从视频中提取 IMU」：**

**不可行。** 普通视频文件（MOV、MP4 等）只包含图像序列和音频，**不包含 IMU 数据**。加速度计、陀螺仪由独立硬件采集，需在录制时与视频同时写入，无法事后从视频中提取。

因此，正确流程是：

1. **录制阶段**：在真机上用本应用（或 Spectacular Rec）**同时**录制视频 + IMU，得到 `data.mov` + `data.jsonl` + `calibration.json`。
2. **处理阶段**：将整个数据包上传到电脑或服务器，进行 NeRF、3DGS 等后处理。

若只有「视频文件」：可用视觉里程计（Visual Odometry）从图像估计运动，但那是**估算的位姿**，不是 Spectacular 格式要求的**真实 IMU 读数**，与 NeRF/3DGS 等工具的数据格式可能不兼容。要获得标准 SLAM 数据包，必须在录制时同步采集 IMU。

### 7.4 标定流程

若需高精度内参，建议：

1. 使用 Spectacular AI 标定工具生成 `calibration.json`
2. 或自研标定流程：Aprilgrid 标定板 + 多角度采集 + 离线优化

### 7.5 依赖与许可

- 若使用 FFmpeg 做视频后处理，需注意 GPL/LGPL 许可
- iOS 端 AVFoundation 编码通常足够，可避免引入 FFmpeg

---

## 八、参考资源

| 资源                      | 链接                                                                        |
| ------------------------- | --------------------------------------------------------------------------- |
| Spectacular AI 数据格式   | https://github.com/SpectacularAI/docs/blob/main/other/DATA_FORMAT.md        |
| Spectacular AI 录制文档   | https://spectacularai.github.io/docs/sdk/recording.html                     |
| Spectacular AI 移动端说明 | https://spectacularai.github.io/docs/sdk/wrappers/mobile.html               |
| Flutter MethodChannel     | https://docs.flutter.dev/platform-integration/platform-channels             |
| AVFoundation 对焦文档     | https://developer.apple.com/documentation/avfoundation/capture-device-focus |
| CoreMotion 框架           | https://developer.apple.com/documentation/coremotion                        |

---

## 九、快速启动清单

- [ ] 安装 Flutter、Xcode、CocoaPods
- [ ] 创建 Flutter 项目并配置 iOS 权限
- [ ] 实现 MethodChannel 与 Swift RecorderPlugin 骨架
- [ ] 实现 AVFoundation 相机录制 + 对焦/曝光锁定
- [ ] 实现 CoreMotion IMU 采集与 JSONL 写入
- [ ] 实现 calibration.json 生成（静态或标定）
- [ ] 实现录制结束后的数据包打包
- [ ] 实现上传队列与服务器同步
- [ ] 真机测试并验证数据格式兼容性

---

_文档版本：1.0 | 更新日期：2025-03-19_
