# P3 上传架构（ZIP + 自动队列）

本文档定义 Spatial Data Recorder 的 P3 上传实现。目标是在不改动 iOS 采集核心的前提下，实现录制完成后的自动压缩上传，并提供失败重试与手动补传能力。

## 1. 目标与边界

### 1.1 目标

- 停止录制后自动入队并尝试上传。
- 会话目录先压缩成 ZIP，再通过 multipart/form-data 上传。
- 上传成功后删除 ZIP，保留原始 recording 目录。
- 上传失败按指数退避重试。
- 文件浏览页支持手动补传或重试。

### 1.2 非目标

- 不实现后台任务调度（BGTaskScheduler/WorkManager）。
- 不实现断点续传和分片上传。
- 不实现服务端鉴权联调。

## 2. ZIP 内容合同

ZIP 仅包含以下数据，不包含 README 与其他非合同文件。

- 必需：data.mov
- 必需：data.jsonl
- 必需：calibration.json
- 必需：metadata.json
- 可选：data2.mov
- 可选目录：frames2/\*（若存在则全部纳入）

缺失任一必需文件时，任务直接失败，不发起网络请求。

## 3. 模块结构

- 核心配置与异常：lib/core/upload/upload_config.dart, lib/core/upload/upload_exceptions.dart
- 任务模型：lib/core/upload/models/upload_task.dart
- 会话清单构建：lib/core/upload/services/session_upload_manifest_builder.dart
- ZIP 打包：lib/core/upload/services/upload_zip_service.dart
- 上传客户端：lib/core/upload/services/upload_http_client.dart
- 队列持久化：lib/core/upload/repository/upload_queue_repository.dart
- 队列控制器：lib/core/upload/controller/upload_queue_controller.dart
- Riverpod 入口：lib/core/upload/upload_providers.dart

## 4. 状态机

任务状态如下：

- waiting：等待执行
- compressing：正在压缩
- uploading：正在上传
- retrying：等待重试
- success：上传成功
- failed：上传失败
- cancelled：已取消

失败分类：sessionNotFound、missingRequiredFile、zipFailed、network、timeout、unauthorized、serverRejected、cancelled、unknown。

## 5. 触发点与交互

### 5.1 自动触发

- Home 页面在 stopRecording 成功后获取 sessionPath。
- 立即调用 enqueueSession(sessionPath) 入队。
- 上传逻辑与录制链路解耦：录制成功不因上传失败回滚。

### 5.2 手动补传

- RecordingsBrowserPage 对 recording\_\* 目录提供上传菜单。
- 失败或取消状态可触发 retrySession。

### 5.3 状态展示

- Home 页面顶部显示最新上传任务状态。
- 上传中显示进度条，失败显示重试按钮。

## 6. 持久化与恢复

- 队列持久化文件：Documents/output/.upload_queue.json
- App 重启后恢复队列。
- 进程中断时未完成任务会回收为 waiting/retrying 后继续执行。

## 7. 重试策略

- 仅对可重试错误重试。
- 最大重试次数：默认 3 次。
- 退避策略：指数退避（baseDelay \* 2^(attempt-1)），上限 5 分钟。

## 8. 服务端接入说明

当前 upload endpoint 为占位配置，后续接入服务端时只需覆盖 UploadConfig：

- baseUrl：服务端地址
- uploadPath：上传路径
- extraHeaders：鉴权头或业务头
- timeout：连接与上传超时

上传请求体采用 multipart/form-data，包含：

- file：ZIP 文件
- sessionName：会话目录名
- sessionPath：客户端会话绝对路径（可按需移除）

## 9. 测试

已补充基础测试：

- 清单构建测试：合同文件过滤与必需文件校验
- ZIP 打包测试：压缩结果存在且路径映射正确

后续建议补充：

- Dio 上传失败分类与重试决策测试
- 队列恢复与重启续传测试
