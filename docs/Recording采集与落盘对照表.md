# Recording：设备/API 能采到的 vs 当前 recording 里实际有的

范围与 [`Recording参数来源说明.md`](Recording参数来源说明.md) 一致。内参/外参含义见该文档第三、四节及 [`Spectacular样例对齐差距说明.md`](Spectacular样例对齐差距说明.md)。


| 设备/API 能采到的                 | 当前 recording 里实际有的                                                                                                                    |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| 主相机视频帧（经编码管线）               | `data.mov`（H.264，无麦克风轨）                                                                                                               |
| 第二路视频（深度灰度或超广角 RGB）           | **`data2.mov`**（若设备/会话支持双路）：深度模式为 **深度→8bit 灰度**；否则 **超广角 RGB**；见 `metadata.dual_capture_mode`                                      |
| 陀螺仪角速度 `rotationRate`       | `data.jsonl`：`sensor.type: gyroscope`（**rad/s**）                                                                                      |
| 重力 + 用户加速度合成的三轴加速度          | `data.jsonl`：`sensor.type: accelerometer`（**m/s²**，含重力）                                                                                  |
| 磁力计磁场                         | `data.jsonl`：`sensor.type: magnetometer`（**μT**）                                                                                         |
| 视频帧 `presentationTimeStamp` | `data.jsonl`：`frames` 行的根级 `time`（相对首帧秒）                                                                                                |
| 写入顺序上的帧序                    | `data.jsonl`：`frames` 行的 `number`                                                                                                     |
| 双机位 `frames`                  | **`frames[0]`** 广角 rgb；**`frames[1]`** 深度 gray+`depthScale`+`aligned`（深度模式）或超广角 rgb（MultiCam）                                                      |
| IMU 回调时刻（可与媒体时钟对齐）          | `data.jsonl`：传感器行的 `time`（相对 `timeOrigin` 秒）                                                                                         |
| JSONL 按时间有序                 | 停止后按 `time` 升序；同戳次序：陀螺 → 加速度 → 磁力计 → 帧                                                                                              |
| 缓冲刷盘                         | 结束时一次写入 `data.jsonl`                                                                                                                  |
| 对焦 / 曝光（及白平衡）稳定             | 会话开始约 **0.2 s** 后链式锁定（仅作用于**广角**设备）                                                                                                  |
| 机型代号 `hw.machine`           | `metadata.json`：`device_model`                                                                                                        |
| —                           | `metadata.json`：`platform`、`imu_temperature_status`、`intrinsics_source`、`p1`、`spectacular_sample_alignment`、`dual_capture_mode`        |
| IMU 芯片温度（Spectacular 可选）      | **不写入** JSONL                                                                                                                         |
| 原始 Float 深度文件（非视频）           | **不写入**（`data2` 为灰度可视化 H.264）                                                                                                            |
| 精确畸变系数 / 查找表                | **未写入** `calibration.json`                                                                                                            |
| 真实 IMU→相机外参（需标定）            | `calibration.json`：`imuToCamera` 仍为单位阵占位                                                                                               |

