# Share Kit 与本地打包 API 核对（API 24）

> 这是官方开发文档与本机 SDK 类型声明核对，不是向官方 Agent 发起的新问答。
> 本机 HarmonyOS SDK：`/Applications/DevEco-Studio.app/Contents/sdk/default`，版本 `26.0.0.105`；工程兼容 API 为 `6.1.1(24)`。因此这里记录的是 API 起始版本与签名证据，不代表 API 24 或 XT2 运行验收。

## 1. 系统分享面板

- 本机 `hms/ets/kits/@kit.ShareKit.d.ts` 将 `@kit.ShareKit` 标为 since `4.1.0(11)`；`hms/ets/api/@hms.collaboration.systemShare.d.ts` 将 `SharedData`、`SharedRecord`、`ShareController` 及 `show(context, options)` 标为 since `4.1.0(11)`。
- `ShareController.show(context: common.UIAbilityContext, options: ShareControllerOptions): Promise<void>`；官方文本分享示例使用 `SharedData({ utd: utd.UniformDataType.TEXT, content: ... })`，视频分享示例使用文件 URI 构造记录并 `show()` 面板。
- 同一 SDK 声明中 `ShareController.on/off('dismiss', callback)` 标注 since 4.1.0(11)，文档描述为监听分享面板关闭；`on/off('shareCompleted', callback)` 标注 since 5.1.0(18)，文档描述为用户完成分享后返回所用分享渠道，可用于数据统计（`systemShare.d.ts` 的 `on` / `off` 声明及事件注释）。这两个事件不提供接收方已读或已收到内容的证据。
- 官方文档：[分享文本](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/share-utd-text)、[分享视频](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/share-utd-video-V5)。
- `SharedRecord.uri` 注释说明接受 App file URI 与 user file URI。声明未描述接收方授权发放和撤销的时机、事件与授权生命周期的关系，也未说明 `show()` Promise resolve 对应面板显示还是面板关闭；这些必须留作正常系统交接运行验证。
- `@ohos.fileshare` 的持久化授权是另一套 API：本机声明其接口 since 11 且要求 `ohos.permission.FILE_ACCESS_PERSIST`。当前无证据要求给一次性 Share Kit 交接额外申请该权限。

## 2. 沙箱路径 URI

- 本机 `openharmony/ets/api/@ohos.file.fileuri.d.ts` 声明 `fileUri.getUriFromPath(path: string): string` since 9。
- 官方视频分享示例明确把沙箱文件路径交给 `fileUri.getUriFromPath()`，再将 URI 放进 Share Kit 的文件记录。
- 拼接路径仍必须从 Context 属性取根并经本项目统一解析层；不能把 API 示例中的沙箱路径字面量照搬进业务代码。

## 3. ZIP 压缩

- 本机 `openharmony/ets/api/@ohos.zlib.d.ts` 声明 `compressFile(inFile, outFile, options)` since 9；输入可为应用沙箱内的文件或目录。
- `compressFiles(inFiles, outFile, options)` since 12。
- `Options.keepTopLevelFolder` since 26，API 24 路径不得读取或设置该属性。打包器应将需要导出的路径先拷入临时根目录，再压缩该目录；解压产物必须实际检查文件集合和相对路径，不把压缩声明等同于 ZIP 结构已验收。

## 4. 未核实边界

- 分享对象中的 App file URI 是否由系统面板授予接收方可读权限、该权限的生命周期，以及面板关闭或 `shareCompleted` 与授权撤销 / 安全清理临时文件之间的关系。
- `ShareController.show()` 的 Promise resolve 时机和安全清理临时文件的具体时点。
- 当前 ArkWeb Markdown 预览输出全文分图的接口、像素限制与目标应用文件大小限制。Share Kit 支持分享图片 URI 并不证明该预览转图片链路已存在。
- API 24 / XT2 和微信、飞书接收均未运行验证。不得把构造 `SharedData` 成功或面板调起成功写成接收成功。
