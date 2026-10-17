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
| 6 | 同步**只用「JS 自定义 http client 转发到 `@ohos.net.http`」**，拦截方案已否决 | `getRequestBody()` 返回 string，二进制 packfile 有风险 |
| 7 | packfile / 大文本走 **WebMessagePort + ArrayBuffer + 分块（4MB）**；`runJavaScript` 只走控制指令 | `runJavaScript` 返回值是 string，上限未记载 |
| 8 | git 容器**常驻**：`Stack` + `visibility(Hidden)`，**不用 `NodeContainer` 动态卸载** | 卸载会销毁 Web 实例、JS 状态全丢 |
| 9 | git 桥接**先主线程**；要进 Worker 必须把 port **transfer** 进去 | Worker 内无 window，拿不到 `javaScriptProxy` |
| 10 | 原子写用 **`fileIo.AtomicFile`**，不要 tmp + `renameSync` | `renameSync` 的覆盖/原子性官方未记载 |
| 11 | 令牌存 **`@kit.AssetStoreKit`**（敏感值只放 `SECRET`），不写明文 | 无需权限；`ALIAS` 不加密 |
| 12 | 异步渲染下 **Web 组件宽高 ≤ 7680px 物理像素** | 超过会白屏；三栏各 1/3 约 1061px，安全 |
| 13 | 沙箱内读写**不需要任何权限**，只申请 `INTERNET` 就够 | 官方确认 |
| 14 | 路径**只能**由 `context.filesDir` 等 Context 属性拼出，禁止硬编码沙箱目录字符串；库内相对路径 → 绝对路径**只用一层解析器** | 官方强调；UI 与意图执行器共用，别各拼一遍 |
| 15 | 端侧意图 / AI 写文件**同样走 `AtomicFile`** —— 官方示例的 `openSync(READ_WRITE\|TRUNC)` 会写坏文件 | 示例违反硬约束 10，别照抄 |

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
  prototype/index.html        单文件交互原型（浏览器直接打开）
tools/build.ps1               命令行构建 HAP（不用开 DevEco）
tools/gen_app_icon.py         程序化生成分层图标
```

## 命令

```powershell
.\tools\build.ps1              # 构建 debug HAP（已设好 JAVA_HOME → DevEco jbr）
.\tools\build.ps1 -Task clean
.\tools\build.ps1 -OhpmInstall # 缺依赖时
```

```bash
cd web/gitbridge
node build.mjs                 # 改了 src/ 后必做：重新打包 rawfile 产物
npm run smoke                  # node 冒烟（真 clone）
```

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
- 版本发布后**冻结需求文档**（它是承诺记录），遗留问题进 `验收记录.md` 或回流需求池

## 已知坑

1. **命令行构建必须设 `JAVA_HOME`** → 用 `tools\build.ps1`，否则 `spawn java ENOENT`。
2. **`.codegenie/` 是 IDE 误建的嵌套空 git 仓库**，会让 `git add -A` 报 `does not have a commit checked out`。已忽略，别去删。
3. **改完 `web/gitbridge/src` 必须重新打包并把产物一起提交**，否则真机跑旧代码。
4. **base64 只解一层**：桥接 `channel.onResult` 内部已解过，调用方别再解。
5. **Gitee 用 Basic（`username:私人令牌`），GitHub 用 `Bearer <PAT>` 且用户名留空** —— 两者不同。
6. **ArkTS 不允许无类型对象字面量**，HTTP 请求等要显式声明类型。
7. ⚠️ **CodeMirror 6 基于 `contenteditable`，官方建议优先 `textarea`**（输入法兼容性更好）。M0.5 必须两者对比实测，否则 M2 可能被卡死。

## 规范

- 中文文件名：**下划线，不用空格与连字符**。
- 涉及鸿蒙 API 的结论必须能指到 `docs/harmonyos/api_notes.md` 的具体条目，**不许凭记忆编接口名**。
- 决策写进 `docs/`（见开工前第 2 条），不要写进本文件。
