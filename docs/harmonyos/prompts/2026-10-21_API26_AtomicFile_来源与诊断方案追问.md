# 追问：AtomicFile 答复的官方出处与诊断 API

## 工程背景与当前证据

- 工程：曜石笔记，HarmonyOS ArkTS Stage 模型，`compatibleSdkVersion` 为 API 24。
- 当前复现仅发生于 Huawei_TripleFold API 26 arm64 模拟器：非空 Git clone 在 `AtomicFile.startWrite()` 返回 13900020。该现象不外推至 API 24 或 XT2。
- 本机 DevEco Studio 26.0.0.851 随附 HarmonyOS SDK 26.0.0.105：`openharmony/ets/api/@ohos.file.fs.d.ts` 中 `AtomicFile` 类、构造器、`startWrite()` 均标注 `@since 15`；`startWrite()` 的异常列表没有 13900020。`statSync()` 的异常列表将 13900002 标为 `No such file or directory`；本机声明未找到 `createWriteStreamSync`。
- 你之前的答复称 `AtomicFile` 自 API 9 起、父目录必须预先存在且可写、`AtomicFile` 不做路径规范化、跨路径实例无须串行化，并建议 `createWriteStreamSync`、把 `statSync` 的 13900015 当作文件不存在以及直接写文件做对照。答复没有附来源，且部分说法与上述本机 SDK 声明冲突。

## 请只核实有来源支持的内容

请针对每项提供可访问的 HarmonyOS 官方文档 URL、文档标题/章节和适用 API 版本；若没有资料，请明确写“未记载”或“无法确认”，不要用推断补齐：

1. `fileIo.AtomicFile` 与 `startWrite()` 的官方最低 API 版本是什么？如何解释 API 26 SDK 的 `@since 15` 与你所称 API 9 的冲突？
2. `startWrite()` 是否有官方资料说明何种条件会导致 13900020？若没有，请确认根因未记载。
3. 父目录存在/可写、路径规范化、嵌套目录、文件名限制、目标文件状态、同路径或不同路径并发方面，官方资料分别明确保证了什么？没有记载的项目请标明未记载。
4. API 24 的 SDK 声明或官方文档是否能证明 `AtomicFile` 和 `startWrite()` 可用，并给出对应异常列表？没有 API 24 来源时不要用 API 26 模拟器结果替代。
5. 请确认 `createWriteStreamSync` 是否是 HarmonyOS 公开 API，并给出声明位置；`statSync()` 的文件不存在错误码究竟是什么？不得把其他方法的错误码说明套用过来。
6. 若存在官方支持且 API 24 可用的无副作用诊断步骤，请给出精确 API 名称、签名、版本与错误码。不要建议对工作区目标使用普通 stream/open/unlink 来替代或绕过 `AtomicFile`。

## 回答要求

- 将每项标为：官方资料明确说明 / 本机 SDK 声明 / 文档未记载 / 推断。
- 仅在有来源时使用“官方明确说明”等确定表述，并提供直接链接。
- 不提供未核实的接口名、路径限制、4096 字符上限或跨 API 版本兼容保证。
- 若无法找到出处，请直接说明；不要重复无来源的结论。
