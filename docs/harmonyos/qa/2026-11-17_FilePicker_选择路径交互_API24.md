# FilePicker「选择路径」交互与真机/模拟器形态差异（2026-11-17，API24）

> 背景：v1.5「导入本地目录」链路（`DocumentViewPicker` FOLDER 模式）在 XT2 真机上被用户反馈「钻到最深层子目录也没有确认按钮」。hdc 抓屏实测发现真机 Picker 是「选择路径」独立页（确认入口在右上角对勾），与本机 x86_64 模拟器的「我的手机」弹窗形态完全不同。就 3 问求证官方。答复为官方 Agent 文档型回答（用户转交，见下方逐条），关键声明已用本机 API 26 SDK 复核。

## 问了什么（可复现粒度）

环境：DevEco Studio，compileSdkVersion API 24（`compatibleSdkVersion 6.1.1(24)`）；运行设备 Mate XT2 三折叠真机（LAP-AL10，系统 API 26），对照本机 x86_64 模拟器。Stage 模型 ArkTS 应用。

场景：应用通过 `@kit.CoreFileKit` 的 `picker.DocumentViewPicker.select()` 拉起 FOLDER 模式目录选择器（`documentSelectMode: picker.DocumentSelectMode.FOLDER`，`maxSelectNumber: 1`），选择沙箱外用户目录。

真机（XT2）实测观察（hdc `snapshot_display` 抓屏，2026-11-17）：

1. 选择器为独立页面，标题「选择路径」，左上角 X 关闭，右上角两图标：新建文件夹、对勾；确认选择的入口是右上角对勾图标，页面没有任何底部确认按钮。
2. 点击文件夹所在行会将该行高亮选中（底部提示「已选中 xxx · 仅可访问所选项目」）；点击行尾箭头则是展开子目录，展开不等于选中。
3. 本机 x86_64 模拟器上同一 API 拉起的却是弹窗形态（标题「我的手机」），UI 与真机完全不同。

提问：

1. FOLDER 模式下真机「选择路径」页面的这套交互（行点击选中 + 右上角对勾确认、无底部按钮）在官方文档里是否有记载？对应哪份文档？
2. 真机与模拟器的 FilePicker UI 形态不一致（独立页面 vs 弹窗）是什么原因？是否与设备形态（折叠屏/大屏）或系统版本有关？
3. `DocumentViewPicker` 的 `select()` 或相关接口有没有参数可以影响选择器 UI 形态（如弹窗/页面、单选/多选呈现）？如果没有，是否存在其他受支持的定制方式？

末尾防编造约束：每个问题以官方文档或 SDK 声明为依据回答，查不到的条目直接回答「未记载」，不要猜测接口名或参数名；如结论出自某份文档请给出文档名称或路径。

## 官方逐条答复

### 1. 「选择路径」交互细节是否有官方文档记载

**未记载。** 官方文档体系中与 DocumentViewPicker 相关的只有两类：

- API 参考：《@ohos.file.picker (选择器)》（路径：应用框架/Core File Kit（文件基础服务）/ArkTS API），其中 `DocumentSelectOptions` 仅描述参数语义（如 `maxSelectNumber` 在 API 20 及之前目录选择「单次最多可选择 1 个目录」、API 23 起取消目录选择数量限制、Phone 设备不支持目录多选等），`DocumentSelectMode.FOLDER` 仅说明「文件夹类型」，`select()` 仅说明「通过选择模式拉起 documentPicker 界面」。
- 开发指南：《选择用户文件》（路径：应用框架/Core File Kit（文件基础服务）/用户文件/选择与保存用户文件），只给出调用代码与 URI 使用方式。

「行点击选中 + 行尾箭头展开、右上角对勾确认、无底部确认按钮、『仅可访问所选项目』提示」等具体交互细节，属于系统 FilePicker 应用自身的 UI 实现，官方文档没有任何一份记载这套交互规范。FilePicker 是系统应用，其界面由系统侧自行演进，文档不对其 UI 做承诺。

### 2. 真机与模拟器 UI 形态不一致的原因

官方文档**未记载** FilePicker 在「独立页面 vs 弹窗」这一形态差异上的具体原因，也没有记载「折叠屏/大屏会导致 FilePicker 呈现弹窗形态」的规则。可以确认的相关事实依据：

- 官方明确承认模拟器与真机存在能力与表现差异，Core File Kit 文档专门列有「模拟器支持情况」章节并要求参考《模拟器与真机的差异》。
- 真机系统为 API 26，而工程 compileSdkVersion 为 API 24；FilePicker 界面由设备上预装的系统 FilePicker 应用渲染，系统版本不同，Picker 应用版本与 UI 也可能不同。模拟器上呈现的弹窗形态是模拟器环境内 FilePicker 的实现表现，官方未将其定义为规范形态。

结论：形态差异属于系统侧 FilePicker 实现差异（与设备环境、系统版本相关），官方文档未记载具体成因，也不保证模拟器与真机 Picker UI 一致。**涉及 Picker 的界面验证，应以真机为准。**

### 3. select() 是否有参数可以控制 UI 形态

**没有。** `DocumentSelectOptions` 的全部字段为：`maxSelectNumber`、`defaultFilePathUri`、`fileSuffixFilters`、`selectMode`、`authMode`（仅 2in1 设备生效）、`multiAuthMode` / `multiUriArray`（仅 Phone 生效，且仅支持文件授权）、`mergeMode`（拉起文件管理应用聚合视图，仅 Phone 生效）、`isEncryptionSupported`（仅文件生效）、`allowsMulFolderSelection`（API 26 起，配合 `selectMode` 为 FOLDER/MIXED 时支持多选文件夹）。其中没有任何控制「弹窗/页面」呈现形态的参数，`select()` 本身也只接收这一个选项对象。

其他受支持的「定制」途径也不存在——FilePicker 是系统应用，开发者无法自定义其 UI。能力上最接近的可配置项只有：

- `allowsMulFolderSelection`（API 26 起）：影响目录单选/多选的行为，但不改变 UI 形态；
- `mergeMode`：拉起文件管理应用的聚合视图，属于另一种系统界面，仍非自定义 UI；
- 若是在 ArkWeb 的 Web 组件场景，可通过 `onShowFileSelector` 回调拦截文件选择请求，自行构建选择界面后再把结果返回给 Web——这是目前官方文档中唯一记载的「自定义文件选择界面」途径，但不适用于普通应用页面。

### 补充说明（答复附带）

- `maxSelectNumber: 1` 配置在 FOLDER 模式下与系统行为一致：API 20 及之前目录选择本就限制单次最多 1 个目录；若升级到 API 26 SDK，还可通过 `allowsMulFolderSelection` 显式控制是否允许目录多选。
- Picker 返回的 URI 为临时授权，退出应用后台后失效；如需持久化访问所选目录，需参考官方「文件持久化授权访问」相关指导申请持久化权限。
- 建议在应用内对 Picker 交互做引导文案时，不要假设固定形态（如「点击底部确认按钮」），以兼容不同设备/系统版本上 FilePicker 的 UI 差异。

## 本机 SDK 复核（API 26，`sdk/default/openharmony/ets/api/@ohos.file.picker.d.ts`）

| 声明 | 位置 | 结果 |
| --- | --- | --- |
| `defaultFilePathUri?: string` | L430 | ✅ `@since 10` |
| `fileSuffixFilters?: Array<string>` | L451 | ✅ `@since 10` |
| `maxSelectNumber?: number` | L471 | ✅ `@since 10`；注释含「API 20 及之前目录单次最多 1 个」（L455-457） |
| `selectMode?: DocumentSelectMode` | L480 | ✅ `@since 11`，syscap `FileManagement.UserFileService.FolderSelection` |
| `authMode?: boolean` | L497 | ✅ `@since 12`；注释「used on 2-in-1 devices but has no effect on other devices」 |
| `multiAuthMode?: boolean` | L511 | ✅ `@since 15`；仅 smartphones |
| `multiUriArray?: Array<string>` | L523 | ✅ `@since 15`；仅 smartphones、only files |
| `mergeMode?: MergeTypeMode` | L535 | ✅ `@since 15`；仅 smartphones |
| `isEncryptionSupported?: boolean` | L544 | ✅ `@since 19`；only files |
| `allowsMulFolderSelection?: boolean` | L554 | ⚠️ `@since 26.0.0`；**d.ts 注释写「Only 2-in-1 devices are supported」，官方答复未提该设备限制**（答复与 SDK 错位的又一例，此前 4 次见 T 组）。超出 API 24，本工程不可用，仅备档 |

字段清单与答复一致：`DocumentSelectOptions` **确无任何控制 UI 形态的参数** ✅。

## XT2 真机实测（2026-11-17，hdc `snapshot_display` 抓屏）

- 「选择路径」页：左上 X 关闭；右上从左到右＝新建文件夹、**对勾（＝确认）**；无底部确认按钮。
- 点文件夹行＝选中：行浅蓝高亮，底部提示「已选中 obisidian-vault」，最底部盾牌小字「仅可访问所选项目」。
- 点行尾箭头＝展开子目录，展开不改变选中态。
- 用户体感「钻到最深层子目录也没有确认按钮」的原因：确认入口**始终在右上角**，钻层级不会触发任何底部按钮——非缺陷，是系统 Picker 的交互设计。

## 模拟器补充实测（2026-11-17 晚，x86_64 模拟器 127.0.0.1:5555，`uitest dumpLayout` 全量节点树）

用户反馈模拟器上同样无法选目录。对 FOLDER 模式拉起的「我的手机」弹窗做了 UI 节点树 dump（313 节点）并逐区域裁图放大识别：

- 弹窗为 UIExtension `SheetWrapper` / `SheetPage` 形态，标题「我的手机」，面包屑「我的手机 > Documents > sample_vau...」。
- 标题栏右侧仅两个可点控件：**视图切换图标 + 关闭 ×**（裁图放大识别确认）；**没有对勾确认、没有新建文件夹**——与 XT2 真机「选择路径」页（新建文件夹 + 对勾）不同构。
- 文件夹行尾是**向右导航箭头**（点击进入下一层），不是选择圆圈/勾选框。
- **全树 313 节点中没有任何 `checkable` 节点、没有任何「选择/确定/完成」按钮**（dump 里的「选择」Text 是应用自身 ImportVaultDialog 的按钮，非 Picker 控件）。

结论：**本机 x86_64 模拟器的 FilePicker 没有实现「选中目录」控件，FOLDER 模式选目录流程在模拟器上无法完成**——用户钻到最深层也没有确认按钮不是操作问题，是该环境 FilePicker 缺少选择 UI。与官方答复「模拟器 Picker 为环境自身实现、界面验证以真机为准」口径一致。本地文档库未检出把这条列为模拟器限制的明文记载（Core File Kit「模拟器支持情况」章节未收录该条目）。

## 结论标记

| 条目 | 标记 |
| --- | --- |
| 「选择路径」交互细节官方未记载（FilePicker 系统应用自身 UI，文档不承诺） | ❓（以真机实测值为准） |
| 真机/模拟器形态差异成因未记载；Picker UI 由设备预装系统应用渲染、以真机为准 | ⚠️（机制方向明确 + 官方承认模拟器差异存在，具体成因无记载） |
| `DocumentSelectOptions` 无控制 UI 形态的参数；字段清单 | ✅（官方 API 参考 + 本机 SDK 双向核实） |
| `allowsMulFolderSelection` since 26.0.0、d.ts 注释限 2in1 | ✅ 记载存在；⚠️ 答复漏提 2in1 限制；API 24 不可用 |
| XT2 真机「选择路径」交互实测值 | ✅（实测，高于官方答复） |
| 模拟器 FilePicker 无「选中目录」控件，FOLDER 选目录在 x86_64 模拟器无法完成 | ✅（uitest 节点树 + 裁图识别实测；官方文档未明文记载该限制） |
