# 咨询：三方应用拿到「目录 URI」后，用什么 API 递归枚举 / 读写子文件？（API 24）

> 用法：把「问题正文」整段复制，发给鸿蒙官方技术支持 / 开发者问答 / 官方 AI 助手。
> 正文自包含：环境、目标、复现代码、实测结果表、SDK 契约出处都在里面，对方不需要追问就能回答。
>
> 状态：**✅ 2026-10-31 已收到答复并实测闭环** —— 见
> [`qa/2026-10-31_目录URI遍历答复核验.md`](qa/2026-10-31_目录URI遍历答复核验.md)。
> 结论已回填 `api_notes.md` **T3（listFile 不支持 URI，官方确认）** 与 **T5（Native fdopendir 通路）**。
> 核心：官方确认三方侧无 ArkTS 枚举接口，**但链路没断** ——
> `fs.openSync(目录URI, READ_ONLY|OpenMode.DIR)` 拿 fd → Native `fdopendir`/`openat` 递归；
> Q5-C 不成立，**产品形态不用改**。XT2 实测单层 16 条 / 递归 31 条，已验证含子目录路径。
>
> ⚠️ **采纳答复前请注意**：本项目有硬约束——**官方答复也要交叉验证**。
> 我们已被官方答复误导过**四次**（详见文末统计），其中本次补丁就抓到一个：
> 答复示例里的 **`fs.OpenMode.READ_DIR` 根本不存在**（真实是 `OpenMode.DIR = 0o200000`）。
> **拿到答复后请尽量给出 API 文档链接或 SDK 出处。**

---

## 一句话问题

三方应用用 `DocumentViewPicker`（`DocumentSelectMode.FOLDER`）让用户授权**一个外部目录**，
拿到 `file://docs/storage/Users/currentUser/Download/xxx` 这样的**目录 URI**，
`persistPermission` → `activatePermission` 全部成功；但 `fs.listFileSync(该URI, {recursion: true})`
返回 **13900002（ENOENT）**，而同一个 URI 用 `fs.openSync()` 却**能成功打开**。

**这个场景下，三方应用递归枚举该目录下所有文件的官方推荐做法是什么？**

---

## 问题正文

````
### 环境

- 设备：HUAWEI Mate XT2（LAP-AL10），OpenHarmony-7.0.0.111，
  `const.ohos.apiversion = 26`
- 另有模拟器（x86_64，同一 API 26 系统），行为一致，便于复现
- compileSdkVersion 6.0.0(26) / compatibleSdkVersion **6.1.1(24)** —— **我们只能用 API ≤ 24 的接口**
- ArkTS，Stage 模型

### 目标（不是 toy demo，是真实产品需求）

做一个 Obsidian 类笔记 App：**让用户一次性授权「一个笔记库目录」**（内含多层子目录、
大量 `.md`），App 需要三条能力：

1. 递归枚举该目录下所有 `.md`（含子目录）
2. 读写这些 `.md`（编辑并保存回去）
3. 授权持久化 —— **重启 App / 重启设备后仍能访问，不再弹选择器**

已申请并声明 `ohos.permission.FILE_ACCESS_PERSIST`；`atm dump` 显示
`grantStatus=0 / flag=4`（SYSTEM_GRANT，声明即授予）。

### 复现代码（最小片段，ArkTS）

```typescript
import { picker } from '@kit.CoreFileKit';
import { fileShare } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';

// 1) 选目录
const pickerOpts = new picker.DocumentViewPicker(context);
const uris = await pickerOpts.select({
  selectMode: picker.DocumentSelectMode.FOLDER,   // ← 目录模式
});
const dirUri = uris[0];
// 实测拿到：file://docs/storage/Users/currentUser/Download/com.onyx.galaxy.hmos.note

// 2) 持久化 READ+WRITE
await fileShare.persistPermission([
  { uri: dirUri, operationMode: fileShare.OperationMode.READ_MODE
                               | fileShare.OperationMode.WRITE_MODE },
]);

// 3) 校验 + 激活（含「杀进程重启后」再激活，也成功）
const flags = await fileShare.checkPersistentPermission([
  { uri: dirUri, operationMode: fileShare.OperationMode.READ_MODE },
]);                                        // → [true]
await fileShare.activatePermission([
  { uri: dirUri, operationMode: fileShare.OperationMode.READ_MODE
                               | fileShare.OperationMode.WRITE_MODE },
]);

// 4) 递归枚举 —— ❌ 失败
const names = fs.listFileSync(dirUri, { recursion: true });
// BusinessError: code 13900002, message "No such file or directory"

// 5) 同一个 URI 用 open —— ✅ 成功
const fd = fs.openSync(dirUri, fs.OpenMode.READ_DIR);
// 返回可用 fd，不抛错
```

### 实测结果表（Mate XT2，API 26）

| # | 调用 | 结果 |
| --- | --- | --- |
| 0 | `canIUse('SystemCapability.FileManagement.DocumentFilePicker.FolderSelection')` | ✅ true |
| 1 | `DocumentViewPicker.select({ selectMode: FOLDER })` | ✅ 返回 `file://docs/...` 目录 URI |
| 2 | `fileShare.persistPermission([{uri, operationMode: 3}])` | ✅ 成功 |
| 3 | `fileShare.checkPersistentPermission([...])` | ✅ `[true]` |
| 4 | `fileShare.activatePermission([...])` | ✅ 成功 |
| 4b | 同上，**杀进程重启后再 activate** | ✅ 成功（持久化确认有效） |
| 5 | `fs.listFileSync(dirUri, { recursion: true })` | ❌ **13900002** No such file or directory |
| 6 | `fs.openSync(dirUri, OpenMode.READ_DIR)` | ✅ 成功，返回可用 fd |

### 关键：SDK 类型定义里二者契约本来就不同

本机 SDK `sdk/default/openharmony/ets/api/@ohos.file.fs.d.ts`：

| 接口 | d.ts 行 | path 参数原文 |
| --- | --- | --- |
| `fs.open` | 2491 / 2529 / 2582 | `Application sandbox path **or URI** of a file or directory to open` |
| `fs.lstat` | 1711 / 1733 | `Application sandbox path **or URI** of the file.<br>**Note**: URIs can be passed since API …` |
| `fs.listFile` | 1548 起（全部重载） | `Application sandbox path of the directory`（**无 URI 字样**） |

也就是说：**`open` / `lstat` 明文支持 URI，`listFile` 明文只支持沙箱路径**。
我们实测的结果（第 5 步失败、第 6 步成功）与 SDK 契约完全吻合——**不是用法错误，是接口不支持**。

但这样一来，第 1 步能选到目录、第 2~4 步能把权限持久化并激活，
却**没有任何能枚举内容的 API**，整条链路就断了。

### 想请你确认的问题（可逐条回答，方便我对照）

**Q1（核心）** 三方应用拿到 `DocumentSelectMode.FOLDER` 返回的**目录 URI** 后，
**递归枚举其全部子目录与文件的官方推荐 API 是什么？** 请给出 API 名 + 最低 API 版本。

**Q2** `fs.listFile` 的 path 参数是否**永远不会**支持 `file://docs/...` 这类目录 URI？
（SDK 注释已这么写，我们要确认它是不是「文档过时而实现支持」，还是确实不支持。）
如果**未来会支持**，请告知版本计划；如果**确定不支持**，我们就不等了。

**Q3** 我们注意到 **`fs.open(目录URI)` 能成功拿到 fd**，说明内核侧目录是可访问的，
只是缺少枚举入口。**是否有基于 fd 的目录遍历接口**（类似 POSIX `readdir(fd)` /
`DirStream` / `opendir` 语义）？我们在 SDK d.ts 里搜 `readdir` / `opendir` / `DirStream`
均无结果——是否漏了模块名？

**Q4** `@ohos.file.fileAccess` 我们查到是 **已废弃 + 仅系统应用可用**（`systemapi`）。
它的**三方替代方位**是什么？（若确实没有三方替代，请明确说「没有」，
我们据此改产品形态。）

**Q5（产品形态兜底）** 如果三方 App **结构上无法**枚举用户授权的外部目录，
请确认我们下面的理解是否正确：

- A：只能让用户 **逐个/批量选文件**（`DocumentSelectMode.FILE`），
  选到哪个 URI 才能操作哪个文件，**拿不到目录全貌**；
- B：或者 App **把笔记库搬进自己的沙箱目录**（导入制），由 App 自己管理生命周期；
- C：不存在「授权一次外部目录、App 长期自由读写」的形态。

**Q6** 若 Q5 的 C 成立，那么 **`FILE_ACCESS_PERSIST` 这个权限的适用场景到底是什么**？
我们能持久化 `operationMode: 3`（READ+WRITE）且 `checkPersistentPermission` 返回 true，
却遍历不了目录——这个权限 granted 之后**实际解锁了哪些能力**？请给出官方说明或示例。

**Q7（次要）** 应用**卸载重装**后，此前持久化的 URI 是否应当继续有效？
我们曾观察到重装后 `listFile` 报 13900002，但**这条证据不可靠**（因为 listFile 本来就不支持 URI，
失败是必然的，与重装无关）。我们还没用 `openSync` 复测过卸载前后的差异——
**如果方便，请一并说明「目录授权在什么条件下会失效」**（卸载重装 / 清数据 / 换机 / 系统升级 / 目录被移动或改名）。

### 我们已经做过 / 已排除的（避免重复建议）

- ❌ 确认不是权限没授予：`FILE_ACCESS_PERSIST` 是 **SYSTEM_GRANT**，
  `atm dump` 显示 `grantStatus=0 / flag=4`，无需运行时弹窗。
- ❌ 确认不是 URI 编码问题：URI 未经任何 decode，原样传给 `listFileSync` 失败、
  原样传给 `openSync` 成功——同一个串，两个接口表现不同，**与编码无关**。
- ❌ 确认不是 Picker 选错模式：`selectMode` 明确是 `DocumentSelectMode.FOLDER`，
  返回的确实是目录 URI（`file://docs/storage/Users/currentUser/...`）。
- ❌ `FilePicker` 选文件模式只能拿到文件 URI，**不满足「整库」语义**（我们知道这条路，正在评估）。
- ⚠️ 网上流传的「`listFile` 支持 URI 递归遍历外部目录」社区示例与 SDK d.ts 注释冲突，
  **我们按 SDK 注释为准**——如果社区用法是对的，请给出官方口径出处。
- ⚠️ 我们**不打算**用任何 `systemapi` / 系统签名能力，也不要 `@ohos.file.fileAccess`
  这种已废弃通道。请只给三方应用（普通 NORMAL 级）可用方案。
````

---

## 拿到答复后（给我自己看）

| 答复 | 动作 |
| --- | --- |
| 存在可枚举目录 URI 的 API（含 version ≤ 24） | 回填 `api_notes.md` **T3**（❓→✅），v1.5 的 15.1–15.6 按该 API 落码 |
| 只有在更高版本才支持 | 记录版本号 + 是否值得抬 `compatibleSdkVersion`（涉及 XT2 之外的覆盖率） |
| 官方明确「三方不可枚举外部目录」 | `api_notes.md` **T3** 标「实测+官方确认不可行」，**v1.5 §6.1 阻塞项落地为「改产品形态」**，走 Q5 的 A/B 方案重新设计 |
| 推荐「导入到沙箱」（B 方案） | 另行评估：是否接受「笔记库搬进 App 沙箱」+ 导出回写的产品形态 |

回填位置：

- `docs/harmonyos/api_notes.md` —— **T1**（Picker 目录模式）、**T2**（persist/activate）、
  **T3**（目录遍历）、**T4**（权限等级）
- `docs/releases/v1.5/需求文档.md` —— §6.1 阻塞项 1
- 若结论是「改产品形态」，`docs/requirements_backlog.md` 的 v1.5 条目要整体重排

---

## 「官方答复有硬伤」统计（每次 Adoption 前先扫一眼）

| # | 官方说法 | 实际 | 出处 |
| --- | --- | --- | --- |
| 1 | `getCurrentFoldCreaseRegion()` 返回单个 Rect | SDK 实证是 `Array<Rect>` | `咨询_折痕接口_XT2.md` |
| 2 | `build-profile` overrides 需 `name` 字段 | 运行时 schema 拒绝 | 同上 |
| 3 | `display.getLiveCreaseRegion()` | 是 `Display` **实例方法**，编译报 10505001 | 同上 |
| 4 | **`fs.OpenMode.READ_DIR`** | **不存在**；真实是 `OpenMode.DIR = 0o200000`，开目录要 `READ_ONLY \| DIR` | 本次答复，`qa/2026-10-31_目录URI遍历答复核验.md` |

规律：**方向性结论可信度高，具体 API 名必须回 SDK 核一遍。**

### ✅ 第 4 条已被官方主动纠正（2026-10-31 第二轮）

写链路的答复开篇即写明：
「先纠正上一轮的错误并致歉：`fs.OpenMode` 中不存在 `READ_DIR`，打开目录应使用 `fs.OpenMode.DIR`（0o200000）」，
并且全篇符号零错误——这是四轮咨询里质量最高的一次。

促成因素很可能是提问正文里那句明确要求：
> 「烦请核对到 `@ohos.file.fs.d.ts` 的真实符号与行号，或给出可查证的文档链接」

→ **以后每份模板都保留这段要求**，模板范本见
[`咨询_目录URI写入链路_API24.md`](咨询_目录URI写入链路_API24.md)。

---

## 投递渠道建议

1. **华为开发者联盟 → 技术支持 / 在线提单**（最有可能拿到明确答复，
   我们的折痕接口问题就是这么解的）
2. HarmonyOS 开发者社区问答版（同正文，标题用「目录URI无法递归枚举，listFile 返回13900002」）
3. 官方 AI 助手（适合快速交叉验证，但按我们的硬约束，答复要再找 SDK / 设备验证）
