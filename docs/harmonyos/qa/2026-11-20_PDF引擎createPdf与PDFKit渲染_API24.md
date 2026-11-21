# PDF 引擎 createPdf 与 PDF Kit 渲染官方核实（2026-11-20）

> 背景：v1.94 立项「PDF 导出改用 ArkWeb 官方引擎」（需求池 AH-01），落码完成后、真机验收前，
> 就 print 管线行为与 PDF Kit 渲染的 API 24 边界向鸿蒙官方 Agent 核实。
> 环境：ArkTS Stage 模型；DevEco Studio API 26 SDK 编译，`compatibleSdkVersion 6.1.1(24)`；
> 真机 HUAWEI Mate XT 非凡大师（三折叠，系统 API 24）。ArkWeb 加载本地 rawfile HTML 渲染
> Markdown 预览，选定 `WebviewController.createPdf()`（@since 14）生成 PDF + PDF Kit 预览。
>
> 本轮为**第二轮追问**：第一轮（同日早些时候）问的是 PDF Kit 总体能力（`@kit.PDFKit` 导入、
> `pdfService.loadDocument`、`PdfView` 预览、ArkWeb `createPdf` 用于分享），答复即本仓库
> v1.94 需求文档立项依据；本轮追问聚焦六个拿不准的行为点。防编造约束：只答有官方文档或
> SDK 声明依据的内容，查不到答「未记载」，区分 API 24 与更高版本。

## 问了什么（6 问，含关键限定条件）

1. **print 媒体查询**：createPdf 走 Chromium print 管线时页面内 `@media print` CSS 是否生效？
   视口应用布局（`body{height:100%; overflow:hidden}` + `#content{overflow-y:auto}`）在
   print 下是否会被当作只有一屏、内容截断为第一页？
2. **遮挡场景可用性**：Web 组件仍在组件树内、但被父级不透明容器完全遮住（未卸载、未
   `visibility(Hidden)`）时，createPdf 能否生成完整内容？官方对遮挡/隐藏状态下调用有无限制或已知问题？
3. **产物形态与配置**：createPdf 产物是否为矢量 PDF（含文本对象、可选中可搜索）？
   `PdfConfiguration` 的 width/height 单位（英寸）、页边距范围 [0, 半页高/宽)、scale [0.0, 2.0]、
   `shouldPrintBackground` 默认 false，在 API 24 上是否与 API 26 一致？有无页数/内容长度/耗时上限或超时行为？
4. **PDF Kit 渲染（API 24）**：`pdfService.loadDocument`（since 12）+
   `PdfPage.getAreaPixelMap(matrix, bitmapWidth, bitmapHeight, isGray, drawAnnotations)` 在
   API 24 是否可用？`getPixelMapWithPages` 是否 API 26 起才有？`PdfPage.render` 与
   `getAreaPixelMap` 在 API 24 的可用性分别如何？
5. **`position:fixed` 元素**在 createPdf 产物中的表现：每页重复、仅出现一次还是被裁掉？官方是否记载？
6. **错误码**：createPdf 与 PDF Kit 加载/渲染在 API 24 的常见错误码及含义、触发条件。

## 官方怎么答（要点）

1. **print 媒体查询**：✅ `@media print` 生效有官方记载——官方指南《使用Web组件保存前端页面为PDF》
   明确推荐「通过 CSS 媒体查询（@media print）优化 PDF 排版」。⚠️ 视口布局是否截断为第一页
   **未记载**，建议在 `@media print` 显式重置 `body{height:auto; overflow:visible}`
   `#content{overflow:visible}` 并真机验证。
2. **遮挡场景**：❓ 官方对 createPdf 的前提仅要求「Web 组件已加载且网页内容渲染完成」，
   **未记载**遮挡/隐藏状态下的限制或已知问题，不确定遮挡是否影响产物完整性，建议真机验证。
3. **产物形态与配置**：✅ `PdfConfiguration` 参数（英寸、96px/英寸、scale 越界钳制、边距越界置 0、
   `shouldPrintBackground` 默认 false）官方有记载，未标注 API 24 与 26 差异，可视为一致。
   ❓ 产物是否矢量（可选中可搜索）**未记载**。❓ 页数/内容长度/耗时上限**未记载**。
4. **PDF Kit 渲染**：✅ `loadDocument` 起始 5.0.0(12)，API 24 可用。✅ `getAreaPixelMap` 为常规
   页面转图接口（早于 API 18 的 WithOptions 变体即已存在），API 24 可用。✅ `getPixelMapWithPages`
   起始 **26.0.0(26)**，API 24 **不可用**（多页合并转图为 26 新增）。❌ `PdfPage.render`
   官方 API 中**未找到该方法**，勿在 API 24 使用。
5. **`position:fixed`**：❓ 每页重复/仅一次/被裁掉**均未记载**，需真机验证。
6. **错误码**：✅ createPdf（ArkWeb）：401 参数校验失败、17100001 WebviewController 未与
   Web 组件绑定。✅ PDF Kit：1011301001（pageIndices 与 matrices 长度不匹配）、1011301002
   （无效页码）、1011301003（bitmap 像素数超上限，减小宽高）、1011301004（创建 bitmap 失败，
   资源不足）、1011301005（bitmap 渲染失败，文档不完整）、1011301006（文档未加载，重新
   loadDocument）。⚠️ 答复自注：1011301001~1011301003 与 API 26 的 `getPixelMapWithPages`
   关联；1011301004~1011301006 为 PDF Kit 通用错误码。

落地建议（答复附带）：API 24 多页合并渲染不可用，预览需逐页 `getAreaPixelMap` 或用 `PdfView`
组件（since 12）；对三个「未记载」点（视口截断、遮挡、fixed）在真机小样验证后再固化方案。

## 本机 SDK 复核补记（2026-11-20，API 26 SDK `hms/ets/api/@hms.officeservice.pdfservice.d.ts`）

- ✅ `getAreaPixelMap(matrix, bitmapwidth, bitmapHeight, isGray, drawAnnotations): image.PixelMap`
  —— **@since 5.0.0(12)**（约 :2555），API 24 可用，与答复一致。
- ✅ `getAreaPixelMapWithOptions(matrix, w, h, options?: PixelOptions)` —— **@since 5.1.0(18)**
  （约 :2571）；`PixelOptions` class 同 @since 5.1.0(18)。答复只提了「WithOptions 变体」未给版本，此处补齐。
- ✅ `getPagePixelMap(): image.PixelMap` —— @since 5.0.0(12)（整页转图，无需 matrix）。
- ✅ `getPixelMapWithPages(...)` —— **@since 26.0.0**（约 :1100），API 24 不可用，与答复一致。
- ✅ `loadDocument(path, password?, onProgress?): ParseResult` —— @since 5.0.0(12)（:670）；
  `getPage(index): PdfPage` —— @since 5.0.0(12)（:750）。
- ✅ 全文件**无 `render` 方法**——官方答复正确；v1.94 需求文档 §3.4 提到的「PDF Kit
  `PdfPage.render()`」是错误提法，实际落地代码（`NotePdfEngineDevice.ets`）用的就是
  `getAreaPixelMap`，无代码影响。

## 对 v1.94 的影响

- **零返工**：v1.94 落码与官方口径完全一致（`@media print` 显式重置视口约束 ✅ 已做、
  预览用 `getAreaPixelMap` 逐页渲染 ✅ 已做、未用 `getPixelMapWithPages` / `render` ✅）。
- 三个「未记载」点（视口截断、遮挡、`position:fixed`）即 v1.94 §2 已列的真机验收项，
  无需新增代码；真机验收结果回填 `api_notes.md` AD 组与 v1.94 §7。
- 水印 print 形态：v1.94 取「整篇末尾一次」（`position: static`），与 fixed 未记载风险无关，
  维持现状。
