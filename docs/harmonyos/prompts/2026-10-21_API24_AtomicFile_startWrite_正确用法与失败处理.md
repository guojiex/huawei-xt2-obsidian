# 问题：API 24/26 下 `fileIo.AtomicFile.startWrite()` 的推荐用法与失败处理

## 工程与复现背景

- 工程：曜石笔记，ArkTS + Stage 模型，`compatibleSdkVersion` 为 `6.1.1(24)`。
- 本机 DevEco Studio `26.0.0.851`，HarmonyOS SDK `26.0.0.105`。
- 复现设备：Huawei_TripleFold 模拟器，系统报告型号 `emulator`，HarmonyOS `7.0.0.107(SP8DEVC00E999R4P11)`、OpenHarmony `7.0.0.105`、API 26、`aarch64`。
- 故障仅在上述 API 26 模拟器的非空 Git clone 集成路径复现；API 24 运行时和 XT2 真机尚未测试。
- 写入路径基于应用 `filesDir`，脱敏形态为 `filesDir/vaults/<id>/<仓库相对路径>`。失败时目标文件不存在、父目录存在且为目录，`accessSync(parentPath, AccessModeType.WRITE)` 返回 `true`。
- clone 已完整接收 HTTP 200 的 Git packfile；首次写工作区文件时，`new fileIo.AtomicFile(targetPath).startWrite()` 返回 `13900020`。笔记正文、真实路径和凭据均不在此提供。
- 本机 API 26 SDK 的 `@ohos.file.fs.d.ts` 将 `AtomicFile` / `startWrite()` 标为 API 15+。`startWrite()` 声明没有显式参数，方法级异常列表为 13900001、13900002、13900012、13900027、13900042，没有列 13900020。通用文件管理错误码资料将 13900020 标为 “Invalid argument”，但目前不能确认该通用说明如何映射到本次 `startWrite()`。

## 请回答 `AtomicFile` 的正确调用流程

请依据 HarmonyOS 官方 API 文档和 SDK 声明，说明 API 24 可用的 `AtomicFile` 写入生命周期，并给出一段最小、完整、可编译的 ArkTS 示例。请分别覆盖以下情况：

1. `startWrite()` 成功返回 `WriteStream` 后，如何调用 `write()`，应在何时调用 `finishWrite()`？异步 `write()` 回调报告失败时，应如何调用 `failWrite()`？
2. `startWrite()` 自身同步抛错、尚未返回 `WriteStream` 时，是否应调用同一实例的 `failWrite()`？若官方有示例，请提供具体章节和直接链接；若未记载，请明确说明。
3. `WriteStream` 是否应由调用者显式 `close()`？`finishWrite()` 或 `failWrite()` 是否负责结束相关写入资源？请给出方法级依据。
4. `finishWrite()` 或 `failWrite()` 自身抛错时，推荐如何保留原始错误并报告清理错误？调用失败后的 `AtomicFile` 实例能否复用，重试是否需要创建新实例？并发写入是否有官方保证？未记载的部分请标为未记载。
5. 对于 `startWrite()` 实际返回 13900020、但该码未出现在本机 `startWrite()` 异常列表的情况：官方文档是否说明该 API 可抛出通用错误码列表中的其他错误？请区分“错误码通用描述”和“该方法已确认的触发原因”，不要仅根据错误码名称推断具体根因。

## 资料与约束

- `@ohos.file.fs（文件管理）`：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs#atomicfile15
- `startWrite()`：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs#startwrite15
- `finishWrite()` / `failWrite()`：请提供对应官方章节的直接链接。
- 文件管理错误码 13900020：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/errorcode-filemanagement#section13900020-无效的参数

回答时请：

- 对每条结论标注“官方文档明确说明 / 本机 SDK 声明 / 推断 / 未记载”。
- 提供官方文档标题、章节、直接 URL、适用 API 版本；对未能核实的内容明确说无法确认。
- 不要编造临时文件命名、文件名长度限制、并发保证或错误码到内部步骤的映射。
- 不要建议用普通 `open`、stream 或 `unlink` 替代 `AtomicFile` 写工作区文件；仓库要求工作区文件保持原子写入。
- 不要把 API 26 模拟器观察外推为 API 24 或 XT2 的运行时结论。
