# API 26 AtomicFile.startWrite 13900020 转贴答复核验

## 来源与边界

本记录整理用户转贴的一份 HarmonyOS 开发助手答复。答复自称基于 HarmonyOS API 26 模拟器与 API 24 兼容工程，但未附官方文档链接、文档标题或 SDK 声明位置；其来源无法独立确认，因此不视为官方答复。以下 SDK 核验仅基于本机 DevEco Studio 26.0.0.851 内置 HarmonyOS SDK 26.0.0.105 的声明，不代表 API 24 SDK 或 XT2 实测。

## 逐项核验

| 问题 | 转贴答复说法 | 核验结果 |
| --- | --- | --- |
| `AtomicFile.startWrite()` 返回 13900020 的原因 | 文档没有说明具体原因；13900020 在通用 File IO 错误码中表示 Invalid argument。 | **部分与本机声明相符，根因仍未知。** API 26 SDK 中 `AtomicFile.startWrite()` 的异常列表未列 13900020；其他 File IO 方法有将该码说明为 Invalid argument 的声明，但不能据此解释 `startWrite()` 的本次错误。 |
| 路径与父目录限制 | 声称父目录必须存在且可写，AtomicFile 不负责路径规范化。 | **未能由所查声明确认。** API 26 SDK 的构造参数说明目标是应用沙箱路径；`startWrite()` 说明目标文件不存在时会创建。所查方法声明没有记录父目录可写前置条件或规范化语义。目标目录状态仍以本项目模拟器日志为准，不能由转贴答复推导错误原因。 |
| 并发要求 | 声称不同路径实例不要求串行；同一实例未 finish/fail 前不能再次 start。 | **未记载。** 所查 API 26 SDK 声明没有给出线程安全或并发保证，也没有写明重复调用时的行为。项目串行化后仍复现，只能说明串行化未解决该次复现，不能据此排除并发因素为一般性原因。 |
| API 24 可用版本及行为 | 声称 AtomicFile 自 API 9 起可用，且 API 24 与 API 26 使用相同错误码体系。 | **存在版本冲突，API 24 未核实。** 本机 API 26 SDK 的 `AtomicFile` 类、构造器及 `startWrite()` 均标记 `@since 15`，与转贴答复的 API 9 冲突。本机当前安装的 SDK 目录只有 API 26，无法据此独立确认 API 24 SDK 声明或错误码行为；API 26 模拟器结果不外推到 API 24 或 XT2。 |
| 诊断代码示例 | 建议用 `createWriteStreamSync` 对照写入，并把 `statSync` 错误 13900015 当作文件不存在。 | **示例不应直接使用。** 本机 API 26 `@ohos.file.fs.d.ts` 未声明 `createWriteStreamSync`；其中声明的是 `createWriteStream`、`createStreamSync` 等接口。`statSync` 的异常列表列出 13900002 No such file or directory，没有列 13900015；该 SDK 在其他接口中把 13900015 说明为 File exists，因此示例用 13900015 判断文件不存在与本机声明不符。未经 API 24 SDK 与官方资料确认，不采用这些示例作为诊断代码。 |

## 本机证据

- SDK 包：`/Applications/DevEco-Studio.app/Contents/sdk/default/sdk-pkg.json`，`apiVersion` 为 `26`，版本 `26.0.0.105`。
- 声明：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/api/@ohos.file.fs.d.ts`。`AtomicFile` 类和 `startWrite()` 标注 `@since 15`；`startWrite()` 异常列表为 13900001、13900002、13900012、13900027、13900042，没有 13900020。
- `13900020` 在该 SDK 的其他文件操作声明中出现为 `Invalid argument`；该含义只适用于对应方法的声明，不足以确定 `AtomicFile.startWrite()` 的错误原因。
- 本机 API 26 模拟器上目标不存在、父目录存在且为目录时多次复现 `startWrite()` 返回 13900020；详细设备和请求证据见 [v0.3 §6](../../releases/v0.3/需求文档.md) 与 [原始提问记录](../prompts/2026-10-20_API26_AtomicFile_startWrite_13900020.md)。

## 结论

当前答复不能解除 C1-API26 阻塞，也不能作为 API 24 或 XT2 结论。保留已核实的 API 26 SDK 声明和模拟器实测；错误根因、父目录额外要求、并发语义及 API 24 行为仍待有出处的官方资料或对应设备验证。

## 第二份用户转贴答复复核（2026-10-21）

第二份答复原文归档于 [`第二份转贴答复原文`](2026-10-21_API26_AtomicFile_第二份转贴答复原文.md)。它同样没有官方文档 URL、文档标题或 SDK 声明位置，因此不能视为官方结论。

| 内容 | 核验 |
| --- | --- |
| `startWrite()` 对 13900020 的原因未记载 | 与当前证据边界相符；13900020 在其他 File IO 声明中的含义不能直接套到 `startWrite()`。本机 API 26 SDK 的该方法异常表仍不含此码。 |
| `AtomicFile` 自 API 9 起可用 | 与本机 API 26 SDK 声明冲突：类、构造器和 `startWrite()` 均标 `@since 15`。API 24 SDK 未安装，API 24 可用性仍不能据此确认。 |
| 父目录必须预先存在且可写、路径不做规范化、不同路径无需串行 | 没有给出处；所查 API 26 声明只说明构造参数是应用沙箱路径、目标不存在时 `startWrite()` 会创建文件，未记载这些额外限制或并发保证。 |
| `createWriteStreamSync` 和 `statSync` 错误处理 | 本机 API 26 `@ohos.file.fs.d.ts` 未声明 `createWriteStreamSync`；`statSync()` 声明将 13900002 列为 `No such file or directory`，未列 13900015。13900015 在该 SDK 的其他接口中表示 `File exists`。 |
| 用普通 stream/open/unlink 做路径写入诊断 | 不采用。答复未给出 API 24 证据，且该做法绕过仓库要求的 `AtomicFile` 写入约束，可能修改实际目标或留下副作用；不据此在应用中实现诊断写入。 |
| 4096 字符路径上限、API 24 与 API 26 错误码体系一致、所有 File IO API 跨版本兼容 | 没有来源或 API 24 SDK 证据，保持未确认，不作为工程事实。 |

因此第二份答复没有提供可用于改码的新核实结论，也没有解除 v0.3 非空 clone 阻塞。仅保留原文和上述核验；追问出处的提示词见 [`来源与诊断方案追问`](../prompts/2026-10-21_API26_AtomicFile_来源与诊断方案追问.md)。
