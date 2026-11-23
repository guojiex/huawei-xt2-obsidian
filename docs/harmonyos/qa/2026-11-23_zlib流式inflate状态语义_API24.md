# zlib 流式 inflate 状态语义与逐条目解压能力（API 24，2026-11-23 官方答复）

> 本机环境：DevEco Studio 6.0（Windows），compatibleSdkVersion 6.1.1(24)，`@ohos.zlib`（`@kit.BasicServicesKit`）。
> 验证设备：华为 XT2 三折叠真机（API 24 固件）与 x86_64 模拟器（API 26）。
> 结论真源：[api_notes Y4 2026-11-23 补记](../api_notes.md#y4--未核实边界实现期单测--设备验收补齐)。
> 来源性质：官方 Agent 答复（用户转贴带回；提问带环境声明与防编造约束，凡文档查不到依据的一律答「未记载」）。
> 背景：Y4 两条踩坑（2026-11-17 模拟器 `getZStream` 修复通过 → 2026-11-18 XT2 真机复验失败 → availableOut 检查整体移除）之后，向官方求证「用法是否不对、是否有我们漏掉的官方逐条目解压能力」。

## 问（五问）

1. `inflateInit2(-15)` + 循环 `inflate(NO_FLUSH)` + 以 `STREAM_END` 为终态的用法是否为官方预期用法？是否有文档未覆盖的必做步骤？
2. `zip.inflate()` 之后传入的 `ZStream` 是否保证原地更新？`getZStream()` 是否唯一权威状态读取方式？API 24 真机与 API 26 模拟器上其返回语义是否一致、有无已知缺陷？
3. API ≤ 24 下除 `zlib.decompressFile`（整包）外，是否存在官方逐条目 / 带进度 / 可取消的 ZIP 解压能力（任何 Kit、任何模块）？
4. 错误码 17800004 / 17800005 的确切触发条件？
5. `decompressFile` 解压前是否校验条目 CRC？对加密 ZIP、路径穿越（`../`）、symlink 条目在 API 24 的实际行为？

## 答（官方，要点）

1. **用法基本正确**。官方《压缩与解压》指南的 inflate 示例在**每次 `zip.inflate()` 之后都 `getZStream()` 并把 `availableIn/nextIn/availableOut/nextOut/totalIn/totalOut` 逐字段拷回调用方 strm**，再依 `availableOut` 判断输出是否写满、依 `STREAM_END` 决定是否继续——即指南把 `getZStream()` 作为必做步骤。`windowBits`：zlib 格式 [8,15]、gzip [24,31]、**raw deflate [-15,-8]**，-15 合法且为标准取值。指南未要求特定 flush 值（示例解压侧即 NO_FLUSH）、未强制分段（官方示例按 4096 字节分段，属缓冲区策略）。
2. 原地更新语义文档**未以「保证/不保证」措辞声明**；指南写法实际上把 `getZStream()` 作为权威状态读取途径。**API 24 真机与 API 26 模拟器上 `getZStream()` 返回语义差异、已知缺陷——未记载**；建议经开发者工单渠道反馈核实。官方 FAQ 另有一处直接在 deflate 后读传入 `zStream.totalOut` 的示例，与指南不一致，以指南写法为准。
3. **API ≤ 24 不存在官方逐条目 / 可取消的 ZIP 解压接口**。带进度回调的 `OH_Archive_*`（Core File Kit C API，oh_archive.h，`OH_Archive_Reader_SetProgressHandlerWithData`）**起始版本 26.0.0** 且为整包 `ExtractAllFile`，两条路都堵死。官方对「安全解压不可信 ZIP」无专门安全规范；官方能力边界 = `decompressFile` 整包 + 流式 inflate 指南。**「自行解析容器 + 逐条目流式 inflate + 自行 CRC32 校验」被确认为 API 24 约束下与官方能力对齐的合理做法。**
4. `17800004`（压缩/解压流错误）：未先 `inflateInit/deflateInit` 就调流式接口、gz 系接口刷新模式 / 访问模式错误等；`inflateInit2` 错误码表也列有它。`17800005`（传入数据错误）：数据不符合压缩格式 / 已损坏 / 未压缩（描述针对 uncompress 系）。
5. `decompressFile`：路径穿越有记载——API 13 起 inFile/outFile 含 `../` 抛 900001/900002，**压缩包内条目名含 `../` 抛 900003**；6.0.0(20) Beta2 起格式有误的包改为解压失败抛格式错误码。**解压前是否校验条目 CRC：未记载；加密 ZIP 行为：未记载；symlink 条目行为：未记载。**

## 与本项目现状对齐

- **用法没有错**：`ZipImportDevice.ets` 的 `inflateInit2(-15)` + NO_FLUSH 循环 + `STREAM_END` 终态与官方指南一致；官方确认 -15 为 raw deflate 标准取值。
- **2026-11-18 的拍板与官方建议吻合**：官方对 `getZStream()` 跨设备差异答「未记载」并建议工单核实；同时明确兜底姿势 =「以已验证正确的输出长度 + CRC32 校验为准，`getZStream()` 仅作辅助信息」。本项目设备层已完全不依赖 `getZStream()`（只留 `STREAM_END` 终态），服务层 `ZipImportService.extract` 长度 + CRC32 双重权威校验——即官方建议形态，**零代码改动**。
- **自绘路线被官方背书**：API ≤ 24 无逐条目 / 可取消官方解压能力，本项目「自绘容器解析 + 逐条目流式 inflate + 自行 CRC32」为合理做法；v1.36 选型无需回炉。
- 遗留动作：XT2 真机 `getZStream()` 行为差异属「文档未记载」，如需根因可提开发者工单（非阻断，本项目已不依赖该调用）。
