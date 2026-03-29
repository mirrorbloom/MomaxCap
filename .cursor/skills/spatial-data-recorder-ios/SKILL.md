---
name: spatial-data-recorder-ios
description: >-
  spatial_data_recorder 项目的环境约束、跨机开发流程、Flutter+iOS SLAM 采集架构与 MethodChannel 约定。
  在修改 iOS 原生代码、真机调试、pubspec、部署版本或 Windows/Mac 协作时使用。
---

# spatial_data_recorder · iOS 采集开发上下文

## 环境与版本约束

| 项目 | 当前约定 |
|------|-----------|
| **日常写代码** | Windows（Android Studio / VS Code + Flutter） |
| **iOS 编译 / CocoaPods / 真机 USB 调试** | Mac 上拉取同一 Git 仓库后执行 |
| **Xcode** | **16.4**（与 Flutter 版本需兼容；以 Mac 上 `flutter doctor` 为准） |
| **iOS SDK / 真机系统** | 本机 Xcode 支持的最高系统为 **iOS 18.5**；测试机系统应 **≤ 18.5**，避免使用仅 19+ SDK 的 API |
| **最低系统（部署目标）** | **iOS 15.0**（`Podfile` `platform` 与 Xcode `IPHONEOS_DEPLOYMENT_TARGET` 已对齐） |
| **CocoaPods** | Mac 上需安装；首次或依赖变更后在 `ios/` 执行 `pod install` |

说明：iOS 应用**无法**在 Windows 上编译；Windows 上可跑 `flutter analyze`、写 Dart/UI；**原生 Swift、签名、真机安装**必须在 Mac 上完成。

## Mac 上首次拉取后的命令

```bash
cd /path/to/spatial_data_recorder
flutter pub get
cd ios && pod install && cd ..
flutter devices
flutter run -d <iphone_device_id>
```

若 `ios/Podfile` 或插件变更后构建失败，可尝试：`cd ios && pod repo update && pod install`。

## Windows → Mac 协作注意

1. **换行与权限**：提交前统一 LF；避免把 `ios/Pods/`、`ios/.symlinks/` 等提交进 Git（由 `.gitignore` 处理）。
2. **Flutter 版本**：两台机器使用**相同 major 的 Flutter**（或同一 `fvm` 配置），减少 `Generated.xcconfig` 与插件注册不一致。
3. **签名**：在 Mac 的 Xcode 中设置 Team、`Signing & Capabilities`；证书与描述文件不入库时，每位开发者本地配置一次即可。

## 项目目录与职责（Dart）

| 路径 | 职责 |
|------|------|
| `lib/main.dart` | 入口：`ProviderScope` + `SpatialDataRecorderApp` |
| `lib/app/` | 根 `MaterialApp`、主题、路由入口 |
| `lib/core/constants/` | `MethodChannel` 名称等常量（与 iOS 一致） |
| `lib/core/recorder/` | 录制平台抽象与 `MethodChannel` 实现 |
| `lib/features/home/` | 首页与后续功能入口 |

原生侧：`ios/Runner/AppDelegate.swift` 注册与 Dart 相同的 channel 名；后续可将具体逻辑拆到独立 Swift 文件并在 Xcode 中加入工程。

## MethodChannel 约定

- **名称**：`com.binwu.reconstruction.spatial_data_recorder/recorder`（与 `lib/core/constants/recorder_channel.dart` 中常量一致）。
- **Bundle ID**：`com.binwu.reconstruction.spatialDataRecorder`（Xcode / Apple 开发者后台需一致）。

实现清单见仓库内 `docs/Flutter-iOS-SLAM数据采集应用开发指南.md`（Spectacular 数据格式、`data.mov` / `data.jsonl` / `calibration.json` 等）。

## 依赖用途（pubspec）

- **flutter_riverpod**：应用状态与后续录制/上传流程。
- **path_provider**、**path**：会话输出目录、拼接路径。
- **permission_handler**：相机 / 运动权限请求（与 `Info.plist` 文案配合）。
- **dio**：HTTP 上传（预签名 URL 或 multipart）。
- **archive**：会话打包 zip。
- **uuid**：会话 ID。

## 传感器与模拟器

真机才能完整验证相机 + IMU；iOS 模拟器中 IMU 不可用，详见主文档「混合模式」与模拟器说明。
