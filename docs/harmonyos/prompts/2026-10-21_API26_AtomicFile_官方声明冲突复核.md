# 追问：核对 AtomicFile API 版本与 13900020 官方声明

## 工程背景与当前证据

- 工程：曜石笔记，HarmonyOS 原生 ArkTS Stage 模型，包名 `com.jxg.huaweiobsidian`，`compatibleSdkVersion` 为 `6.1.1(24)`。
- 设备复现：Huawei_TripleFold 模拟器，系统报告型号 `emulator`、HarmonyOS `7.0.0.107(SP8DEVC00E999R4P11)`、OpenHarmony `7.0.0.105`、API 26、`aarch64`。本次问题只在该模拟器复现，不推断 API 24 或 XT2。
- 受影响代码：`entry/src/main/ets/git/GitFsBackend.ets` 的 `writeAtomic()`。目标由 `context.filesDir` 经单一 `VaultPathResolver` 解析为库内路径，没有在日志中记录沙箱绝对路径、笔记内容、认证信息或请求头。
- 当前运行结果：非空 Git clone 的 HTTP 响应（含一次 6,299,605 B 有效 `git-upload-pack` 响应）已通过 WebMessagePort 完整接收，随后 `AtomicFile.startWrite()` 返回 BusinessError `13900020`。诊断为目标不存在、父路径存在且为目录。工作区 AtomicFile 写已串行化，多次复测仍失败。同一模拟器中普通编辑器 `NoteService.saveNote` 路径保存成功；两路径参数与执行环境还未逐项对照。
- 本机 DevEco Studio 26.0.0.851 随附 SDK 包 `26.0.0.105`。`openharmony/ets/api/@ohos.file.fs.d.ts` 将 `AtomicFile` 类、构造器和 `startWrite()` 标记为 `@since 15`；`startWrite()` 文档说目标不存在时创建，异常列表为 13900001、13900002、13900012、13900027、13900042，没有 13900020。当前本机安装目录只有 API 26 SDK，未找到 API 24 SDK 声明。
- SDK 中其他 File IO 方法把 13900020 说明为 `Invalid argument`，但 `startWrite()` 自身没有列出该错误码。所查 `statSync()` 异常列表将 13900002 标为 `No such file or directory`；13900015 在其他接口声明中表示 `File exists`。

此前收到一份未附链接的 HarmonyOS 开发助手答复，称 `AtomicFile` 自 API 9 起可用、父目录必须可写、不同路径无须串行化，并建议调用 `createWriteStreamSync` 和把 13900015 当作 `statSync` 的文件不存在错误。这些说法与本机 SDK 的 `@since 15` 相冲突或未获本机声明支持；`createWriteStreamSync` 也未见于本机声明。请先核对来源，不要直接沿用这些说法。

## 希望核实

1. 请给出 HarmonyOS 官方 API 文档链接和适用 API 版本：`fileIo.AtomicFile` 实际从哪个 API 版本开始提供？如果官方文档、SDK 声明或系统版本口径不同，请分别说明。如何解释官方答复称 API 9 与 API 26 SDK 标注 `@since 15` 的冲突？
2. 官方资料是否明确说明 `AtomicFile.startWrite()` 会因什么条件返回 `13900020`？如果没有，请明确答复“文档未记载具体原因”，不要把其他 File IO 接口的错误码含义套用到 `startWrite()`。
3. `AtomicFile` 的公开约束是否明确要求父目录预先存在且可写，或对路径规范化、嵌套目录、文件名、现存目标、线程/并发有额外要求？逐项引用资料；文档没写的请标“未记载”。
4. API 24 的 `AtomicFile`、`startWrite()` 方法签名和异常列表有无官方声明或对应 API 24 SDK 证据？请提供链接或准确声明出处；如果无法确认，不要用 API 26 模拟器结果代替。
5. 对 API 24 可用的公开诊断接口，若目标是区分传入路径问题与 `AtomicFile` 运行时失败，官方支持的最小步骤是什么？请给出精确接口名、API 版本、签名及异常码。不要建议本机 SDK 未声明的 `createWriteStreamSync`，不要把 13900015 作为文件不存在码，也不要建议用不安全写法替换 AtomicFile。

## 回答格式

- 每项分别标注：官方资料明确说明 / 本机 SDK 声明 / 文档未记载 / 推断。
- 提供可访问的官方文档 URL、文档章节和适用 API 版本；没有来源时明确说明。
- 若先前答复有错误，请直接更正并说明依据。不要编造 API、签名、路径限制或运行时保证。
