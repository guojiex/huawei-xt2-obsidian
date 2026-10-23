# 追问：API 26 模拟器中 AtomicFile.WriteStream 写入 Git 二进制数据报 13900020

## 工程与设备

- 工程：曜石笔记，ArkTS + Stage，`compatibleSdkVersion` 为 6.1.1(24)。
- 验证设备：DevEco 的 `Huawei_TripleFold` 模拟器；系统识别型号为 `emulator`，HarmonyOS 7.0.0.107（`SP8DEVC00E999R4P11`）、API 26、arm64-v8a。
- 工具链：DevEco Studio 26.0.0.851，SDK 26.0.0.105。API 26 本机声明：
  - `@ohos.file.fs.d.ts`：`AtomicFile` 与 `startWrite()` 标记 `@since 15`；`startWrite()` 的方法级 `@throws` 未列 13900020。
  - `@ohos.util.stream.d.ts`：`Writable.write(chunk?: string | Uint8Array, encoding?: string, callback?: Function)`；文档列出的编码为 `utf8`、`gb18030`、`gbk`、`gb2312`。
- 同一模拟器此前对一个简单文本探针执行 `AtomicFile.startWrite()`、写入字符串、回调中 `finishWrite()` 成功。该证据只覆盖字符串写入的那条路径。

## 本轮复现事实

- clone 的 HTTP fixture 收到 `GET /conflict.git/info/refs → 200` 和 `POST /conflict.git/git-upload-pack → 200`。
- clone 的 `.git/config` 由 ArkTS fs 后端以 `AtomicFile` 写入。`startWrite()` 返回 `WriteStream` 后，调用 `stream.write(bytes, 'utf8', callback)`，其中 `bytes` 是由 Base64 解码得到的 `Uint8Array`。成功回调中调用 `finishWrite()`；失败时调用 `failWrite()`，不显式关闭流。
- 首次 UI 曾报告 `AtomicFile startWrite failed ... 13900020`。复核代码发现当时 `startWrite()` 和 `stream.write()` 共用一个 `try/catch`，因此该阶段文案不能证明异常来自 `startWrite()`。
- 开启实时 hilog 后，同一 App 进程在 clone 写入时记录：
  - `file_api: [common_func.cpp:683->GetWriteArg] Illegal write buffer or encoding`
  - `file_api: [stream_n_exporter.cpp:265->WriteExec] Failed to resolve buf and options`
- 可复核的模拟器日志时间 / PID：2026-10-22 20:46:16.028 / 17433、20:53:27.299 / 25288、20:56:46.390 / 28580、21:00:53.094 / 1236。实时日志没有打印具体目标路径；这些时间与对应的新隔离目标 clone 操作相邻。
- 将 `startWrite()` 和 `stream.write()` 分开捕获后，新隔离目录中的 UI 显示 `AtomicFile write failed for .git/config: 13900020: Invalid argument`。这把失败阶段定位到 `WriteStream.write()` 调用，但不能单独确定是 buffer、encoding、运行时实现还是其他参数问题。
- 在 API 26 模拟器新隔离目标上，以下调用变体仍出现相同 hilog 参数解析错误与 13900020：`write(bytes, 'utf8', callback)`、`write(bytes, undefined, callback)`；另试过先复制 `Uint8Array` 再写，也未解决。
- 没有清理先前的 `_b`、`_c`、`/vault` 失败数据，也没有清理本轮 `_d` 至 `_g` 隔离目标。没有改用普通 stream/open/unlink/rename 绕过 AtomicFile。

## 请核实

1. 官方 API 文档是否明确保证 `AtomicFile.startWrite()` 返回的 `WriteStream` 可用 `write(Uint8Array, encoding?, callback?)` 写二进制内容？请提供 API 24 与 API 26 的文档章节、签名、版本和直接链接；若只保证字符串，请明确说明。
2. 对 `Uint8Array` chunk，官方 `Writable.write()` 是否要求省略 `encoding`？若可以传入，请列出合法编码的准确拼写、参数顺序和回调签名。不要只给字符串写入示例。
3. `GetWriteArg: Illegal write buffer or encoding` / `WriteExec: Failed to resolve buf and options` 与 `13900020` 是否有官方对应说明或已知问题记录？若没有，请明确标为未记载，勿推断到 `AtomicFile.startWrite()` 或文件路径。
4. 请给一个 API 24 可用、严格使用 `AtomicFile`、将任意 `Uint8Array` 二进制完整写入并在成功/失败时分别收尾的最小 ArkTS 示例。不得用普通 stream、直接 open、tmp+rename 或其他方式绕过 AtomicFile。
5. 若 API 声明与 API 26 模拟器运行结果矛盾，是否有官方支持渠道可提交？请列出最小诊断材料；无需笔记内容、令牌、真实仓库地址或未脱敏沙箱绝对路径。

## 回答要求

- 每项标注“官方文档明确说明 / 本机 SDK 声明 / 已知问题记录 / 推断 / 未记载”。
- API 26 模拟器证据不得外推到 API 24 运行时或 XT2 真机。
- 不要将通用 `Invalid argument` 直接解释为某个内部步骤或具体根因。
- 不确定就直说；不要编造接口、内部实现、限制或修复版本。
