# 咨询：三方应用对已授权「目录 URI」的**写入**链路怎么做？（API 24）

> 用法：把「问题正文」整段复制，发给鸿蒙官方技术支持 / 开发者问答 / 官方 AI 助手。
> 正文自包含：环境、目标、SDK 契约出处、实测读数都在里面，对方不需要追问就能回答。
>
> 状态：**✅ 2026-10-31 已收到答复并实测闭环** —— 见
> [`qa/2026-10-31_目录URI写链路答复核验.md`](qa/2026-10-31_目录URI写链路答复核验.md)。
> 结论已回填 `api_notes.md` **T6（AtomicFile 不支持 URI，code=-1 有 SDK 出处）**、
> **T7（写/删/改名全走 Native POSIX，含 XT2 五步实测）**、**T8（无官方变更通知，只能轮询）**。
> 核心：**读写删改全部收敛 Native**（`openat`/`write`/`fsync`/`renameat`/`unlinkat`），
> ArkkTS 只管 Picker + `fileShare` + 传 dirFd；答复明确这条路**不会因用 POSIX 被上架驳回**，
> 且 ArkTS 侧**无补齐计划** → 按「现在就写 Native」决策，不再等官方 API。
>
> ✅ **本轮答复零硬伤**：对方开篇主动纠正了上一轮的 `OpenMode.READ_DIR` 错误，
> 且本轮出现的全部符号均与本机 SDK 一致（详见核验稿）。这是四轮咨询里质量最高的一次，
> 推测与我们在正文里明确要求「给出 d.ts 行号/文档链接」有关 —— **这个要求建议固化进以后的模板**。
>
> ⚠️ **采纳答复前请注意**：本项目有硬约束——**官方答复也要交叉验证**。
> 我们已被官方答复误导过**四次**（详见文末统计），最近一次是答复示例里的
> **`fs.OpenMode.READ_DIR` 根本不存在**（真实是 `OpenMode.DIR = 0o200000`）。
> **拿到答复后请给出 API 文档链接或 SDK 出处**，我们会在设备上跑一遍再落地。

---

## 一句话问题

上一轮已确认并实测：三方应用对 `DocumentViewPicker(FOLDER)` 授权的**目录 URI**，
枚举要走 `fs.openSync(目录URI, READ_ONLY|OpenMode.DIR)` → Native `fdopendir`/`openat`。
现在读链路通了，**写链路断了**：
`AtomicFile(path)` 的 path 参数在 SDK 里明确是 **"Application sandbox path of the file"**，
我们传目录 URI / 拼接后的子文件 URI 都失败（**`code = -1`，不是 BusinessError，拿不到 errno**）。

**在只持有「目录 URI + 持久化读写授权」的前提下，
新建子文件 / 覆盖写已有文件 / 原子替换 / 删除重命名的官方推荐做法各是什么？**

---

## 问题正文

````
### 环境

- 设备：HUAWEI Mate XT2（LAP-AL10），OpenHarmony-7.0.0.111，`const.ohos.apiversion = 26`
- 另有模拟器（x86_64，同一 API 26 系统），行为一致，便于复现
- compileSdkVersion 6.0.0(26) / compatibleSdkVersion **6.1.1(24)**
  —— **我们只能用 API ≤ 24 的接口**，`@since 15` 的 AtomicFile 虽然可用但要受这条限制约束语义
- ArkTS Stage 模型，普通三方应用（NORMAL 权限，已声明 `ohos.permission.FILE_ACCESS_PERSIST`）

### 目标（一个 Markdown 笔记 App 的真实诉求）

用户选一次外部目录（如 Download/我的笔记/），之后 App 要能长期：
1. 递归枚举该目录下所有 `.md`（**上一轮已解决**：Native `fdopendir`/`openat`，实测单层 16 条 / 递归 31 条）
2. **读**某个 md 的全文（上一轮未单独问，但 `open` 收 URI + `read(fd)` 应当可行）
3. **写回**某个 md：全量覆盖（含"新内容比原内容短"的情况，需要截断）
4. **新建**一个 md（用户点"新建笔记"）
5. **删除 / 重命名** md
6. 以上操作要保证**不因写一半崩溃而产生半截文件**（这是我们最在意的）

### 已实测成功的前置链路（上一轮结论，已设备验证）

| 步骤 | 结果 |
| --- | --- |
| DocumentViewPicker(FOLDER)，`canIUse('SystemCapability.FileManagement.File.FileIO.FolderSelection')` | ✅ true |
| 返回 URI | ✅ `file://docs/storage/Users/currentUser/Download` |
| `fileShare.persistPermission([{uri, operationMode: 3}])` | ✅ |
| `fileShare.checkPersistentPermission([uri])` | ✅ `[true]` |
| `fileShare.activatePermission([{uri, operationMode: 3}])` | ✅ 杀进程重启后再次激活仍成功 |
| `fs.open(目录URI)` 拿 fd | ✅（注释口径："Application sandbox path **or URI**"） |
| Native `fdopendir(fd)` 单层 | ✅ 16 条，与 Picker 自报 16 项一致 |
| Native `openat` 递归 | ✅ 31 条，路径含子目录前缀 → 授权顺延到子目录得证 |
| `fs.listFileSync(目录URI, {recursion:true})` | ❌ 13900002（已知，path 不收 URI） |

也就是说：**"目录 fd 是真实可遍历的内核 fd"这件事已经得到验证**，
剩下的问题是"**怎么基于这个 fd / 这个 URI 往下写**"。

### 本轮的失败现象

对同一个已授权目录 URI 尝试原子写：

```typescript
const dirUri = 'file://docs/storage/Users/currentUser/Download';   // Picker 返回
const target = '某个已存在的子文件 URI（由 dirUri 拼接得到）';

const af = new fileIo.AtomicFile(target);      // ← 这里或后续 startWrite 失败
const stream = af.startWrite();
```

结果：**抛出的错误 `code = -1`** —— **不是 BusinessError**，`error.code` 为 -1，
既拿不到 errno（13900002 / 13900012 / 13900042），也没有 message 可判读。
我们怀疑是 `AtomicFile` 内部会把 path 当沙箱路径处理并做拼临时文件操作，
对 federated URI 直接失败在一个不抛 BusinessError 的环节。

### SDK 契约对照（这是我们最希望你确认/纠正的部分）

本机 `@ohos.file.fs.d.ts` 逐字摘录 —— 我们把**所有可能用到的写接口**的
`path` 参数口径列全了，分歧非常整齐：

| 接口 | d.ts 行 | 第一个参数的官方口径 | 能否用于目录 URI 子树 |
| --- | --- | --- | --- |
| `AtomicFile(path)` | L4714 / L4718 | **Application sandbox path of the file** | ❌ 推测不行（已实测失败） |
| `createStream(path, mode)` | L902 / L948 | **Application sandbox path of the file** | ❌ |
| `unlink(path)` | L3455 / L3481 | **Application sandbox path of the file** | ❌ |
| `rename(oldPath, newPath)` | L3009 / L3044 | **Application sandbox path of the file or directory** | ❌ |
| `listFile*(path, options)` | L1548 起 | **Application sandbox path of the directory** | ❌（上一轮官方已确认） |
| **`open(path, mode)`** | L2491 / L2529 / L2582 | **Application sandbox path or URI** of a file or directory | ✅ 已实测 |
| `lstat / stat / copyFile / truncate` | L1711 / L3184 / L761 / L3346 | 参数为 `string \| number`（**Path or FD**） | ⚠️ 取决于 path 是否同 `open` 口径 |

而**所有"拿 fd 之后"的操作全部可用**（这些才是真正干活的部分）：

| 接口 | d.ts 行 | 形参 |
| --- | --- | --- |
| `write` / `writeSync` | L3557 / L3651 | `fd: number` |
| `truncate` / `truncateSync` | L3346 / L3429 | `file: string \| number` |
| `fdopenStream` / `fdopenStreamSync` | L1404 / L1498 | `fd: number` |
| `fsync` / `fdatasync` / `dup` | L1515 / L1307 / L1307 | `fd: number` |
| `copyFile` / `copyFileSync` | L761 / L855 | `src: string \| number, dest: string \| number`，注释写 "Path **or FD** of the file" |

**看到的格局**：写数据的通路（fd 语义）是齐的，
**但"由路径/URI 生成这个 fd"的入口里，只有 `open` 一家明确支持 URI**，
其余（AtomicFile / createStream / rename / unlink）全都被注释限定成沙箱路径。

### 据此提出的问题

**Q1（最核心）：新建子文件**
已授权目录 `dirUri`，要在它下面新建一个 `新笔记.md`，
官方推荐做法是下面哪一条？请明确支持与否，并给出可行的那条的正确用法：
- (a) `fs.open(dirUri + '/' + encodeURIComponent(name), OpenMode.WRITE_ONLY | OpenMode.CREATE | OpenMode.TRUNC)` 直接 open 一个**尚不存在的子文件 URI**？—— 若可行，URI 拼接的**规范**是什么（要不要 encodeURIComponent？分隔符/特殊字符怎么处理？有没有类似 `FileUri` 的工具可以安全地拼子路径）？
- (b) 只能 Native 侧 `openat(dirFd, name, O_CREAT | O_WRONLY, 0666)`？
- (c) 沙箱内写好 → `fs.copyFileSync(sandboxPath, ?)` 拷进去（dest 见 Q5）？
- (d) 其他官方路径？

**Q2：覆盖写已存在的子文件（含截断）**
对一个**已存在**的 md：
- 能否 `fs.open(childUri, OpenMode.WRITE_ONLY)` 拿到可写 fd？`childUri` 由 `dirUri` 拼接得到时是否仍然被授权覆盖（授权是否顺延到子文件，上一轮只验证了"读"顺延）？
- 新内容**比原内容短**时，正确做法是 `fs.truncateSync(fd, newLen)` 吗（`truncate` 收 fd，看起来可行）？还是 `WRITE_ONLY | TRUNC` 开文件时由系统处理？

**Q3（我们最在意）：原子替换怎么做**
`AtomicFile` 看起来不可用于该场景（path 口径是沙箱路径 + 实测 code=-1）。那么要保证
"写一半崩溃不留半截笔记"，官方推荐哪条？各自的官方支持状态请明确：
- (a) Native 侧：同目录写 `xxx.md.tmp` → `fsync` → `renameat(dirFd, tmp, name)` 覆盖（**我们倾向这条**）
- (b) ArkTS 侧：`open(childUri, CREATE)` + `write` + `fsync` 直接原地覆盖（非原子，崩溃即半截）
- (c) 沙箱内 `AtomicFile` 写完整 → `copyFileSync` 到外部（半原子：copy 本身不原子）
- (d) 有其他用于外部文件的原子写能力被我们漏掉了？
- 附带：**如果我把 Q3 做成 (a)，这个用法（NDK POSIX）在应用上架审核时是否会被驳回？**

**Q4：删除 / 重命名**
ArkTS 的 `unlink` / `rename` 又不收 URI。是否同样必须 Native（`unlinkat(dirFd, name)` / `renameat` ）？
另外有个政策层面的担心：**三方应用是否有权限删除用户授权目录下的文件**？
系统是否需要二次确认弹窗？（我们不希望用户每次删笔记都要再授权一次）

**Q5：`copyFileSync` 的 dest 到底支不支持 URI？**
d.ts 只写了 "Destination path of the file **or FD of the file created**"，没像 `open` 那样明说 "or URI"。
请确认：
- `dest` 传**拼接的子文件 URI** 是否可行（即"沙箱写 → 拷进授权目录"这条通路是否成立）？
- `dest` 传 fd 时，这个 fd 必须由 `open(url, CREATE)` 先建、且此时 dest 就成了"写入目标"语义吗？

**Q6：Native 通路的长期有效性**
若上述写操作只能走 NDK POSIX（`openat` / `write` / `fsync` / `renameat` / `unlinkat`），请确认：
- 这条路在 API 24–26 是否被**官方认可**（我们担心它是"能用但未承诺"的实现细节，某个版本被关掉）？
- ArkTS 侧后续是否有计划补齐：① `listFile*` 支持 URI；② `rename`/`unlink`/`createStream` 支持 URI；③ 提供面向外部目录的原子写 API？如果有计划，版本号是多少？（这会影响我们是现在写 Native 还是等官方 API）

**Q7（顺带，非阻塞）：外部目录变更感知**
我们是笔记应用，还有个诉求：用户在 PC / 别的 App 修改了同一个 md，我们希望 App 能做增量同步。
ArkTS 侧似乎没有对外部目录的监听能力（`FileObserver` 之类只覆盖应用沙箱？）。请确认：
- 是否有官方的**外部目录变更通知**（媒体库观察者 / FileManagement 的变更回调 / `DocumentScanner` 之类）可用于 `Download` 这类 documents 目录？
- 如果只能轮询，官方是否推荐我们对 `openat` 拿到的每个文件做 `stat` 比对 mtime/size？有没有省电/性能上的官方建议粒度？

（Q7 不影响我们当前版本落地，答不了可以先跳过。）

### 已排除（不用再建议）

- `AtomicFile` / `createStream` / `unlink` / `rename` / `listFile*`：d.ts path 口径均为沙箱路径（本轮新查，行号见上表）
- `fs.listFileSync(URI)`：上一轮已由你们确认不支持 URI 且无支持计划
- `@ohos.file.fileAccess`：已废弃且仅 systemapi，三方不可用
- `@ohos.fileio` 的 `opendir` / `Dir.read`：API 9 已废弃，且同样只收沙箱路径
- 改产品形态（逐个选文件 / 导入沙箱）：上一轮你们答 Q5-C 明确说不需要

### 关于上轮答复的反馈（供参考，希望能提升答复精度）

上一轮的答复方向是对的、我们也实测闭环了，但示例代码里有
**`fs.OpenMode.READ_DIR` 这个不存在的枚举**（真实是 `OpenMode.DIR = 0o200000`，d.ts L199），
照抄编译不过。这是我们第 4 次遇到"方向对、具体 API 名错"的情况。
**所以这次如需给出示例代码，烦请核对到 `@ohos.file.fs.d.ts` 的真实符号与行号**，
或给出可查证的文档链接；我们这边会照旧在设备上回验一遍再落地。

### 附：我们打算做的对照实验（若你给的答复不同我们会回来追一句）

在核实页加四个对照，各跑一次并把 errno 记下来：
1. `AtomicFile(dirUri)` / `AtomicFile(dirUri + '/x.md')` —— 预期都失败（已知 code=-1）
2. `openSync(dirUri + '/probe_write.md', WRITE_ONLY|CREATE|TRUNC)` → `writeSync` → 回读
3. `openSync(已存在的childUri, WRITE_ONLY)` → `writeSync` → `truncateSync(fd, len)`
4. Native `openat(dirFd, 'probe_native.md', O_CREAT|O_WRONLY)` → `write` → `renameat` 覆盖
````

---

## 投递渠道建议

沿用上一轮成功的渠道：**华为开发者联盟技术支持在线提单**为主，社区问答版作为交叉验证。

---

## 拿到答复后：回填清单

| 答复要点 | 回填到 |
| --- | --- |
| 新建 / 覆盖 / 原子的官方做法 | `api_notes.md` **T6**（写入链路）由 ❓ 改 ✅/❌，给出可执行结论 |
| Q6 Native 通路长期有效性 | 决定要不要把写入也塞进 `vaultdir_napi`；若官方认可 → 复用现有 target |
| Q3 原子替换方案 | 决定 `saveNote` 的实现形态（Native renameat vs 原地 write） |
| Q7 变更感知 | 决定是否新开一轮 `外部目录变更感知` 咨询 / 或降级为轮询 |
| 答复中出现的**任何 API 名** | 逐条回 d.ts 核一遍（见下方硬伤统计），并入 `ExternalDirProbePage` 实测 |

落地硬约束：**答复要先用本机 SDK d.ts 核一遍，再在 XT2 上跑一遍，两个都过才写进业务代码。**

---

## 官方答复硬伤统计（累计 4 次）

| 次序 | 场景 | 答复给的 | 真实情况 | 影响 |
| --- | --- | --- | --- | --- |
| 1 | 折痕接口 | `Rect` 可直接构造 | 需用具体 Rect 类型/不同成员名 | 编译失败 |
| 2 | 构建配置 | `build-profile` 的 `name` 字段 | 字段名/位置不符 | 构建失败 |
| 3 | 折痕 | `getLiveCreaseRegion()` 挂在某对象上 | 挂错对象 | 运行时拿不到 |
| 4 | 目录枚举 | `fs.OpenMode.READ_DIR` | **不存在**；真实 `OpenMode.DIR = 0o200000`（d.ts L199），开目录用 `READ_ONLY \| DIR` | 照抄编译不过 |

**规律**：**方向性结论可信度高；具体 API 名 / 签名 / 字段名必须回 SDK d.ts 核。**
所以本轮正文明确要求对方给出可查证出处。
