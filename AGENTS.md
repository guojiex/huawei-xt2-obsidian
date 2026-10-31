# AGENTS.md —— 本仓库开发手册

> **曜石笔记**：为华为 XT2 三折叠做的本地 Markdown 笔记应用。
> ArkTS · Stage 模型 · **API 24**（`compatibleSdkVersion 6.1.1(24)`）· 包名 `com.jxg.huaweiobsidian`。
>
> 📌 **本文件只讲「怎么在这个仓库里干活」**：硬约束、命令、坑、工作流。
> **决策、进度、里程碑一律看 `docs/`**（本文件不复制它们，避免两处不一致）。
>
> ⚠️ 鸿蒙很多行为文档没写，凭通用移动端经验猜会直接写错 —— 先读 `docs/harmonyos/`。

## 开工前读什么

| 顺序 | 文件 | 看什么 |
| --- | --- | --- |
| 1 | `docs/mvp_design.md` | 范围、架构、多库模型、**里程碑与进度（第 7 节）**、验收标准 |
| 2 | `docs/open_questions.md` | **已定决策总表**（别重新讨论）+ 待拍板项 + TODO 挂起 |
| 3 | `docs/harmonyos/api_notes.md` | 鸿蒙行为结论的**单一真源**，带 ✅/⚠️/❓ |
| 4 | `docs/releases/README.md` | **版本化开发规则**；再读当前版本的 `vX.Y/需求文档.md` |
| 5 | `docs/harmonyos/README.md` | 问答规则：提问前先查，别重复问 |
| 6 | 本文件 §硬约束 + §已知坑 | 违反会编译失败或返工 |

## 硬约束

| # | 约束 | 原因 |
| --- | --- | --- |
| 1 | **ArkTS + Stage 模型**，禁止 FA 模型 / JS | 官方已不推荐 FA |
| 2 | **只用 API ≤ 24 的接口** | 例：`listFileExt`（fileFilter）是 API 26，只能用 `listFileSync` 自己过滤 |
| 3 | 断点用 `window.on('windowSizeChange')` + `px2vp()`，**不要用 `getFoldDisplayMode()` 做形态分支** | 官方推荐统一断点机制，该接口不返回全部形态值 |
| 4 | 三折叠在系统里**始终是 `phone`**，`deviceTypes` 保持 `["phone","tablet","2in1"]` | 全展开 10 英寸也不会变成 tablet/2in1 |
| 5 | **三栏自绘**，禁用 `FoldSplitContainer` | 已否决，见决策总表 |
| 6 | 同步优先验证并采用 **Native libgit2**；仅当 Native 经验证不可行时评估备选。若使用现有 Web 路线，只用 JS 自定义 HTTP client 转发到 `@ohos.net.http`，拦截方案已否决 | `getRequestBody()` 返回 string，二进制 packfile 有风险 |
| 7 | Web 备选的 packfile / 大文本走 **WebMessagePort + ArrayBuffer + 分块（4MB）**；`runJavaScript` 只走控制指令 | `runJavaScript` 返回值是 string，上限未记载 |
| 8 | Web 备选的 git 容器**常驻**：`Stack` + `visibility(Hidden)`，**不用 `NodeContainer` 动态卸载** | 卸载会销毁 Web 实例、JS 状态全丢 |
| 9 | Web 备选的 git 桥接**先主线程**；要进 Worker 必须把 port **transfer** 进去 | Worker 内无 window，拿不到 `javaScriptProxy` |
| 10 | **`AtomicFile` 是完整性方案，不是 HarmonyOS 强制 API。** 更新已有文件、失败时必须保留旧内容，或不能让目标路径出现半成品时用 `fileIo.AtomicFile`；不要自行用 tmp + `renameSync` 模拟原子替换。对新建且唯一命名的图片附件，可在 API ≤24 接口核实后用 `fileIo.copyFile` 从已授权源 fd 复制到解析器给出的新目标；等待复制完成、校验后再插入 Markdown 引用，失败时删除可能的半成品。复制中断可能留下不完整目标；若产品不接受此风险则用 `AtomicFile`。 | `AtomicFile` 保留原文件的失败回滚语义见 `api_notes.md` C1；Picker URI 授权见 Q1。`copyFile` 默认覆盖同名目标，必须使用新路径；API 声明与 URI/fd 用法须以当前 SDK 和官方资料核实 |
| 11 | 令牌存 **`@kit.AssetStoreKit`**（敏感值只放 `SECRET`），不写明文 | 无需权限；`ALIAS` 不加密 |
| 12 | 异步渲染下 **Web 组件宽高 ≤ 7680px 物理像素** | 超过会白屏；三栏各 1/3 约 1061px，安全 |
| 13 | 沙箱内读写**不需要任何权限**；只申请 `INTERNET` 就够。**已拍板例外（2026-10-31）**：v1.5 外部目录持久授权需要 `ohos.permission.FILE_ACCESS_PERSIST`，已在 `module.json5` 声明 —— 沙箱库不受影响，非 v1.5 功能**不得**新增任何权限 | 官方确认；例外依据见 `docs/harmonyos/api_notes.md` T2。**发布上架前必须完成 AGC 受限权限申请**，调试期靠含 ACL 的 debug profile |
| 14 | 路径**只能**由 `context.filesDir` 等 Context 属性拼出，禁止硬编码沙箱目录字符串；库内相对路径 → 绝对路径**只用一层解析器** | 官方强调；UI 与意图执行器共用，别各拼一遍 |
| 15 | 端侧意图 / AI 修改已有笔记**同样走 `AtomicFile`** —— 禁止用 `openSync(READ_WRITE\|TRUNC)` 覆盖原内容；新建唯一附件按硬约束 10 选择写入方式 | 这是保护现有笔记内容的工程策略，不是 HarmonyOS 平台强制要求 |
| 16 | 埋点用**原生 `hiAppEvent` + `UIObserver`**，不引第三方 SDK；**笔记内容一律禁止进埋点**（标题/文件名/路径/正文/字数/标签全禁） | 个人知识库的隐私红线；采集内容会抬高合规与审核成本 |
| 17 | 颜色 / 圆角 / 间距 / 字号**只引用 token**（`app.color.*` / `app.float.*` 或常量模块），**组件里禁止散写数值**；唯一设计真源是 `docs/prototype/v2/index.html` 的 `:root` / `[data-theme="dark"]`。编辑器、预览和原生资源按明确映射同步；组件里不散写数值，具体差异与验证见 v0.9 迁移清单。v1 设计稿保持从工作树删除；历史对照只读 Git 历史，不恢复或归档旧稿 | 散写会让深色模式与换主色变成全局搜替换（2026-10-17 定，落地在 v0.2） |
| 18 | 禁止凭记忆写 **`Hds*` 组件名**或 **`sys.symbol.*` 资源 id**；UI Design Kit / Symbol 未核实前用自绘兜底 | 同铁律：编造 API 会直接编译失败；待核实项见 `api_notes.md` **I 组** |
| 19 | **`build-profile.json5` 永久保持 `"signingConfigs": []`**；签名改由工程级 **`hvigorfile.ts` 的 `config.ohos.overrides.signingConfig`** 注入，凭据只存在于 `.local/local-signing.json`（已 gitignore） | DevEco 自动签名会往 `build-profile.json5` 回写**密码明文 + 本机绝对路径**，而该文件**不能 ignore**（移除后 hvigor 报 `00304035 Not Found`，实测）。⚠️ **签名链必须同源（2026-10-31 实测踩到的第二个签名坑）**：
`profile(.p7b)` 里带的 development-certificate 必须与 `certpath(.cer)` / `storeFile(.p12)`
是**同一个开发证书**，否则装机报 `code:9568322 signature verification failed due to not
trusted app source`，**连真机都部署不上去**。当时是把 profile 换成了从别处下载的含 ACL
的 p7b（证书 SHA1 `65E4…`），而本机 keystore 属于 DevEco 自动签名那套（`C7FA…`），两者
不同源。查法：解析 p7b 的 `bundle-info.development-certificate` 与 `certpath` 证书算 SHA1 比对。
工程已支持 `$env:OHOS_SIGNING_PROFILE = 'file-access'` 切到含 ACL 的那套，但**只有当你手上有
与该 profile 配套的 p12/cer 时才用得起来**；日常（`default`）就用 DevEco 自动签名那套。

机制与 ⚠️ 运行时 schema（**只接受 `material` / `type`，写 `name` 构建失败**）见 `api_notes.md` **I4**；日常用 `.\tools\signing.ps1 -Import` 抽凭据，`-InstallHook` 装 pre-commit 兜底 |

## 目录地图

```
AppScope/                     应用级配置（app_name = 曜石笔记）
entry/src/main/ets/
  entryability/               EntryAbility（断点监听注册处）
  git/                        GitBridgeModels / GitFsBackend / GitHttpBackend / GitBridgeView
  pages/                      Index.ets、SyncPage.ets
  resources/rawfile/gitbridge/index.html   ← 构建产物，已入库（268KB）
web/gitbridge/                Web 内 isomorphic-git 桥接层（独立 npm 包源码）
  src/                        codec / channel / fsBridge / httpBridge / index
  test/node_smoke.mjs         node 冒烟（真 clone GitHub / Gitee）
docs/
  mvp_design.md               设计主文档（含进度与里程碑）
  requirements_backlog.md     需求池（所有想做的，未分配）
  releases/                   ★ 版本档案：vX.Y/需求文档.md（**落码前必看**）
  open_questions.md           已定决策总表 + 待决 + TODO 挂起
  harmonyos/                  ★ 鸿蒙知识库：api_notes.md（真源）/ qa/ / prompts/
  prototype/v2/index.html     当前单文件交互原型（浏览器直接打开）
spec/                        v0.1 的 spec/plan/tasks（**执行计划，不是承诺记录**）
tools/
  build.ps1                   命令行构建 HAP（不用开 DevEco）
  install.ps1                 装 HAP 到真机 / 拉起
  signing.ps1                 签名配置挂载(-On) / 还原(-Off) / 状态(-Status) / 装钩子
  tests/                      全部 Node/Python 测试（test_*.mjs、test_changelog.py、lib/source.mjs）
  generators/                 生成器与图标脚本（build_*.py、gen_*.py）
.local/                       ★ 本地私有：签名版 build-profile 备份（已 gitignore）
```

## 命令

```powershell
.\tools\build.ps1              # 构建 debug HAP（已设好 JAVA_HOME → DevEco jbr）
.\tools\build.ps1 -Task clean
.\tools\build.ps1 -OhpmInstall # 缺依赖时
.\tools\install.ps1 -Run    # 装到真机并拉起（前置：DevEco 里做过自动签名）
```

```powershell
# 签名：凭据放 .local，build-profile.json5 永久干净，构建即签名
.\tools\signing.ps1 -InstallHook   # 首次：装 pre-commit，凭据被 git add 直接拒提交
.\tools\signing.ps1 -Import        # DevEco 自动签名后跑一次：抽凭据到 .local 并还原干净版
.\tools\signing.ps1 -Status        # 看三态（build-profile 干净？本地凭据在？钩子装了？）
.\tools\build.ps1                  # 直接就是签名构建（hvigorfile.ts 注入）
```

### 发布签名（上架 AGC，2026-10-31 落地）

调试凭据与发布凭据**分开两套**，互不通用：发布签名的包装不上真机，调试签名上不了架。

```powershell
$env:OHOS_SIGNING_PROFILE = 'release'   # 让 hvigorfile.ts 改读 .local/release-signing.json
.\tools\build.ps1 -Release              # 发布构建（默认 assembleApp，强制 arm64）
```

材料放 `.local/release-signing/`（`yaoshi_release.p12` / `.csr` / `.cer` / `.p7b`，密码同目录
`keystore.pass.txt`），与 `build-profile.json5` 无签名配置的做法一致。

⚠️ **三个实测硬约束**（都踩过，别再犯）：

0. **密码必须是 DevEco 密文，不能是明文**。hvigor 的 `getKeyStorePwd()` **无条件**把
   `material.storePassword` 当 hex 密文做 AES-128-GCM 解密，密钥取自
   `dirname(storeFile)/material`（必须含 `fd/`(3 项)、`ac/`(1 文件)、`ce/`(1 文件)）。
   填明文会在 SignHap 阶段报
   `00308018 … ENOENT: no such file or directory, stat '<storeFile 同级目录>\material'`。
   密文生成：`tools\encode_signing_pwd.mjs`（算法照 DevEco 的 `decipher-util.js` 复刻，
   密钥只依赖 material 内容，与密码本身无关）。发布材料目录里那份
   `.local/release-signing/material` 是从 `.ohos\config\material` 复制来的，**别删**。

1. **`storePassword` / `keyPassword` 必须 ≥ 32 位**，否则签名阶段直接失败：
   `00303116 Configuration Error … length of the storePassword or keyPassword field … is less than 32`。
   生成时就给 40 位纯字母数字。
2. **改密钥库口令必须「先写密码文件，再执行 keytool」**。反过来的话一旦中途失败，
   库已换新口令而新口令没落盘 → 私钥永久不可恢复 → 证书 + Profile 全部作废，只能重新申请。
   另外 **PKCS12 不支持 `keytool -keypasswd`**（`UnsupportedOperationException`），
   改 `-storepasswd` 就等于同时改了 key password。

```bash
cd web/gitbridge
node build.mjs                 # 改了 src/ 后必做：重新打包 rawfile 产物
npm run smoke                  # node 冒烟（真 clone）
```

## Native 构建与跨机器 ABI（重要）

App 的 git 能力走 `native/git2_napi`（libgit2 编成 so），**`.build/` 是 gitignore 的**：
换机器 / 全新 clone 之后第一次构建 HAP 之前必须先编 native，否则 CMake 直接
`FATAL_ERROR: Build native/git2_napi before assembling the App HAP`。

```bash
./native/git2_napi/build.sh                    # 默认 arm64-v8a，真机 / Apple Silicon Mac 用这个
OHOS_ARCH=x86_64 ./native/git2_napi/build.sh   # 仅本机 Windows 模拟器需要，见下
export OHOS_NDK=...                            # Windows 本机要显式指向 DevEco 的 native SDK
```

| 宿主 | 模拟器镜像架构 | 能否装 arm64-only HAP |
| --- | --- | --- |
| XT2 真机 / Mac Apple Silicon（arm64 镜像） | arm64 | ✅ 直接用默认配置 |
| **Windows 本机**（DevEco 只提供 x86 镜像） | x86_64 | ❌ `bm install` 报 code:9568347 需要开覆盖 |

仓库提交的 `entry/build-profile.json5` **永远只有 `arm64-v8a`**，不要为了本机环境改它。
Windows 本机要跑模拟器时：

```powershell
bash ./native/git2_napi/build.sh                             # arm64（默认架构，一次即可）
OHOS_ARCH=x86_64 bash ./native/git2_napi/build.sh            # x86_64，产物放 .build/out/libs/x86_64
.\tools\abi.ps1 -Dual          # ★ 推荐：同时编两种 ABI，模拟器与 XT2 真机共用同一个包
.\tools\abi.ps1 -Set x86_64    # 只编 x86_64（不再也为真机出包时用）
.\tools\abi.ps1 -Reset         # 恢复 arm64-only（出上架包前必做）
.\tools\abi.ps1 -Status        # 看当前状态
```

`-Dual` 的前提是**两个架构的 libgit2 都已编过**（`.build/out/libs/` 下要有 `arm64-v8a/` 与
`x86_64/` 两个目录）。开着的包同时含两份 so（约 18MB vs 单架构约 10MB），好处是不用来回切：
本机模拟器与 XT2 真机装同一个 HAP 都行。

> ⚠️ **IDE 里点「运行」报 code:9568347 时的第一件事**：先跑 `.\tools\abi.ps1 -Status`。
> 覆盖是**关着**的（该文件被 `build.ps1 -Abi` 的 finally 撤回了，或换过机器 / 清过
> `.local/`），构建就会退回 arm64-only → x86_64 模拟器拒装。2026-10-31 第二次踩到。
> `.local/` 是 gitignore 的本地目录，不含他改动时不该被清理。

原理：`.local/local-abi.json`（gitignore）由 **entry/hvigorfile.ts** 通过
`overrides.buildOption.externalNativeOptions.abiFilters` 注入 hvigor pipeline。
**必须注入在 pipeline 里** —— 只改命令行脚本没用，IDE 点「运行」走的是它自己的
hvigor，读不到脚本参数（这是 2026-10-31 踩过的坑：改了 build.ps1 后 IDE 部署照旧失败）。

单次覆盖用 `.\tools\build.ps1 -Abi x86_64`（只管这一次，跑完撤回）；
想让 IDE 也能部署就用 `abi.ps1 -Set`，它能一直生效到 `-Reset`。

> x86_64 模拟器只能用来验收 UI，**它的证据不能外推到 API 24 / XT2 真机**。

## 静态内容生成

- 样例真源：`sample_vault/notes/` + `manifest.json`，运行 `python3 tools/generators/build_sample_vault.py`。
- 版本记录真源：`changelog.json`，运行 `python3 tools/generators/build_changelog.py`；App 包版本仍取 `AppScope/app.json5` / 运行时包信息。
- 两个脚本都提供 `--check`，提交前检查并连同生成产物提交；不要手改生成的 ETS、CHANGELOG.md 或原型标记区。
- 复用说明见 `docs/engineering/数据驱动页面.md`，不把个人笔记、令牌或运行时状态写入静态产物。

## 鸿蒙知识库工作流

与官方 Agent 的问答**一律落 `docs/harmonyos/`**，规则见其 `README.md`，摘要：

1. **提问前**查 `api_notes.md` 与 `qa/` 索引，问过的不重复问
2. 提问从 `prompts/` 最新一份复制改名 `prompts/YYYY-MM-DD_主题_APIxx.md`
3. 拿到回答：先存档 `qa/YYYY-MM-DD_主题_APIxx.md` → 再提炼进 `api_notes.md`（每条带 ✅/⚠️/❓）→ 更新索引
4. 真机验证后把 ⚠️/❓ 改成 ✅ 并写**实测值**
5. 结论只准链接不准复制到别的文档；被推翻的加删除线保留（不删）

## 版本化开发（详见 `docs/releases/README.md`）

- **一个版本一个目录**（`v0.1` / `v0.2` …），每个目录必须有 `需求文档.md`
- **任何落码都必须能对应到当前版本需求文档里的某条需求** —— 需求池里没分配进版本的不许开工
- **开新版本 = 先建目录 + 先写需求文档，再动手写代码**（不许先写代码后补文档）
- 需求**只能从 `requirements_backlog.md` 分配进版本**，不许在版本目录里凭空新增
- **交给别人实现**：用该版本目录的 `实现提示词.md`（自包含，含防编造约束）；没有就照 `v0.1/实现提示词.md` 先写一版
- 版本发布后**冻结需求文档**（它是承诺记录），遗留问题进 `验收记录.md` 或回流需求池

## 已知坑

1. **命令行构建必须设 `JAVA_HOME`** → 用 `tools\build.ps1`，否则 `spawn java ENOENT`。
2. **`.codegenie/` 是 IDE 误建的嵌套空 git 仓库**，会让 `git add -A` 报 `does not have a commit checked out`。已忽略，别去删。
3. **改完 `web/gitbridge/src` 必须重新打包并把产物一起提交**，否则真机跑旧代码。
4. **base64 只解一层**：桥接 `channel.onResult` 内部已解过，调用方别再解。
5. **Gitee 用 Basic（`username:私人令牌`），GitHub 用 `Bearer <PAT>` 且用户名留空** —— 两者不同。
6. **ArkTS 不允许无类型对象字面量**，HTTP 请求等要显式声明类型。
7. ⚠️ **CodeMirror 6 基于 `contenteditable`，官方建议优先 `textarea`**（输入法兼容性更好）。M0.5 必须两者对比实测，否则 M2 可能被卡死。
8. **`.ps1` 必须是 UTF-8 with BOM**：PowerShell 5.1 在无 BOM 时按 GBK 读脚本，中文注释里的字节会被误解析成引号，报出「字符串缺少终止符」这类看起来毫无关联的错。新建 .ps1 后检查一次。
9. **PowerShell 里别用 `$profile` 当变量名**（它是自动变量 = 用户配置文件路径）；函数返回**单元素数组会被解包成标量**，`$x[0]` 会变成字符串首字符。
10. **改动 UI 开关类能力要想到 IDE 那条路**：命令行脚本的参数 IDE 读不到，必须注入 hvigor pipeline（见上面 ABI 覆盖）。

## 规范

- 中文文件名：**下划线，不用空格与连字符**。
- 涉及鸿蒙 API 的结论必须能指到 `docs/harmonyos/api_notes.md` 的具体条目，**不许凭记忆编接口名**。
- 决策写进 `docs/`（见开工前第 2 条），不要写进本文件。
