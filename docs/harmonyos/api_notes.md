# HarmonyOS API 核实笔记（API 24）

> 📌 本文件是**所有鸿蒙行为结论的单一真源**，维护规则见 [`README.md`](README.md)：
> 提问前先查这里；结论只准链接不准复制；被推翻的加删除线保留；真机验证后把 ⚠️/❓ 改成 ✅ 并写实测值。
>
> **来源**：华为官方 AI 助手对本工程 [`prompts/2026-10-17_首批提问_API24.md`](prompts/2026-10-17_首批提问_API24.md) 的答复（2026-10-17）
> （已问过什么见 [`qa/2026-10-17_首批回答_API24.md`](qa/2026-10-17_首批回答_API24.md)）。
> 本机版本：`compatibleSdkVersion 6.1.1(24)` = **API 24**，`targetSdkVersion 26.0.0`。
>
> **可信度标记**（落码前必看）：
> ✅ 官方接口/文档明确记载，可直接落码
> ⚠️ 对方基于文档机制**推断**，务必真机验证
> ❓ 官方文档未记载（对方已诚实标注"不确定"），不要押宝
>
> **总原则：凡标 ⚠️ / ❓ 的，在真机验证前不许写进关键路径。** 已据此调整了 MVP 的验证顺序。

---

## A 组：三折叠形态与折痕

### A1 折叠状态 ✅（三屏态返回值 ❓）

```typescript
import { display } from '@kit.ArkUI';

display.isFoldable(): boolean          // 是否可折叠
display.getFoldStatus(): display.FoldStatus
display.on('foldStatusChange', cb) / off
display.on('foldAngleChange', cb: Callback<Array<number>>)  // 三折叠返回【两个】角度，从右到左为折轴一、折轴二
```

`FoldStatus` 枚举：`UNKNOWN=0` / `EXPANDED=1` / `FOLDED=2` / `HALF_FOLDED=3`。

**对三折叠的语义**：`EXPANDED` = 折轴一完全展开、折轴二折叠（即**双屏态**）；`FOLDED` = 两轴均折叠（**单屏态**）。

> ⚠️ **三屏全展开（G 态）时 `getFoldStatus()` 返回什么，官方文档未记载** —— 枚举里只有 4 个值，看不出哪个对应 G 态。
> 三折叠共有 9 种折叠状态，常用的只有单屏(F) / 双屏(M) / 三屏(G) 三态。
> **真机验证方案**：三个形态各打印一次 `getFoldStatus()` 与 `foldAngleChange` 的双角度值，据此建映射表。
> **兜底**：以窗口宽度断点为主、foldStatus 为辅（见 A3）。

### A2 折痕区域 ⚠️ **官方答复已被 SDK 实证推翻（2026-10-17）**

```typescript
// ❌ 官方 Agent 的答复（2026-10-17 首批）：「只返回单个 Rect」
~~display.getCurrentFoldCreaseRegion(): display.Rect~~

// ✅ SDK 类型定义实证（v0.1 落码时查得）：返回结构体，折痕是【数组】
display.getCurrentFoldCreaseRegion(): display.FoldCreaseRegion
// FoldCreaseRegion { displayId: number, creaseRects: Array<Rect> }
```

**结论修正**：折痕是 **`creaseRects` 数组**，不是单个 Rect —— 这意味着三折叠的两条铰链**有可能**一次性全部拿到。
（出处：`docs/releases/v0.1/需求文档.md` §6.1 验收记录；代码见 `EntryAbility.logFoldCalibration()`，它打印的类型就是 `display.FoldCreaseRegion`。）

> ⚠️ 但这**只是类型定义层面的事实**，不等于三折叠运行时真的返回两段 —— 仍属 ❓，**真机打印前不许进布局算式**。
> 教训记一笔：**官方 Agent 的答复也要交叉验证**，能查 SDK 类型定义时优先查 SDK（这次就是靠 SDK 发现答复错了）。

决策不变：本版本**折痕只做日志采集**（`TODO(真机校准)`），布局仍按等分；真机拿到实际 `creaseRects` 后再校准成常量表。

### A2-bis `FoldSplitContainer` 核实结论：**不适用本工程**（2026-10-17 查官方文档确认）

曾把它列为首选方案（悬停态自动避让折痕 + 支持三分栏），查完官方参数表后**否决**。三条硬伤：

**① 它的"三分栏"不是三列横排，是「侧列贯穿 + 另两栏上下堆叠」。**

```
FoldSplitContainer 三分栏实际结构：

+---------------------------+------------------+
|        primary            |                  |
|        （主区）            |      extra       |
+---------------------------+   （扩展区，      |
|        secondary          |    上下贯穿）     |
|        （次区）            |                  |
+---------------------------+------------------+
        ↑ verticalSplitRatio     ↑ horizontalSplitRatio
         控制 primary:secondary     控制 (primary+secondary) : extra
         的【高度】比               的【宽度】比
```

横排的列只有 **2 个**（左半区上下两栏 + 右半区一个贯穿列）。
我们要的是**三块物理屏横向排列 → 文件树 | 编辑器 | 预览 三列横排**，模型对不上。

**② 分栏比例只能用预设枚举，且没有 1:1:1。**

`PresetSplitRatio` 只有三个值：`LAYOUT_1V1`(1:1) / `LAYOUT_3V2`(3:2) / `LAYOUT_2V3`(2:3)。
**不支持任意比例**，做不到各占 1/3。默认值：有 extra 时 `horizontalSplitRatio` 默认 `LAYOUT_3V2`，即右侧列只占 2/5。

**③ 它是为双折叠的「悬停态」设计的。**
核心卖点是悬停态自动避让折痕；三折叠的三屏态（G 态）不在它的模型里。二分栏时只有 `verticalSplitRatio`（**上下**分），连"列表 | 详情"左右分栏都不是它的默认形态。

> 补充事实（与选型无关但有用）：导入路径是 **`import { FoldSplitContainer } from '@kit.ArkUI'`**，
> 不是独立的 advanced 包；配套类型 `ExpandedRegionLayoutOptions` / `HoverModeRegionLayoutOptions` /
> `FoldedRegionLayoutOptions` / `PresetSplitRatio` / `ExtraRegionPosition` 同样从 `@kit.ArkUI` 导入。
> 事件：`onHoverStatusChange`。

→ **决策：三档布局全部自绘**，见 A2 末尾的三条出路之 ②/③。

### 修正后的出路（按推荐顺序）

1. **自绘 + 真机校准**（推荐起步方式）：自绘三档布局，宽度先用等分（50% / 1/3），
   真机打印 `getCurrentFoldCreaseRegion()` 与 `foldAngleChange` 双角度，**校准后写死校准值**。
2. **等分 + 折痕只做标注**：维持 50% / 1/3，折痕不参与决定栏宽。校准前的默认状态。
3. （已否决）~~`FoldSplitContainer`~~ —— 模型与比例都不匹配，见上。

> 官方折痕避让设计标准（悬停态）：上半屏内容由中线**向上避让 16vp**、下半屏**向下避让 40vp**。
> 这条仍有参考价值：三折叠若进入类似的半折悬停姿态，可照此避让。

### A3 断点获取 ✅ —— 现有方案就是官方推荐

`window.on('windowSizeChange')` + `px2vp()` **就是官方推荐做法**，窗口属性里没有直接的 vp 宽度字段。

官方明确建议：**优先用统一断点机制（一次开发多端部署），不要用 `getFoldDisplayMode()` 一类形态接口做分支**（该接口出于兼容考虑不返回全部形态值）。

→ **我们的三档断点（sm/md/lg）方案与官方思路一致，保持不变。**

### A4 折叠切换时 UIAbility ✅ 不重建

窗口尺寸变化走事件通知，`onDestroy`/`onCreate` 由系统调度（销毁、内存回收），**与尺寸变化无关**。
HarmonyOS 的 `module.json5` **不存在**类似 Android `configChanges` 的"排除配置变更"配置项，无需配置。

→ 但仍建议编辑中内容定期落盘或存 `AppStorage`（防内存回收等极端场景）。

### A5 设备类型 ✅

三折叠手机在系统中**始终是 `phone`**，全展开 10 英寸的 G 态也不会变成 tablet / 2in1。
我们的 `deviceTypes: ["phone","tablet","2in1"]` 合适，断点差异靠 `windowSizeChange` 处理。

---

## B 组：Web 组件

### B1 大数据通道 ❓ → 应改用 WebMessagePort

`runJavaScript()` 的脚本长度上限**官方未记载**。但它的返回值是 string，100KB 级文本经它往返有明显序列化开销，**不适合做数据通道**。

官方大数据通道是 **WebMessagePort**：

```typescript
controller.createWebMessagePort()   // 建立双向端口
port.postMessage(...)               // 支持 string、ArrayBuffer
```

→ **通道分工（待落码）**：控制指令走 `runJavaScript` / `javaScriptProxy`；**大文本与 git packfile 走 MessagePort 传 ArrayBuffer**。

> 📌 **二次核实（2026-10-17，见 `qa/2026-10-17_B组追问_Web组件.md` B-3）**：
> `runJavaScript(script: string, callback: (result: string) => void)` —— **参数与返回值的长度上限官方均未记载** ❓。
> 返回值是 JS 表达式的字符串化结果，二进制要先 base64（**膨胀 33%**）。→ 结论不变：packfile 走 MessagePort。

### B2 隐藏的计算型 Web 组件 ⚠️ → **常驻用 `visibility(Hidden)`，不要用 NodeContainer 卸载**

`visibility(Hidden)` / `opacity(0)` 时组件仍在树上、JS 环境保留（反向推断，未逐字记载）。**不建议用 1×1 像素**。

> ❌ **已推翻（2026-10-17）**：~~官方方案是 `NodeController` + `NodeContainer` 动态挂载/卸载~~ —— 二次核实确认
> **NodeContainer 从组件树移除时 Web 组件被销毁、Chromium 实例释放，重新挂载会重新加载页面，JS 状态（变量/闭包/Worker）全丢**（⚠️ 推断，文档未记载"节点缓存/后台保活"）。
>
> ✅ **正确做法**：git 计算容器**常驻**，用 `Stack` + `visibility(Hidden)` 控制可见性而非存在性：
> ```typescript
> Stack() {
>   Web({ src: $rawfile('gitbridge/index.html'), controller: this.controller })
>     .width('100%').height('100%')
>     .visibility(this.webVisible ? Visibility.Visible : Visibility.Hidden)
>   NoteEditor()
> }
> ```
> ⚠️ 待真机验证：Hidden 状态下 ArkWeb 会不会做内存优化（暂停 JS 执行 / 降低优先级）。
> 详见 `qa/2026-10-17_B组追问_Web组件.md` B-4。

### B3 Worker 内无法访问 javaScriptProxy ⚠️ —— 影响我们的"桥接放 Worker"计划

- Web 页面内可用标准 Web Worker（ArkWeb 基于 Chromium M114，推断）
- **Worker 内访问不到 `javaScriptProxy` 注入的对象**：注入是"注入到 window 对象"，Worker 是独立全局作用域、没有 window

→ **原计划"fs 桥接放 Worker"行不通**（直接调 javaScriptProxy 这条路）。
→ **MVP 决策：先放主线程**（数百篇量级可接受），性能实测不够再优化。文档里"必须批量化并放 Worker"的表述已修正。

> 📌 **二次核实（2026-10-17，见 `qa/2026-10-17_B组追问_Web组件.md` B-6）**：Worker 可救，只是要换通道。
> ArkWeb 基于 Chromium M114，标准 Web Worker 可用（⚠️ 推断）；`javaScriptProxy` 不可访问（因为它绑在 window 上）。
> **绕过办法**：把原生侧的 `WebMessagePort` **transfer 进 Worker**，Worker 内直接用它收发 ArrayBuffer 与原生通信：
> ```typescript
> worker.postMessage({ type: 'init', port }, [port]);   // 主线程把 port 转移进 Worker
> // worker 内：nativePort.onmessage = e => handle(e.data /* ArrayBuffer */)
> ```
> → **性能优化路径已明确**：桥接要进 Worker 时，走 transferred MessagePort，而不是 javaScriptProxy。MVP 仍先主线程。

### B4 rawfile 页面的 origin 与 CORS ✅ —— 官方更推荐"拦截"而非"转发"

`$rawfile` 页面走 `resource://rawfile/` 协议，**ArkWeb 内核明确禁止 file / resource 协议的跨域访问**，页面内 fetch 会被拦。
（与我们的实测一致：github.com 的 git 端点不返回 CORS 头。）

官方给的**首选方案是拦截，不是转发**：

```
onInterceptRequest 拦截请求
  → 原生层用 @ohos.net.http 真正发出
  → WebResourceHandler.didReceiveResponseBody(data: ArrayBuffer) 流式回填
```

这样 isomorphic-git **继续用原生 fetch、JS 侧代码零改动**，原生层对 JS 完全透明，也绕开 CORS。

> ⚠️ **但拦截方案有一个我们还没验证的致命前提**：`git-receive-pack`（push）是 **POST + 大二进制 body**。
> `onInterceptRequest` 回调的 `WebResourceRequest` **能否完整拿到 POST 请求体**，官方答复未覆盖。拿不到 → 拦截方案在 push 场景直接废掉。
> 现有方案（JS 侧自定义 http client 转发到原生）已在 node 冒烟测试中**真实 clone 成功**，POST body 由我们自己构造、不受此限制。
>
> **决策（2026-10-17 二次核实后定案）**：**拦截方案 ❌ 否决（对 push 不适用）**，现有转发方案为最终方案。
>
> 📌 二次核实结果（`qa/2026-10-17_B组追问_Web组件.md` B-1）：
> - ✅ `WebResourceRequest` 有 `getMethod()` / `getUrl()` / `getHeader()` / **`getRequestBody(): string`**
> - ⚠️ **返回类型是 `string` 而非 `ArrayBuffer`** → 文本 body 没问题，**二进制 packfile 经 string 序列化有编码损坏风险**
> - ❓ 官方既未说"支持二进制"也未说"仅支持文本"
>
> → 结论：**clone/fetch（GET 为主）走拦截可行，但 `git-receive-pack`（push，POST + 大二进制）不可靠**。
> 既然 push 是硬需求，统一走**转发**更省心，不再保留"拦截迁移"这条优化线。
> ⚠️ 新接口名 `getRequestBody()` 本次答复**未附文档链接**，若将来真要用拦截，落码前在 DevEco 里用 `@kit.ArkWeb` 补全复核。

### B5 尺寸变化不重载 ✅，但有尺寸上限要注意

`onPageEnd` 只在加载完成触发，尺寸变化不构成导航，**页面不重载**，滚动位置与编辑内容自然保留。

两个坑（文档记载）：
- **异步渲染模式下 Web 组件宽高不能超过 7680px（物理像素），超过会白屏**。三折叠全展开宽度大，全屏 Web 要留意；我们三栏各 1/3 时单栏约 1061px，安全。
- `onRenderExited`（渲染子进程异常退出）后需 `loadUrl` 重载，此时状态会丢 → 回调里做数据保存。

### B6 中文输入法 ❓ —— 仍是 M0.5 spike 的头号验证项

文档未记载系统性兼容问题，**必须真机实测** contenteditable / textarea。

可配置项：`keyboardAvoidMode`（软键盘避让）、`blurOnKeyboardHideMode`、`onInterceptKeyboardAttach` + `WebKeyboardController`（完全接管键盘）。
页面级键盘避让：`win.setWindowAvoidAreaTypes([AvoidAreaType.TYPE_KEYBOARD], cb)`。

> 📌 **二次核实（2026-10-17，见 `qa/2026-10-17_B组追问_Web组件.md` B-5）**：官方仍**无**明确记载 ❓。
> ⚠️ 上述键盘配置项主要影响**容器布局**，不直接管 Web 内部的输入逻辑。
> ⚠️ **对方建议优先用 `<textarea>` 而非 `contenteditable`**（输入法兼容性更好）→ **与我们的选型冲突**：
> 编辑器方案 A 用的 **CodeMirror 6 基于 `contenteditable`**。
> → **M0.5 spike 必须实测**：拼音 / 语音 / 手写三种输入下的 **composition 预编辑事件**与**光标定位**。
> 若 CM6 实测有问题，提前准备降级路径（textarea 自绘高亮 / CodeMirror 的 textarea 模式）。

---

### B7 WebMessagePort：rawfile 页面可用，支持 ArrayBuffer，上限未记载 （2026-10-17 新增）

- ✅ `WebMessage` 定义 `interface WebMessage { data: string | ArrayBuffer }` —— **文档明确支持 ArrayBuffer**
- ✅ `controller.createWebMessagePort()` 返回一对 port：一端注入 HTML（`postMessage`），一端原生持有（`onMessageEvent`）
- ⚠️ **`resource://rawfile/` 页面可用**：它是 ArkWeb 内部协议，`createWebMessagePort` 是**组件级** API，不受页面协议的跨域策略影响
- ❓ **单条消息的 ArrayBuffer 大小上限未记载**；推断受 Chromium IPC 单条上限（数十 MB 级）与设备内存约束
- ⚠️ **传输策略：分块**（示例 4MB/块，末尾发完成标记如 `__TRANSFER_COMPLETE__`），不要赌单条上限

```typescript
// 原生侧接收
nativePort.onMessageEvent((result: WebMessage) => {
  if (result.data instanceof ArrayBuffer) { /* new Uint8Array(result.data) */ }
});
```

→ **通道选型定案**：控制指令走 `runJavaScript` / `javaScriptProxy`；**大文本与 packfile 走 MessagePort + ArrayBuffer + 分块**。
→ 真机需实测：上限具体多少、分块大小取多少最稳（列入 M0.5 spike）。

---

## C 组：文件系统与存储

### C1 原子写 ✅ —— 用官方 AtomicFile 替换自研 tmp+rename

`renameSync` 在 dest 已存在时是否覆盖、是否原子，**官方均未记载**（不要把笔记完整性押在它上面）。

官方专门能力：**`fileIo.AtomicFile`（API 15+，我们的 API 24 可用）**

```typescript
import { fileIo } from '@kit.CoreFileKit';

let atomicFile = new fileIo.AtomicFile(targetPath);
let stream = atomicFile.openWrite();
try {
  stream.writeSync(content);
  stream.closeSync();
  atomicFile.finishWrite();   // 成功：临时文件重命名到目标位置
} catch (err) {
  atomicFile.failWrite();     // 失败：删临时文件，原文件不受影响
}
```

→ **直接采纳**，替换 4.2 节的自研 tmp+rename，以及 fs 桥接层里工作区 md 的写入。

### C2 目录遍历 ✅

`listFileSync(path, options)` **无分页游标**，一次性返回 `string[]`；`ListFileOptions` 有 `recursion`、`listNum`（0 = 全部）。
**API 26 才有 `listFileExt`（支持 `fileFilter`），我们 API 24 用不了** → 按后缀过滤要自己写。

TaskPool / Worker 中可调用 `@ohos.file.fs`，官方推荐把 IO 放 TaskPool；未记载"必须主线程"的接口。
上千文件：子线程遍历 + 分批处理，别在主线程一次性构建大数组。

### C3 访问令牌 ✅ —— Asset Store Kit，无需权限

```typescript
import { asset } from '@kit.AssetStoreKit';

// 写入
let attr: asset.AssetMap = new Map();
attr.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(token));  // 加密存储位
attr.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('github_token')); // 检索用，不加密
asset.addSync(attr);

// 读取（未找到抛 24000002，需捕获）
let query: asset.AssetMap = new Map();
query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('github_token'));
query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
let secret = asset.querySync(query)[0].get(asset.Tag.SECRET) as Uint8Array;
```

- 模块 `@ohos.security.asset`，导入 `@kit.AssetStoreKit`，首批 API 11+，`addSync/querySync` API 12+
- **无需申请任何权限**（SystemCapability.Security.Asset，非权限管控）
- **ALIAS 与含 DATA_LABEL 的属性不加密**，敏感数据只能放 `SECRET`
- 多库场景下 token 按库存 → **ALIAS 用 `vault:<库id>:token`**

### C4 备份 ✅（体积上限 ❓）

`backup_config.json` 的 `includes` 支持目录与通配符，可覆盖含子目录的整个文件树。体积上限未记载。

> ⚠️ **设备差异**：**PC/2in1 不支持备份恢复；Tablet 开启自由多窗后也不生效。**
> 我们的 `deviceTypes` 含 `2in1` → 备份不能作为唯一的数据保命通道，**导出 zip 仍要做**。

---

## D 组：HAR 打包与 ohpm 发布

### D1 HAR 内 rawfile ✅（建议编译确认）

HAR 的资源（含 `resources/rawfile`）编译期合并进依赖方 HAP，主模块可直接 `$rawfile('xxx/index.html')`。
注意主模块与 HAR 的 rawfile **重名冲突**问题。

→ 抽库的前置风险基本解除，但仍建议先建个空 HAR 编译确认一次。

### D2 ohpm 发布 ✅（是否必须 release ❓，审核周期 ❓）

```bash
ohpm config set publish_registry https://ohpm.openharmony.cn/ohpm/
ohpm config set publish_id <发布码>
ohpm publish yourlib.har
```

- 流程：准备 `oh-package.json5`（name/version 须符合 semver）→ 生成公私钥、公钥上传中心仓取**发布码** → `.ohpmrc` 配 `publish_registry`/`publish_id`/私钥路径 → 构建 .har → `ohpm publish`
- 包大小上限 **300MB**（ohpm 5.0.1+）
- `@<group>/<package>` 只有组织成员可发布；库名被占用后不能重复发布

---

## E 组：权限与网络

### E1 沙箱权限 ✅ —— 无需任何权限，当前无遗漏

应用对自己沙箱（`filesDir`）内自建文件有完全读写能力。只申请 `INTERNET` 是对的。

### E2 ARRAY_BUFFER 大小 ❓

`@ohos.net.http` 无流式读取接口，一次性返回完整响应。几十 MB 可行但占内存峰值。
超大对象可用 HTTP Range 分片自行拼接。

### E3 长时间网络 ✅

前台 clone/push **无需额外权限**。只有退后台仍需传输时才需 `KEEP_BACKGROUND_RUNNING` + `DATA_TRANSFER` 长时任务。

→ **决策：clone/push 保持前台执行 + 进度提示**（最简单合规）。不做后台同步。

---

## F 组：小艺智能体与端侧意图（Insight Intent）

> 来源：[`qa/2026-10-17_小艺智能体_端侧意图框架.md`](qa/2026-10-17_小艺智能体_端侧意图框架.md)（2026-10-17）
> ⚠️ **本组所有结论均未附文档链接**，落码前必须在 DevEco 用 `@kit.*` 补全复核接口名与签名。
> **不要在别的文档里复制本组结论**，一律链接过来 —— 下面标 ⚠️ 的随时可能被推翻。

### F1 应用内对话入口：`FunctionComponent` ⚠️

`@kit.AgentFrameworkKit` 提供 `FunctionComponent`（配 `FunctionController` 监听
`agentDialogOpened` / `agentDialogClosed`），传 `agentId` 即可在 App 内拉起智能体对话面板。
→ 这是「App 内嵌 AI 对话」的官方路径，**无需人工审核**（技能以 MCP / 插件形式发布到**自己**的智能体；
要进小艺主对话入口才需审核）。

### F2 意图声明：`@InsightIntentEntry` 装饰器 ⚠️

意图执行器用 `@InsightIntentEntry({...})` 装饰，参数用 **JSON Schema 内联声明**；
执行文件在 `insight_intent.json` 里用 `insightIntentsSrcEntry` 声明。
⚠️ 官方自己也不确定该字段是否支持**数组形式**（答复用「若不支持请以 IDE 编译提示为准」带过）。
→ 落码前先建一个单文件最小样例跑通编译，再决定怎么组织。

### F3 参数传递：同名属性自动注入 ⚠️

大模型解析出的参数**自动赋值给执行器的同名类属性**，随后触发 `onExecute()`。
**每个字段的 `description` 会被大模型用来理解怎么填参 —— 务必写清楚**，这是意图能不能填对的关键。

### F4 生命周期：`onCreate → onExecute`，不建 window ⚠️⚠️

后台执行模式（`UI_ABILITY_BACKGROUND`）下若冷启动，生命周期顺序是
`onCreate → onExecute`，**不经过 `onWindowStageCreate`**。
→ 需在 `EntryAbility.onCreate` 里把 context 存进全局单例，否则执行器拿不到 `filesDir`。
→ ⚠️ **这条对我们是致命的**：不建 window 意味着 **ArkWeb 组件没挂载 → 我们的 gitbridge 不可用 →
意图内无法同步 commit**。详见 §F6。

### F5 路径与写入 ✅ / ⚠️ 混合

- ✅ **路径必须基于 `context.filesDir` 等 Context 属性动态获取，禁止硬编码沙箱目录字符串**
  （与我们的既有硬约束一致）。
- ⚠️ 官方示例代码用 `openSync(READ_WRITE | TRUNC)` 覆盖写 —— **违反我们的原子写硬约束（见 C1）**。
  → **意图执行器里的写回必须换成 `fileIo.AtomicFile`**，别被示例带偏。
- ✅ 单篇数 MB 时 `readTextSync` 全量读入内存有风险，改用 `createReadStream` 分段读。

### F6 ⚠️ **关键冲突：git 版本底座在本工程里不成立**

官方方案假定存在一个**原生 ArkTS git**（`GitService.commit()`）。
我们的 git 是 **isomorphic-git 打包进 `rawfile/gitbridge/index.html`，跑在 ArkWeb 页面里**，
ArkTS 侧只有 fs / http 桥接。叠加 F4 的「后台执行不建 window」：

> **后台意图执行时，Web 组件可能根本不存在 → commit 无处调用。**

三种出路（**待拍板**，记录在 `docs/open_questions.md`）：

| 出路 | 做法 | 代价 |
| --- | --- | --- |
| **A. commit 入队、延迟执行** ⭐推荐 | 执行器写文件后把「待 commit 路径 + 消息」写进队列文件；App 回前台、Web 就绪后由主线程消费 | 反馈文案要改成「已修改，版本待提交」 |
| B. 执行时同步拉起不可见 Web 再 commit | 冷启动建 WebView 有耗时，且 Hidden 下 JS 是否执行未验证 | 慢 + 不可靠 |
| C. 放弃意图内 git，改文件级备份 | 写前复制 `.bak` / 自建轻量历史目录 | 失去 git log 摘要等扩展，且污染 vault |

→ 在出路拍板前，**不要把「AI 改笔记」排进 MVP 主链路**。

### F7 意图设计：锚点定位法 ✅（值得直接采纳）

「细粒度修改」的关键不在代码而在**参数设计**：修改指令必须携带 `anchor`（笔记原文中的精确片段），
执行器用字符串定位后按 `action` 重组。比「第几行」「标题路径」可靠——
大模型读完原文后擅长精确复制片段，且锚点对不上时可以**拒绝执行并要求重新读取**（防错改的闸门）。

建议意图清单：`QueryNotes` / `ReadNote` / `EditNote`（`replace`·`insertBefore`·`insertAfter`·`delete`）/
`AppendNote`（高频简单操作单独开意图，降低出错率）/ `UndoLastEdit`。

→ **我们要补的工程细节**：anchor 在文中出现**多次**时必须拒绝执行，
执行器应校验出现次数 >1 就要求智能体给更长的锚点。

### F8 智能体侧约束 ✅（建议照抄进系统提示词）

> 修改任何笔记前必须先调用 `ReadNote` 获取原文；
> `anchor` 必须取自原文，禁止凭记忆编造；
> 执行修改后向用户复述变更内容。

高风险操作（删除整篇）**单独设意图**，并在智能体侧配置执行前向用户确认。

---

## G 组：埋点与事件打点（hiAppEvent / UIObserver）

> 来源：2026-10-17 官方答复，**附了信息来源链接**（比前两批无链接答复可信度高一档）。
> 存档：`qa/2026-10-17_埋点与事件打点.md`。核实深度：**答复口径**，未逐条对照官方文档原文。

### G1 三类埋点都有原生能力，且版本全部可用 ✅

| 类型 | API | 起始版本 | API 24 可用 |
| --- | --- | --- | --- |
| 曝光（组件级） | `onVisibleAreaApproximateChange` | **17+** | ✅ |
| 曝光（全局无侵入） | `FrameNode.setOnVisibleAreaApproximateChange` | **12+** | ✅ |
| 点击 | `UIObserver.on('willClick')`（点击前回调，可拿 `ClickEvent` + `FrameNode`） | **12+** | ✅ |
| 页面切换 | `UIObserver.on('navDestinationSwitch')` | **12+** | ✅ |

**能力分层**：采集 → `hiAppEvent.write` 落盘 → `addWatcher` 订阅 → `onTrigger` 批量 `takeNext()` → 自建 http 上报。
→ **无需引入第三方埋点 SDK。**

### G2 曝光埋点细节 ✅

- `ratios: [0.5]` 的**实际生效阈值区间是 `[0.0, 0.5]`**，回调在比值**跨越**阈值时触发（非每帧）。
- 用 `onVisibleAreaApproximateChange` 而非 `onVisibleAreaChange`：计算频度由 `expectedUpdateInterval` 控制，**列表大量注册时功耗更优** → 文件树场景应当用它。
- ⚠️ **去重必须自己做**，官方示例的 `exposedSet` 是**内存态**，进程重启失效。

### G3 批量取出 ✅ / ⚠️

`triggerCondition: { row, size }` 满足任一即触发；`onTrigger` 里 `holder.takeNext()` 取到 null 为止。
⚠️ `addWatcher` 涉及 I/O，**性能敏感场景放子线程**，且该线程在使用周期内**不能被销毁**；watcher **同名会覆盖前一次订阅**。

### G4 全局无侵入方案 ✅（最匹配我们的文件树）

业务组件只声明 `.id()` 与 `.customProperty()` 标识身份；Ability 层统一用 `UIObserver` + `FrameNode.setOnVisibleAreaApproximateChange` 监听，**业务代码零侵入**。
点击同理：`observer.on('willClick', cb)` **全局注册一次**，回调里读 `FrameNode` 标识。

### G5 明确的能力限制 ⚠️

可见区域计算**不支持**：兄弟组件遮挡、窗口遮挡、组件旋转；只算自身节点相对祖先直至窗口边界的裁切比。
→ 三折叠形态切换瞬间的曝光比值**准确性无保证**，相关埋点只作趋势看。

### G6 另一条路径：华为分析 Analytics Kit ✅

上架华为应用市场后可用，AGC 控制台直接看板，免自建后台。与原生方案可**并用**（hiAppEvent 落盘保不丢 + 云端看板）。
差别：原生方案**数据归你自己**；Analytics Kit 数据在华为侧。

### G7 🔴 本项目红线：笔记内容一律不得进入埋点

**可采集**：行为坐标（目录层级、当前形态、按钮点击、同步成败与耗时）。
**禁止采集**：笔记标题、文件名、路径、正文、字数、标签。

理由：① 这是个人知识库，不是内容社区；② 采集用户内容会显著抬高隐私合规成本与上架审核风险。
→ **埋点字段设计必须先过这条红线再落码。**

### G8 我们补的三条工程约束（官方没提）

1. **曝光去重按「会话内」定义指标** —— 官方 Set 是内存态，重启后同一批笔记会重复计曝光。推荐先把指标定义为"单会话内曝光"，而非跨会话去重。
2. **上报非实时、失败即丢** —— `triggerCondition` 本就是累积触发；**不做重试队列**，避免埋点上报与 git 同步抢带宽、拖累主链路。
3. **埋点不得阻塞主链路** —— 采集与上报全部走旁路，异常吞掉，不许让埋点崩溃影响编辑/同步。

### G9 待核实 ❓（不阻塞）

| 编号 | 问题 |
| --- | --- |
| **G-A** | `hiAppEvent.write` 是否需要权限？落盘是否在应用沙箱内？ |
| **G-B** | `UIObserver.on('willClick')` 只能观察，还是能拦截点击？ |
| **G-C** | `customProperty()` 的值有无类型/长度限制？ |

---

## H 组：应用元信息与版本读取

> 2026-10-17 建立。起因：需要「关于」页显示版本号，**运行时怎么读 `versionName` 尚未核实**。

### H1 版本号的单一真源是 `AppScope/app.json5` ✅

```
AppScope/app.json5 → app.versionCode / app.versionName
```

⚠️ **当前值仍是工程模板默认（`1.0.0` / `1000000`）**，未与版本规则对齐。
按 `docs/releases/README.md` R1：版本目录 `v0.1` → `versionName = "0.1.0"`，`versionCode` 单调递增。
**发布时必须同步**（R9 第 2 条），否则装到手机上的版本号与版本档案对不上。

### H2 运行时读取版本号 ❓ 待核实（**别凭记忆写**）

候选路径（**均未核实，落码前必须 DevEco 补全确认**）：

| 候选 | 说明 | 状态 |
| --- | --- | --- |
| `bundleManager.getBundleInfoForSelf(...)` → `BundleInfo.appInfo.versionName` | 读自身包信息 | ❓ 是否存在该 flag / 是否需要权限，未核实 |
| 资源文件 `$r('app.string.xxx')` 手写版本字符串 | 简单但**必然与 app.json5 漂移** | ❌ 不推荐 |
| 构建期注入常量 | 需改构建脚本 | ❓ 待评估 |

> **硬规则**：版本号**只能从包信息读出**或**构建期注入**，**禁止在源码里手写版本字符串**——手写必然与 `app.json5` 不一致，且每次发版都要记得改。

### H3 待核实清单

| 编号 | 问题 |
| --- | --- |
| **H-1** | API 24 下运行时读取自身 `versionName` 的**确切接口与所需 flag**？读自身包信息是否需要权限？ |
| **H-2** | `bundleManager` 的同步版本（如 `getBundleInfoForSelfSync`）在 API 24 是否可用？ |

---

## 落地决策表

| 结论 | 决策 | 何时做 |
| --- | --- | --- |
| 三档断点用 windowSizeChange + px2vp | ✅ 维持原方案 | 已是现状 |
| UIAbility 折叠切换不重建 | ✅ 解除顾虑，仍需定期落盘 | 已是现状 |
| 三折叠恒为 phone | ✅ deviceTypes 不动 | 已是现状 |
| ~~折痕接口只返回单个 Rect~~ | ⚠️ **纠正**：SDK 实证返回 `FoldCreaseRegion{ creaseRects: Array<Rect> }`（官方答复错了）。决策不变：**自绘等分 + 真机校准**（~~`FoldSplitContainer`~~ 已于 2026-10-17 否决） | 已定为自绘；真机校准待做 |
| **三屏态 FoldStatus 返回值未知** | ⚠️ 真机打印建映射表 | M0.5 顺带做 |
| **AtomicFile 官方原子写** | ✅ **替换自研 tmp+rename** | M0.2 落码时 |
| **Asset Store Kit 存令牌** | ✅ **实现 TokenStore，alias 按库** | M3.5 前 |
| **大文本/packfile 走 WebMessagePort** | ✅ 新增通道（**分块 4MB**），替代 runJavaScript 传大数据 | 真机验证上限后 |
| **Worker 内拿不到 javaScriptProxy** | ✅ 桥接**先放主线程**；要进 Worker 时把 port **transfer** 进去 | 性能优化时 |
| 拦截方案（onInterceptRequest） | ❌ **否决（2026-10-17）**：`getRequestBody()` 返回 **string**，二进制 packfile 有损坏风险 → push 不可靠 | 转发方案为最终方案 |
| 离线 Web 组件（NodeContainer） | ❌ **推翻（2026-10-17）**：卸载即销毁、重挂会重载页面 → git 容器改 **`visibility(Hidden)` 常驻** | M0 落码时 |
| 沙箱无权限需求 | ✅ 确认无遗漏 | — |
| 后台同步不做 | ✅ 保持前台 | — |
| HAR rawfile 可加载 | ✅ 抽库前置风险基本解除 | 抽库前编译确认 |
| Web 组件 7680px 上限 | ✅ 三栏各 1/3 安全，全屏 Web 要留意 | 编码时注意 |
| 中文输入法 | ❓ **M0.5 spike 头号验证项**；⚠️ 官方建议优先 textarea，**与 CodeMirror 6（contenteditable）冲突**，实测不过要准备降级路径 | M0.5 |
| **小艺智能体 + 端侧意图** | ⚠️ 方案可行但**未附文档链接**，且 §F6 与我们的 Web 内 git **存在架构冲突** → 出路未拍板前**不进 MVP 主链路** | 核实 F-A/F-B/F-C 后 |
| 意图执行器写文件 | ⚠️ 官方示例用 TRUNC 覆盖写 —— **必须改成 `AtomicFile`**（C1 硬约束优先于示例） | 落码时 |
| **埋点（曝光/点击/页面）** | ✅ **用原生 `hiAppEvent` + `UIObserver`，不引第三方 SDK**；三类 API 起始版本 12–17，**API 24 全部可用**；🔴 **笔记内容一律禁止进埋点** | **后置**（不在 v0.1–v0.3） |
| 埋点上报策略 | ✅ 非实时批量 + **失败即丢**（不做重试），避免与 git 同步抢带宽 | 落码时 |
| 形态分布埋点（sm/md/lg 使用占比） | ✅ 本项目最独有的数据，**v0.1 发布后即可采集**且不触碰内容红线 | v0.1 之后评估 |
