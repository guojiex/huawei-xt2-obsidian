# 追问：API 26 模拟器中 AtomicFile.startWrite() 返回 13900020

## 工程背景

- 工程：曜石笔记，HarmonyOS 原生 ArkTS Stage 模型，包名 `com.jxg.huaweiobsidian`。
- 工程 `compatibleSdkVersion`：`6.1.1(24)`；本次构建由 DevEco Studio 26.0.0.851 / API 26 SDK 编译。
- 设备：Huawei_TripleFold 模拟器，系统 HarmonyOS `7.0.0.107(SP8DEVC00E999R4P11)`、OpenHarmony `7.0.0.105`、API 26、arm64。
- 受影响代码：`entry/src/main/ets/git/GitFsBackend.ets` 的 `writeAtomic()`。目标路径由应用 `context.filesDir` 经唯一的 `VaultPathResolver` 拼接为 `vaults/<库 id>/<库内相对路径>`，没有硬编码沙箱绝对路径。
- 仓库约束：工作区原子写使用 `fileIo.AtomicFile`；不能仅凭经验改成 tmp + rename，也不能编造 HarmonyOS API。

## 当前实现与复现

当前工作区的写入顺序是：创建 `new fs.AtomicFile(abs)`，调用 `startWrite()`，再将字节写入 `WriteStream`，写回调成功后调用 `finishWrite()`；失败时调用 `failWrite()`。本次异常发生在 `startWrite()`，尚未得到 `WriteStream`。

在 API 26 模拟器的当前 unsigned HAP 中，无令牌公开 clone 已显示 WebMessagePort 就绪，大响应通过 ArrayBuffer 完整收到，随后收到 HTTP 200 小响应；第一笔工作区文件原子写的 `startWrite()` 抛出 BusinessError `13900020`。脱敏诊断只得到：目标文件不存在、父路径存在且为目录；没有记录任何绝对路径、笔记正文、URL、令牌或请求头。按现有 C1 决策增加 AtomicFile 写入串行化后，同一 clone 仍在相同阶段返回相同错误。

本机 API 26 SDK 的 `@ohos.file.fs.d.ts` 对 `AtomicFile.startWrite()` 说明“文件不存在时会创建”，方法级异常列表有 13900001、13900002、13900012、13900027、13900042，但没有 13900020。SDK 中其他 File IO 方法（例如 `access(path, mode?)`）的异常列表把 13900020 标为 `Invalid argument`；这是其他方法的声明，不能据此确定 `AtomicFile.startWrite()` 运行时错误的具体含义或根因。此前另一构建曾完成一次公开 clone；这不能代表当前工作树稳定，也不说明 API 24 或 XT2 的行为。

**2026-10-21 10:00 再次复现**：Huawei_TripleFold 模拟器（系统报告型号 `emulator`、HarmonyOS `7.0.0.107(SP8DEVC00E999R4P11)`、OpenHarmony `7.0.0.105`、API 26、`aarch64`、HDC `127.0.0.1:5555`）运行当前 unsigned HAP。SyncPage 显示 WebMessagePort 已就绪，HTTP 200 小响应经端口完整接收；首个工作区文件的 `AtomicFile.startWrite()` 仍以 13900020 失败。脱敏诊断为 `targetExists=false`、`targetIsDirectory=false`、`parentExists=true`、`parentIsDirectory=true`。本次 UI 树与截图：`.local/shots/v03_api26_atomic_repro_ui_20261021_100007.md`、`.local/shots/v03_api26_atomic_repro_100007_20261021_100050.png`。没有记录沙箱绝对路径、笔记内容、令牌或认证头。本次只是同一 API 26 模拟器的又一次复现，不用于推断根因、API 24 或 XT2 行为。

**2026-10-21 10:18–10:23 同进程对照观察**：在相同 Huawei_TripleFold API 26 arm64 模拟器、相同已运行 unsigned HAP 中，通过 Index 编辑器创建临时 Markdown 并输入内容；约 250 ms 后点击同步入口，`Index.flushSave → NoteService.saveNote` 成功完成，SyncPage 随后通过 Git 状态查询显示 1 个未提交文件。输入注入到点击之间没有高精度计时，因此不单独断言自动保存定时器是否已触发。此观察说明本次普通编辑器保存路径成功，而 `GitFsBackend.writeAtomic()` 的 clone 工作区路径在 `AtomicFile.startWrite()` 失败；两条路径的具体输入参数和运行上下文仍需对照，不能据此认定 API 或运行时根因。截图和逐项记录：`.local/shots/v03_api26_pending_badge_20261021_101942.png`、`.local/shots/v03_api26_pending_shape_401_evidence_20261021.md`。

**2026-10-21 12:55 真实 Git packfile 下行复现**：同一 API 26 arm64 模拟器接收本地临时仓库返回的有效 HTTP 200 `git-upload-pack` 响应，正文 6,299,605 B，经 WebMessagePort 分块完整接收；随后 clone 在 `GitFsBackend` 工作区文件 `AtomicFile.startWrite()` 返回 13900020，失败库未登记。只证明该 packfile 下行接收完整，不证明 clone/checkout 成功、API 24 或 XT2。UI 树与截图见 `docs/releases/v0.3/需求文档.md` §6 的“真实 Git packfile 下行”记录。

## 希望核实

1. 官方资料是否记录 `AtomicFile.startWrite()` 在 API 26 返回 `13900020 Invalid argument` 的可能原因？如果没有，请明确说文档未说明，不要猜测原因。
2. `AtomicFile` 的 path 除了必须是应用沙箱路径外，是否还有目录、文件名、权限、路径规范化或目标文件状态方面的限制？当前已确认父目录存在且为目录、目标不存在。
3. 对不同目标路径的 AtomicFile 写入，是否要求应用侧串行化？本工程已串行化后仍复现，请区分官方保证与推断。
4. `AtomicFile` 在 API 24 的可用版本、`startWrite()` 错误码和上述行为是否有可引用的官方说明？不要把 API 26 模拟器结论外推到 API 24 或 XT2。
5. 若官方文档未覆盖该错误，有哪些受支持的最小诊断步骤可以区分路径参数问题与运行时实现问题？结合上述普通 `NoteService.saveNote` 成功、Git clone 工作区写入失败的对照，指出需要采集哪些不含笔记内容或沙箱绝对路径的参数信息；不要根据对照自行猜测根因，也不要建议未经文档支持的替代 API。

请给出官方文档链接、适用 API 版本及必要的 ArkTS 声明示例；逐条区分官方确认、文档未记载和推断。不要编造接口或把推断写成确定结论。
