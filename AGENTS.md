# AGENTS.md —— 给下一个 Agent 的仓库开发手册

> **项目**：曜石笔记 —— 运行在**华为 XT2 三折叠**上的本地 Markdown 笔记应用（Obsidian 式的纯文件库）。
> **包名** `com.jxg.huaweiobsidian` · Stage 模型 · ArkTS · **API 24**（`compatibleSdkVersion 6.1.1(24)`）。
>
> ⚠️ 本文件是**开工前必读**。鸿蒙的很多行为文档没写、只能靠问官方或真机实测，凭通用移动端经验猜会直接写错。

---

## 0. 开工前按这个顺序读

| 顺序 | 文件 | 看什么 |
| --- | --- | --- |
| 1 | `docs/mvp_design.md` | 范围、架构、多库模型、里程碑（M0→M5）、验收标准 |
| 2 | **`docs/harmonyos/README.md`** | 鸿蒙知识库的规则（提问前先查，别重复问） |
| 3 | **`docs/harmonyos/api_notes.md`** | 所有鸿蒙行为结论的**单一真源**，带 ✅/⚠️/❓ 标记 |
| 4 | `docs/open_questions.md` | 待拍板的、TODO 挂起的、要追问鸿蒙的 |
| 5 | 本文件 §2 硬约束 + §5 已知坑 | 违反会编译不过 / 返工 |

---

## 1. 项目定位

- **核心形态**：三折叠单屏 / 双屏 / 三屏三种形态，三屏态是「文件树 | 编辑器 | 预览」三列横排。
- **数据模型**：笔记就是**纯 `.md` 文件树**，放在应用沙箱 `filesDir/vaults/<库名>/`，与 PC 端 Obsidian 的 vault 结构一致（导出不用转换）。
- **多库**：`vaults/local` 是默认本地库；Git 库是 `vaults/<仓库名>`，各有独立远端。**显示名 = 目录名**，不做映射。
- **同步**：Web 组件内跑 isomorphic-git，fs / http 桥接到 ArkTS。冲突**推 `xt2` 分支**，手机上不做合并 UI（PC 端解）。

---

## 2. 硬约束（违反会编译失败或埋雷）

| # | 约束 | 原因 |
| --- | --- | --- |
| 1 | **ArkTS + Stage 模型**，禁止 FA 模型 / JS 扩展型 | 新工程只有 Stage，官方已不推荐 FA |
| 2 | **只用 API 24 及以下的接口**。看到"API 26 才有"的接口一律不用 | 例：`listFileExt`（带 fileFilter）是 API 26，我们只能用 `listFileSync` 自己按后缀过滤 |
| 3 | 三档断点靠 `window.on('windowSizeChange')` + `px2vp()`，**不要用 `getFoldDisplayMode()` 做形态分支** | 官方明确建议用统一断点机制；该接口不返回全部形态值 |
| 4 | 三折叠**在系统里始终是 `phone`**，`deviceTypes` 保持 `["phone","tablet","2in1"]` 不用改 | 全展开 10 英寸也不会变成 tablet/2in1 |
| 5 | **三栏自绘**，禁用 `FoldSplitContainer` | 已否决（见 §4），别再提 |
| 6 | git 桥接**先放主线程**；真要进 Worker，必须把 `WebMessagePort` **transfer** 进去再通信 | Worker 内没有 window，拿不到 `javaScriptProxy` 注入的对象；但 transferred MessagePort 可用 |
| 7 | 原子写用 **`fileIo.AtomicFile`**，不要 tmp + `renameSync` | `renameSync` 的覆盖/原子性官方未记载 |
| 8 | 访问令牌存 **`@kit.AssetStoreKit`**，敏感值只放 `SECRET`，不写明文、不进首选项 | 无需任何权限；`ALIAS` 不加密 |
| 9 | 同步**只用**「JS 侧自定义 http client 转发到原生 `@ohos.net.http`」方案，**拦截方案（`onInterceptRequest`）已否决** | `getRequestBody()` 返回 **string**，二进制 packfile 有编码损坏风险 → push 不可靠（2026-10-17 定案，见 `docs/harmonyos/api_notes.md` B4） |
| 9b | git 计算容器要**常驻**：用 `Stack` + `visibility(Hidden)`，**不要用 `NodeContainer` 动态卸载** | 卸载会销毁 Web 实例、JS 状态全丢，重挂会重新加载页面 |
| 10 | 异步渲染下 **Web 组件宽高 ≤ 7680px 物理像素** | 超过会白屏；三栏各 1/3 时约 1061px，安全 |
| 11 | **同步只做前台**，不申请后台长时任务权限 | 前台 clone/push 无需额外权限（Q4 已决，后台同步转需求池） |
| 12 | 沙箱内读写**不需要任何权限**，当前只申请 `INTERNET` 是对的 | 官方确认 |

---

## 3. 目录地图

```
AppScope/            应用级配置（app_name = 曜石笔记）
entry/               主模块
  src/main/ets/
    entryability/    EntryAbility（断点监听在这里注册）
    git/             GitBridgeModels / GitFsBackend / GitHttpBackend / GitBridgeView
    pages/           Index.ets、SyncPage.ets
  src/main/resources/rawfile/gitbridge/index.html   ← 构建产物，已入库（268KB）
web/gitbridge/       【独立 npm 包】Web 内 isomorphic-git 桥接层的源码
  src/               codec / channel / fsBridge / httpBridge / index
  build.mjs          esbuild 打包 → 上面的 rawfile
  test/node_smoke.mjs  node 冒烟（真 clone GitHub / Gitee）
docs/
  mvp_design.md      设计主文档
  requirements_backlog.md  需求池（含"先不做"的项）
  open_questions.md  待决清单 + TODO 挂起项
  harmonyos/         ★ 鸿蒙知识库（问答与结论，见 §8）
  prototype/index.html  单文件交互原型（三形态 × 视图 × 明暗）
  toolchain.md       工具链
tools/
  build.ps1          命令行构建 HAP（不用开 DevEco）
  gen_app_icon.py    程序化生成分层图标
```

---

## 4. 已定决策（**别再重新讨论**）

| 决策 | 结论 | 时间 |
| --- | --- | --- |
| 编辑器方案 | **A：Web + CodeMirror 6**，先过 M0.5 spike | — |
| 三栏布局 | **自绘** Row/Column + 等分（双屏 50% / 三屏各 1/3），折痕先只做标注，真机校准后写常量表 | 2026-10-17 |
| `FoldSplitContainer` | ❌ **否决**。它的"三分栏"是侧列贯穿 + 另两栏上下堆叠；比例只有 `1V1/3V2/2V3` 三个预设，无 1:1:1；面向双折叠悬停态 | 2026-10-17 |
| 存储位置 | 应用沙箱 `filesDir/vaults/` | — |
| 同步方案 | **isomorphic-git 双向**，冲突推 `xt2` 分支 | — |
| GitHub 单向 zipball 导入 | ❌ 放弃，改动会被覆盖 | — |
| 库命名 | 显示名 = 目录名；非法字符过滤，重名自动加 `-2` | — |
| 同步网络层 | **转发方案定案**，`onInterceptRequest` 拦截 **❌ 否决**（POST body 是 string） | 2026-10-17 |
| 大数据通道 | **WebMessagePort + ArrayBuffer + 分块（4MB）**；`runJavaScript` 只走控制指令 | 2026-10-17 |
| 后台同步 | **先不做**，已转 `requirements_backlog.md`；MVP 用「前台进度条 + 未推送角标」替代 | 2026-10-17 |
| 抽 ohpm 库 | ⏸ **TODO 挂起**（Q3）。触发条件：`push` 跑通 / 真机全流程 / 出现第二个消费方 / 要对外发布 | 2026-10-17 |

栏宽规则（布局时记住）：**一栏 = 一整块物理屏，栏边界压在折痕上**。不是"先定栏宽再躲折痕"。

---

## 5. 已知坑（工程级，踩过的）

1. **命令行构建必须设 `JAVA_HOME`** → 用 `tools\build.ps1`（已指向 DevEco 自带的 `jbr`），否则 `spawn java ENOENT`。
2. **`.codegenie/` 是 IDE 误建的嵌套空 git 仓库**（只有 `.git` 没有 commit），会让 `git add -A` 报 `does not have a commit checked out` 失败。已在 `.gitignore` 忽略，不要去删目录。
3. **改完 `web/gitbridge/src` 必须重新打包并入库**：`node build.mjs` → 产物 `entry/src/main/resources/rawfile/gitbridge/index.html` 要一起提交，否则真机跑的是旧代码。
4. 冒烟测试脚本是 **`npm run smoke`（= `node test/node_smoke.mjs`）**；文件名带 `node_` 前缀（它跑在 node 环境，不是鸿蒙环境），别手打成 `test/smoke.mjs`。
5. **base64 编解码层级**：桥接 `channel.onResult` 内部**已经解过一次** base64，调用方不要再解一遍。
6. **Gitee 私有库用 Basic 认证**（`username:私人令牌`），GitHub 用 `Bearer <PAT>` 且用户名留空 —— 两者不一样，`SyncPage` 的 401/404 人话翻译依赖这个区分。
7. **ArkTS 不允许无类型的对象字面量**，HTTP 请求等要显式声明类型（如 `const request: HttpRequestMsg = {...}`）。
8. 中文文件名：**下划线，不用空格与连字符**（与 vault 命名规范一致）。
9. ⚠️ **编辑器方案 A（CodeMirror 6）基于 `contenteditable`，而官方建议优先 `textarea`**（输入法兼容性更好）。M0.5 spike 必须**两者对比实测**（拼音/语音/手写的 composition 事件与光标），并提前想好降级路径，否则实测不过时 M2 会被卡死。

---

## 6. 还没定的（拍板前不要动）

**只剩 Q2：zip 导出要不要进 MVP？** 推荐进，排 M1。
（`docs/open_questions.md` 顶部有"已决/挂起"速查表，别再问 Q1/Q3/Q4。）

---

## 7. 怎么构建

```powershell
# 构建 debug HAP（不用开 DevEco Studio）
.\tools\build.ps1
.\tools\build.ps1 -Task clean
.\tools\build.ps1 -OhpmInstall     # 缺依赖时先装
```

```bash
# 重新打包 Web 桥接层（改了 web/gitbridge/src 后必做）
cd web/gitbridge && node build.mjs

# node 冒烟（真实 clone GitHub / Gitee）
cd web/gitbridge && node test/node_smoke.mjs
```

详细工具链见 `docs/toolchain.md`。

---

## 8. 鸿蒙知识库工作流（重要）

**所有与鸿蒙官方 Agent 的问答，一律落在 `docs/harmonyos/`**，不许留在聊天记录里。规则见 **`docs/harmonyos/README.md`**，摘要：

```
提问前：先查 api_notes.md 与 qa/ 索引 → 问过的不重复问
        → 从 prompts/ 复制最新一份，改名 prompts/YYYY-MM-DD_主题_APIxx.md
拿到回答：先存档 qa/YYYY-MM-DD_主题_APIxx.md → 再提炼进 api_notes.md（每条带 ✅/⚠️/❓）
        → 更新 README.md 的索引表 → 回填受影响的设计文档
真机验证后：把 ⚠️/❓ 改成 ✅，并写进实测值（实测值比官方答复更可信）
```

- **结论只准链接、不准复制到别的文档**（结论会被推翻，抄一份就漏改）。
- **被推翻的加删除线保留**，写清原因与新位置（我们已经在 `FoldSplitContainer` 上踩过一次）。
- 当前版本锚点：**API 24**。

---

## 9. 当前进度与下一步

已完成：首次提交与远端合并、应用名与图标、`.gitignore`、F6 同步链路（node 冒烟真 clone 成功 + hvigor 命令行 BUILD SUCCESSFUL）、多库原型、三栏方案定型。

下一步：**M0 —— 断点系统 + 自绘三栏骨架**（`docs/mvp_design.md` 第 7 节）。开工前先把 Q2 定了。

---

## 10. 协作约定

- 中文沟通；**结论先行**，再展开细节。
- 涉及鸿蒙 API 的结论必须能指到 `docs/harmonyos/api_notes.md` 的具体条目；**不允许凭记忆或通用移动端经验编接口名**（编造的 API 会直接浪费真机调试时间）。
- 文档改动随手 commit；用户说「commit push」时连推送一起做。
