# API 26 AtomicFile 官方文档链接复核

## 来源与环境

本记录复核用户转贴的第三份 HarmonyOS AI 答复。答复标注“内容由 AI 生成”，因此以下将其视为带官方链接的线索，并与本机 API 26 SDK 声明交叉核对；不把 AI 答复本身当作官方来源。答复原文见[官方文档答复原文](2026-10-21_API26_AtomicFile_官方文档答复原文.md)。

工程 `compatibleSdkVersion` 为 API 24。本机 DevEco Studio 26.0.0.851 / HarmonyOS SDK 26.0.0.105；当前故障只在 Huawei_TripleFold API 26 arm64 模拟器复现，XT2 和 API 24 运行时均未验。

## 核查结论

| 项目 | 核查结果 |
| --- | --- |
| `AtomicFile` / `startWrite()` 最低版本 | 华为官方《[@ohos.file.fs（文件管理）](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs#atomicfile15)》分别以 `AtomicFile15+`、`startWrite15+` 标注 API 15；与本机 d.ts 的 `@since 15` 一致。API 24 高于最低版本，官方文档支持该 API 在 API 24 范围内使用；本机没有 API 24 SDK 声明，API 24 设备运行时仍未实测。 |
| `startWrite()` 的 13900020 根因 | [`startWrite` 官方章节](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs#startwrite15)说明目标不存在时会创建文件，但没有记载 13900020 的触发条件。本机 API 26 SDK 的 `startWrite()` 异常列表也未列此码。官方[文件管理错误码 13900020](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/errorcode-filemanagement#section13900020-无效的参数)说明通用含义为 Invalid argument；不能据此推断 `startWrite()` 的根因。 |
| 父目录、路径规范化、并发 | 官方 `AtomicFile` / `startWrite()` 章节未记载父目录预先存在或可写、路径规范化、嵌套路径、文件名长度、线程安全或并发要求。通用错误码文档也不能替代方法级契约。 |
| `statSync()` 错误码 | 官方[文件管理错误码 13900002](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/errorcode-filemanagement#section13900002-没有这个文件或目录)为 No such file or directory；本机 `statSync()` 声明列出该错误码，没有列 13900015。`Stat.isDirectory()` 是 API 9 声明，可直接判断父路径是否目录；不要用 `!isFile()` 推断它必然是目录。 |
| `accessSync()` 诊断 | 官方 `accessSync` API 9+ 可只读检查存在性；`AccessModeType.WRITE` API 12+ 可检查写权限，权限校验失败会抛 13900012。API 24 高于两者最低版本。本机 SDK 还为 `accessSync()` 列出 13900002、13900020 等异常；诊断应区分返回 `false` 和实际抛出的错误码。该检查不写目标文件，也不证明 `AtomicFile` 创建临时文件或完成重命名一定成功。 |
| `createWriteStreamSync` | 本机 API 26 SDK 未声明此名称。官方 API 为 [`fileIo.createWriteStream`](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs#fileiocreatewritestream12)，API 12+，同步返回 `WriteStream`；这不改变本工程工作区写入必须使用 `AtomicFile` 的约束。 |

## 对当前故障的影响

这份带链接的答复确认了 API 15 起始版本及 API 24 的 API 可用范围，并提供 `accessSync` / `statSync` 作为无写入副作用的路径诊断依据。它没有解释 API 26 模拟器中 `AtomicFile.startWrite()` 返回 13900020 的原因。初次核验时 `GitFsBackend.writeAtomic()` 已在失败后检查目标存在性、父路径存在性和目录类型；2026-10-21 后续版本增加父目录写权限检查。Huawei_TripleFold API 26 arm64 模拟器公开 clone 中，目标不存在、父目录存在且为目录，`accessSync(AccessModeType.WRITE)` 返回 `true`，但 `startWrite()` 仍返回 13900020。不能将“路径和权限检查正常”直接等同于运行时错误已定位；运行时证据见 v0.3 需求文档 §6。

结论：C1-API26 的 API 版本疑问已由官方文档解决；非空 clone 仍阻塞于未解释的 `startWrite()` 13900020。保留 AtomicFile 实现，不改用普通 stream 写入，不外推到 XT2。
