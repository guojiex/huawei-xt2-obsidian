# API 24/26 AtomicFile.startWrite() 用法答复（2026-10-22）

## 来源与核验边界

本记录整理用户带回的 HarmonyOS 开发答复，回应 [`AtomicFile.startWrite() 正确用法提示词`](../prompts/2026-10-21_API24_AtomicFile_startWrite_正确用法与失败处理.md)。答复称依据《@ohos.file.fs（文件管理）》及文件管理错误码，包含 1–10 的脚注编号，但粘贴内容没有附逐项直链或工单编号。以下保留其结论，并与本机 API 26 SDK 声明交叉核对；未能独立确认的细节仍标明来源边界。

工程 `compatibleSdkVersion` 为 `6.1.1(24)`。本机 DevEco Studio `26.0.0.851`，HarmonyOS SDK `26.0.0.105`。13900020 故障目前只在 Huawei_TripleFold API 26 arm64 模拟器的非空 Git clone 集成路径复现；API 24 运行时和 XT2 真机尚未测试。

## 答复要点

| 问题 | 用户带回答复 | 核验与边界 |
| --- | --- | --- |
| 正常写入流程 | `startWrite()` 获取 `WriteStream`；调用 `write()`；回调成功时 `finishWrite()`，失败时 `failWrite()`；目标不存在时会创建。 | 与本机 API 26 `@ohos.file.fs.d.ts` 对 `startWrite()`、`finishWrite()`、`failWrite()` 的声明语义一致。AtomicFile / `startWrite()` 均为 API 15+。 |
| `startWrite()` 同步抛错后的处理 | 答复称官方 `failWrite()` 示例在 `try/catch` 的 `catch` 调同一实例的 `failWrite()`，覆盖 `startWrite()` / `write()` 的同步异常。 | 按用户带回的官方答复记录为推荐处理；粘贴文本没有给出示例的精确 URL。`failWrite()` 本身可能抛错，工程中调用时仍应捕获清理异常并保留原始错误。 |
| 是否关闭流 | AtomicFile 示例不对 `startWrite()` 返回的 `WriteStream` 显式 `close()`；写入会话用 `finishWrite()` / `failWrite()` 收尾。 | 本机 SDK 中 `WriteStream` 继承 `stream.Writable`；AtomicFile 方法声明没有要求调用者关闭 startWrite 返回的流。内部是否具体负责关闭，答复也标为未逐字记载。仓库已有 `close()` 后 `finishWrite()` 导致 native SIGSEGV 的实测，继续禁止此用法。 |
| 实例复用、重试、并发 | 官方文档未记载写入失败后的实例复用、重试策略或并发保证。 | 保持未确认，不据此设计重试或并发语义。 |
| `delete()` 的用途 | 答复指出 `delete()` 删除原始文件和临时文件，官方未把它列为失败后的标准回滚步骤。 | 本机 SDK 声明也写明删除 AtomicFile 对应的原始文件和临时文件；不要用它替代失败回滚，以免删除已有的有效笔记。 |
| 错误码 13900020 | 通用文件管理错误码含义为 “Invalid argument”；方法文档引用基础文件 IO 错误码，SDK `@throws` 列表不是穷尽运行时所有错误码；具体触发条件及内部映射未记载。 | 本机 API 26 SDK 的 `startWrite()` 异常列表没有 13900020。错误码的通用名称不定位本次 `startWrite()` 的具体内部操作；根因仍未知。 |

## 本机 SDK 交叉核对

- SDK 包：`/Applications/DevEco-Studio.app/Contents/sdk/default/sdk-pkg.json`，HarmonyOS `26.0.0.105`。
- 声明文件：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/api/@ohos.file.fs.d.ts`。`AtomicFile`、构造器及 `startWrite()` 标注 `@since 15`；`startWrite()` 异常声明列 13900001、13900002、13900012、13900027、13900042，没有列 13900020。
- `failWrite()` 声明为回滚写入失败后的文件，异常列表含 13900042；`delete()` 声明会删除 AtomicFile 对应的原始文件和临时文件。
- `WriteStream` 继承本机 `@ohos.util.stream.d.ts` 中的 `stream.Writable`。具体写入方法签名应以对应 SDK 声明为准，不把答复示例未经构建验证地复制到生产代码。

## 对工程的影响

- 正常流程和同步异常的清理方式现有 `NoteService.runAtomicSave()` 已用 `finishWrite()` / `failWrite()`，并对 `failWrite()` 清理异常作了保护；不需要因本答复增加新的抽象。
- API 26 模拟器非空 clone 的 13900020 根因仍未解决。父目录写权限检查通过不代表 AtomicFile 写入成功；不将错误归因于超长文件名、特殊字符、临时文件后缀或模拟器差异。
- 不把笔记内容、令牌或真实沙箱路径发给支持渠道。若需要提供路径证据，先使用脱敏路径形态与长度信息。

## 官方资料链接

- [@ohos.file.fs（文件管理）— AtomicFile](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs#atomicfile15)
- [startWrite()](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs#startwrite15)
- [finishWrite()](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs#finishwrite15)
- [failWrite()](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs#failwrite15)
- [文件管理错误码 13900020](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/errorcode-filemanagement#section13900020-无效的参数)
