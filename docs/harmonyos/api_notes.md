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

### A2 折痕区域 ✅（但**只返回单个 Rect**，三折叠行为 ❓）

```typescript
display.getCurrentFoldCreaseRegion(): display.Rect   // left/top/width/height，单位 px
```

**这条对我们是个坏消息**：三折叠有**两条**铰链，但该接口签名返回的是**单个 Rect**，官方未记载三折叠下会返回哪一段（或是否合并）。

因此**不能把"三栏边界压在折痕上"直接建立在它之上**。

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

### B2 隐藏的计算型 Web 组件 ⚠️ → 改用离线 Web 组件

`visibility(Hidden)` / `opacity(0)` 时组件仍在树上、JS 环境保留（反向推断，未逐字记载）。**不建议用 1×1 像素**。

官方方案：**`NodeController` + `NodeContainer` 动态挂载/卸载 Web 节点**（离线 Web 组件，官方为"页面保活"场景提供）。
→ git 计算容器应改用这种方式承载。

### B3 Worker 内无法访问 javaScriptProxy ⚠️ —— 影响我们的"桥接放 Worker"计划

- Web 页面内可用标准 Web Worker（ArkWeb 基于 Chromium M114，推断）
- **Worker 内访问不到 `javaScriptProxy` 注入的对象**：注入是"注入到 window 对象"，Worker 是独立全局作用域、没有 window

→ **原计划"fs 桥接放 Worker"行不通**。可选：Worker 内 `postMessage` 回主线程代为调用；或统一走 WebMessagePort。
→ **MVP 决策：先放主线程**（数百篇量级可接受），性能实测不够再优化。文档里"必须批量化并放 Worker"的表述已修正。

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
> **决策：MVP 保留现有转发方案**（已验证 + 不依赖未验证前提）；把拦截方案记为优化项，先做 POST body 可行性验证再评估迁移。

### B5 尺寸变化不重载 ✅，但有尺寸上限要注意

`onPageEnd` 只在加载完成触发，尺寸变化不构成导航，**页面不重载**，滚动位置与编辑内容自然保留。

两个坑（文档记载）：
- **异步渲染模式下 Web 组件宽高不能超过 7680px（物理像素），超过会白屏**。三折叠全展开宽度大，全屏 Web 要留意；我们三栏各 1/3 时单栏约 1061px，安全。
- `onRenderExited`（渲染子进程异常退出）后需 `loadUrl` 重载，此时状态会丢 → 回调里做数据保存。

### B6 中文输入法 ❓ —— 仍是 M0.5 spike 的头号验证项

文档未记载系统性兼容问题，**必须真机实测** contenteditable / textarea。

可配置项：`keyboardAvoidMode`（软键盘避让）、`blurOnKeyboardHideMode`、`onInterceptKeyboardAttach` + `WebKeyboardController`（完全接管键盘）。

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

## 落地决策表

| 结论 | 决策 | 何时做 |
| --- | --- | --- |
| 三档断点用 windowSizeChange + px2vp | ✅ 维持原方案 | 已是现状 |
| UIAbility 折叠切换不重建 | ✅ 解除顾虑，仍需定期落盘 | 已是现状 |
| 三折叠恒为 phone | ✅ deviceTypes 不动 | 已是现状 |
| **折痕接口只返回单个 Rect** | ⚠️ **自绘等分 + 真机校准**（~~`FoldSplitContainer`~~ 已于 2026-10-17 否决） | **M0 前必须定** → 已定为自绘 |
| **三屏态 FoldStatus 返回值未知** | ⚠️ 真机打印建映射表 | M0.5 顺带做 |
| **AtomicFile 官方原子写** | ✅ **替换自研 tmp+rename** | M0.2 落码时 |
| **Asset Store Kit 存令牌** | ✅ **实现 TokenStore，alias 按库** | M3.5 前 |
| **大文本/packfile 走 WebMessagePort** | ✅ 新增通道，替代 runJavaScript 传大数据 | 真机验证后 |
| **Worker 内拿不到 javaScriptProxy** | ✅ 桥接**不放 Worker**，先主线程 | 已修正文档 |
| 拦截方案（onInterceptRequest） | ⏸ **暂缓**：POST body 获取是未验证前提 | 验证后再评估 |
| 离线 Web 组件（NodeContainer） | ✅ git 容器改用它承载 | 真机阶段 |
| 沙箱无权限需求 | ✅ 确认无遗漏 | — |
| 后台同步不做 | ✅ 保持前台 | — |
| HAR rawfile 可加载 | ✅ 抽库前置风险基本解除 | 抽库前编译确认 |
| Web 组件 7680px 上限 | ✅ 三栏各 1/3 安全，全屏 Web 要留意 | 编码时注意 |
| 中文输入法 | ❓ **M0.5 spike 头号验证项** | M0.5 |
