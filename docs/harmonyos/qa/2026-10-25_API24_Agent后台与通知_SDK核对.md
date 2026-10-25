# Agent 后台与通知：本机 SDK 声明核对

> 2026-10-25，本文件是本机 SDK 文本核对，不是华为官方问答，也不是 API 24 / XT2 运行证据。

来源：`/Applications/DevEco-Studio.app/Contents/sdk/default/sdk-pkg.json` 标注 API 26、26.0.0.105；以下仅依据声明中的 `@since` 判断接口声明是否覆盖 ≤24，不能据此证明场景资格。

- `openharmony/ets/api/@ohos.resourceschedule.backgroundTaskManager.d.ts`：`requestSuspendDelay(reason, callback)` 标注 since 9，返回 DelaySuspendInfo；短时收尾不是无限运行保证。`startBackgroundRunning(context, request: ContinuousTaskRequest)` 标注 since 21，并说明通知与取消机制。
- 同文件 `BackgroundTaskMode.MODE_DATA_TRANSFER` 标注 since 21，描述非托管上传/下载，需要进度更新；不把模型等待或多轮 Agent 自动归为该类别。
- 同文件 `MODE_TASK_KEEPING` 标注 since 21，说明计算任务面向 PC/2in1，其他设备需要受限权限；`MODE_SPECIAL_SCENARIO_PROCESSING` 说明 API 24 起有 ACL 条件。XT2 是 phone，不能以大屏外观套用 PC 资格。
- `openharmony/ets/api/@ohos.notificationManager.d.ts`：`publish(request): Promise<void>` since 9；`isNotificationEnabled(): Promise<boolean>` since 11；带 UIAbilityContext 的 `requestEnableNotification(context, callback)` since 10。声明要求 UI 已加载，并说明拒绝后不能反复弹同一授权申请。

未知：本应用是否符合任一持续后台任务场景、ACL/审核能否获准、小艺能否后台继续同一模型请求/工具循环，以及进程回收后的状态查询/消息补送。需官方明确依据与 API 24 / XT2 正常运行验证，不能靠接口名称判断。
