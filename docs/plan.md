## Plan: P3 上传架构（ZIP + 自动队列）

目标是基于现有录制闭环，在不改动 iOS 采集核心的前提下，新增可配置的网络上传架构：停止录制后自动把会话目录打包为 ZIP，按 multipart/form-data 上传；上传成功后删除 ZIP、保留原始 recording 目录；ZIP 内容遵循样例合同（排除 README），并兼容可选 data2.mov。

**Steps**
1. 阶段一：冻结上传合同与配置入口。明确 ZIP 允许与禁止内容：必需 data.mov、data.jsonl、calibration.json、metadata.json，必需包含 frames2 目录（若存在），可选 data2.mov，明确排除 README 与其他非合同文件。定义上传配置占位（baseUrl、path、超时、header 注入钩子），方便后续你接入真实端口。 
2. 阶段一：建立上传领域模型与状态机（依赖步骤 1）。定义 UploadTask、UploadState、UploadFailureReason、UploadProgress，覆盖 waiting/compressing/uploading/success/failed/retrying/cancelled，并定义任务幂等键（sessionPath）。
3. 阶段二：实现会话清单扫描与预校验（依赖步骤 1，可与步骤 2 并行）。新增清单构建器，负责按白名单收集会话文件、校验必需文件、过滤 README、生成 ZIP 内相对路径映射，确保与 docs/recording_2026-03-18_19-14-19 结构一致。
4. 阶段二：实现 ZIP 打包服务（依赖步骤 3）。使用 archive 将 recording_* 目录打包为单个 ZIP，保存在 output/.upload_cache/ 下；输出 zipPath、zipSize、fileCount、manifest 摘要。完成后支持按策略删除临时 ZIP。
5. 阶段三：实现上传 API 客户端（依赖步骤 1，可与步骤 4 并行）。基于 dio 封装 multipart/form-data 上传，提供进度回调、取消、可替换 endpoint、可注入 headers。对网络错误与 4xx/5xx 做分类，供重试策略判断。
6. 阶段三：实现本地任务队列持久化（依赖步骤 2）。使用应用文档目录中的 JSON 队列文件持久化任务快照（而不是立即引入数据库），支持启动恢复、状态落盘、最大历史条数裁剪。
7. 阶段三：实现上传编排器与重试策略（依赖步骤 4、5、6）。新增 UploadQueueController（Riverpod StateNotifier/AsyncNotifier），实现 enqueue(sessionPath) -> compress -> upload -> cleanup 全链路；失败时按指数退避重试；仅对可重试错误重试；App 重启后自动续传 pending/failed（可配置）。
8. 阶段四：接入录制完成自动上传（依赖步骤 7）。在 HomePage 的 stopRecording 成功分支中拿到 sessionPath 后立即入队；保留录制主链路不阻塞，上传失败只影响上传状态提示，不回滚录制完成结果。
9. 阶段四：补充手动补传入口（依赖步骤 7，可与步骤 8 并行）。在 RecordingsBrowserPage 的 recording_* 目录项增加上传动作（长按或 trailing 菜单），用于历史会话补传与失败重试。
10. 阶段四：可视化上传状态与交互（依赖步骤 8、9）。在主页或录制浏览页展示当前任务状态、进度百分比、失败原因与重试按钮；保持 MVP 级简洁 UI，不引入复杂任务中心页面。
11. 阶段五：测试与验收（依赖步骤 3-10）。补充单元测试（清单扫描、ZIP 过滤、重试决策、队列恢复）与集成测试（mock Dio 成功/失败路径）；完成真机手工验收：录制 -> 自动上传 -> 成功后 ZIP 删除且 recording 保留。
12. 阶段五：文档与运维可接入说明（依赖步骤 11）。更新 MVP 文档和上传接入说明，列出服务端待接参数（endpoint、鉴权 header、响应字段约定、错误码映射），确保你后续只替换配置与协议细节即可。

**Relevant files**
- d:/AndroidStudioProjects/spatial_data_recorder/lib/features/home/home_page.dart — 复用 _stopRecording() 成功回调作为自动入队触发点。
- d:/AndroidStudioProjects/spatial_data_recorder/lib/features/home/recordings_browser_page.dart — 增加手动补传入口与状态展示。
- d:/AndroidStudioProjects/spatial_data_recorder/lib/core/recording/session_directory.dart — 复用会话目录命名与 output 根目录定位。
- d:/AndroidStudioProjects/spatial_data_recorder/lib/core/recorder/recorder_method_channel.dart — 复用 stopRecording() 返回 sessionPath 的契约。
- d:/AndroidStudioProjects/spatial_data_recorder/lib/core/recorder/recorder_providers.dart — 按现有 provider 风格扩展上传 provider 链。
- d:/AndroidStudioProjects/spatial_data_recorder/pubspec.yaml — 复用已有 dio/archive/uuid，不新增依赖即可落地 MVP。
- d:/AndroidStudioProjects/spatial_data_recorder/docs/MVP开发优先级.md — 回填 P3 完成项与已实现边界。
- d:/AndroidStudioProjects/spatial_data_recorder/docs/recording_2026-03-18_19-14-19/README.md — 作为 ZIP 内容合同来源（README 排除、其余结构对齐）。

**Verification**
1. 单元测试：给定含 README、额外杂项文件、可选 data2.mov 的会话目录，验证清单构建器输出只包含合同文件，且路径层级与样例一致。
2. 单元测试：模拟缺失必需文件（例如 calibration.json）时，任务进入 failed 且错误类型为不可上传，不进入网络请求。
3. 集成测试：mock Dio 成功响应，验证状态流 waiting -> compressing -> uploading -> success，且 ZIP 被删除、原始 recording 目录保留。
4. 集成测试：mock 可重试网络错误，验证重试次数、退避间隔和最终状态正确；重启应用后 pending 任务可恢复。
5. 真机验收：iPhone 录制一段数据后自动上传，检查 ZIP 内内容满足样例合同（除 README），若存在 data2.mov 也应被打包。
6. 回归验收：录制、停止、预览、文件浏览流程无行为回退；上传失败不影响录制文件落盘。

**Decisions**
- 上传协议：multipart/form-data 直接上传 ZIP。
- 触发时机：停止录制后自动入队并立即尝试上传。
- ZIP 内容：样例必需文件 + 若存在则包含 data2.mov；排除 README。
- 成功后清理策略：删除 ZIP，保留原始 recording 目录。
- 范围内：ZIP 打包、任务队列、失败重试、手动补传入口、可配置 endpoint 占位。
- 范围外：后台任务调度（BGTaskScheduler/WorkManager）、断点续传、分片上传、账号鉴权联调、服务端实现。

**Further Considerations**
1. 重试上限建议先固定为 3 次（指数退避），后续再做可配置化，避免首版行为复杂。
2. 队列持久化先用 JSON 文件实现，若后续任务规模增大再平滑迁移到数据库。
3. 上传响应建议尽早约定最小字段（taskId/sessionId/storagePath），减少后续端到端联调改动。