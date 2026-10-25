# 追问：API 26 模拟器 AtomicFile.startWrite() 13900020 运行时诊断

## 工程与已核实事实

- 工程：曜石笔记，HarmonyOS ArkTS + Stage 模型，`compatibleSdkVersion` 为 `6.1.1(24)`。
- 当前复现设备：Huawei_TripleFold 模拟器；系统报告型号 `emulator`、HarmonyOS `7.0.0.107(SP8DEVC00E999R4P11)`、OpenHarmony `7.0.0.105`、API 26、`aarch64`。此故障没有在 API 24 运行时或 XT2 真机复现，不能外推。
- 本机 DevEco Studio 26.0.0.851 的 API 26 SDK `@ohos.file.fs.d.ts` 将 `AtomicFile` / `startWrite()` 标为 API 15+；`startWrite()` 方法级异常列表没有 13900020。华为官方 API 文档也确认 API 15+，但官方页面没有说明 `startWrite()` 返回 13900020 的触发条件。
- 已按官方答复执行只读诊断：目标不存在；父路径存在且是目录；`accessSync(parentPath, AccessModeType.WRITE)` 返回 `true`。API 26 arm64 模拟器上这些条件满足时，`startWrite()` 仍返回 13900020。诊断不写入或删除目标文件。

## 可复现的应用上下文

当前 unsigned HAP 的非空 Git clone 已收到 HTTP 200、6,299,610 B 的 `git-upload-pack` 响应，并经 WebMessagePort 完整接收。Git 内部文件写入批次完成后，首次写工作区文件时在 `new fileIo.AtomicFile(targetPath).startWrite()` 处失败；相对路径和正文已脱敏，目标位于应用 `filesDir/vaults/<新库 id>/` 下，父目录可写。失败后 clone 不登记为库。`GitFsBackend` 对非 `.git` 工作区文件用 `AtomicFile`；Git 内部 `.git` 数据通过现有直接写实现，不要建议将工作区文件改成普通 stream/open 写入。

同一模拟器上的应用编辑器此前通过 `NoteService.saveNote()` 对本地笔记完成一次 AtomicFile 保存。该对照路径的目标和调用时序并未与 Git 工作区文件逐项等同，不能据此推出原因。

## 请聚焦尚未回答的问题

API 最低版本、`accessSync` / `statSync` 的签名与通用错误码已核实，请不要重复这些结论。请根据可引用的 HarmonyOS 官方资料、SDK 声明、系统已知问题或开发者支持流程回答：

1. `startWrite()` 无显式参数却返回 13900020 时，这个错误是否可能由 AtomicFile 内部临时文件路径/文件操作抛出？是否有公开源码、错误码映射、已知缺陷或版本修复说明能够确认具体来源？如果没有，请明确“无法从公开资料确认”，不要把通用 Invalid argument 直接解释成具体根因。
2. `AtomicFile` 在应用沙箱 `filesDir/vaults/<id>/<nested path>` 下创建首次写入目标时，除目标父目录存在且可写外，还有哪些官方明确的前提？请区分有来源保证与未记载项目。
3. 若 `startWrite()` 本身抛错，官方是否要求或允许随后调用同一实例的 `failWrite()`？请给出方法文档依据，或明确未记载。
4. 若公开资料不足，针对上述 API 26 模拟器问题，官方建议向哪个开发者支持渠道提交？提交前可安全采集哪些最小诊断字段或最小 ArkTS 复现步骤？不要要求上传笔记内容、真实仓库凭据或敏感路径。

## 回答格式

- 每项标记为“官方文档明确说明 / 本机 SDK 声明 / 已知问题记录 / 未记载 / 推断”。
- 给出可访问的官方文档标题、章节、直接 URL 和适用 API 版本；无来源时明确说明。
- 不要凭空给出 API 名称、临时文件命名约定、路径长度限制或 API 24/26 行为一致性。
- 不要建议用 `createWriteStreamSync`、普通 `open/stream/unlink` 绕过 `AtomicFile` 写工作区。
