# MVP 设计：华为 XT2 三折叠版 Obsidian

> 状态：草稿 / 待确认项见文末「待定与风险」
> 工程：`com.jxg.huaweiobsidian`，DevEco Empty Ability + Stage 模型 + ArkTS（modelVersion 26.0.0）

## 1. 目标与边界

### 1.1 一句话定义

一个运行在华为 XT2 上的本地 Markdown 笔记应用：打开笔记库 → 浏览文件树 → 编辑 Markdown → 查看渲染结果，且在单屏态与三屏展开态下都能用。

### 1.2 MVP 必须做到

| 编号 | 能力 | 说明 |
| --- | --- | --- |
| F1 | 文件树浏览 | 展开/收起目录，打开 `.md`，新建 / 重命名 / 删除 |
| F2 | Markdown 编辑 | 源码编辑，中文输入流畅，撤销可用 |
| F3 | 预览渲染 | 标题、列表、表格、代码块、引用、图片、任务列表、行内样式 |
| F4 | 保存与恢复 | 自动保存，杀进程重进不丢内容 |
| F5 | 三形态适配 | 单屏态 / 双屏态 / 三屏展开态各自布局正确，切换时当前笔记不丢 |
| F6 | GitHub 双向同步 | clone 现有笔记库到沙箱 vault，并能把手机上的改动 commit + push 回去 |

### 1.3 明确不做（v2 及以后）

全文搜索、双链 `[[wikilink]]` 与反链面板、关系图谱、标签与每日笔记、模板、插件系统、PDF 与附件预览、多 vault 切换。

**例外**：Git 双向同步（F6）**已纳入 MVP**。原因很直接——手机端"随手记必须能回写"是硬需求，不能留到 v2。原本担心的冲突处理深水区已经绕开：手机上不做合并，冲突直接推 `xt2` 分支，丢给 PC 端解决（见 4.4）。

其余功能不做的共同理由：它们的前提都是**全库索引**，而索引层本身是独立的工作量。先跑通"单文件闭环"，再谈"库级别智能"。

## 2. 形态与断点

XT2 的三折叠意味着断点不是两档而是三档，这是本应用与普通手机 App 的核心差异。

| 形态 | 断点 | 窗口宽度 | 布局 | 组件实现 |
| --- | --- | --- | --- | --- |
| 单屏态（外屏） | sm | < 600vp | 单栏：编辑器或预览二选一，底部分段切换 | `Navigation` Stack |
| 双屏态 | md | 600–840vp | 双栏：文件树抽屉 + 编辑/预览 Tab | `Navigation` Auto + `SideBarContainer` Overlay |
| 三屏展开态 | lg | ≥ 840vp | 三栏：文件树常驻 + 编辑 + 预览 | `Navigation` Auto + `SideBarContainer` Embed + 内容区左右分栏 |

### 2.1 断点获取方式

不能写死设备类型，必须在运行时按窗口宽度判断：

```ts
// EntryAbility.onWindowStageCreate
const win = windowStage.getMainWindowSync();
win.on('windowSizeChange', (size) => {
  const widthVp = px2vp(size.width);          // 必须换算成 vp
  AppStorage.setOrCreate('breakpoint', widthVp < 600 ? 'sm' : widthVp < 840 ? 'md' : 'lg');
});
```

页面侧用 `@StorageProp('breakpoint') bp: string = 'lg'` 消费，布局按 `bp` 分支。

### 2.2 形态切换的状态保持

折叠/展开只触发窗口尺寸变化，UIAbility 不重建，但布局会重排。必须保证三件事不丢：

1. 当前打开的笔记（存 `AppStorage` 或 `NavPathStack` 状态）
2. 编辑器光标位置与滚动位置（Web 方案下需要显式保存 `scrollTop` 与 selection，切换后回填）
3. 未保存的编辑内容（落盘或草稿临时文件）

### 2.3 折痕避让

XT2 有两条铰链。关键交互元素（按钮、输入框、拖拽热区）不要横跨折痕区域；折痕相关接口在不同 API 版本命名有差异，开工前需按当前 API 参考核对。

## 3. 编辑器与渲染方案

### 3.1 关键判断

**无论选哪条路线，预览渲染都建议使用 Web 组件**（Markdown 的表格、代码块、嵌套列表用 ArkUI 自绘成本过高）。三条路线的真正分歧只有一个：**编辑端放不放进 WebView**。

### 3.2 方案对比

| 维度 | A：Web + CodeMirror 6 | B：ArkTS 原生 + Web 预览 | C：Native C++ + 自绘 |
| --- | --- | --- | --- |
| 编辑体验上限 | 高（高亮、多光标、代码块语言包开箱即用） | 中（无语法高亮，TextArea 纯文本） | 中（取决于编辑端用 A 还是 B） |
| 开发量 | 中（打包 + 桥接） | 低 | 高（解析 + 渲染 + 样式全自研） |
| 主要风险 | WebView 中文输入法与光标、resize 闪烁、桥接开销 | 无高亮，长文滚动需自优化 | MVP 阶段投入产出比低 |
| 大文档性能 | 依赖 WebView，需实测 | 可控 | 最好 |
| 结论 | **MVP 推荐** | 降级预案 | 后置到优化阶段 |

### 3.3 方案 A 落地要点（已选定）

**决策**：采用方案 A（Web 组件 + CodeMirror 6），并在 M1 之前完成 WebView 编辑可行性验证（spike）。spike 不通过则编辑端退回 `TextArea`（方案 B），预览端维持 Web 渲染不变。

资源布局：

```
entry/src/main/resources/rawfile/editor/
  index.html
  editor.js      # CodeMirror 6 + Markdown 语言包 + marked/DOMPurify，vite 打包为 IIFE
  editor.css
```

通信约定：

- ArkTS → Web：`runJavaScript('setContent(...)')`、`setSelection(...)`、`setScrollTop(...)`
- Web → ArkTS：`javaScriptProxy` 注入 `NativeBridge.onChange(patch)` / `onSave()` / `onScroll(...)`
- **禁止每次编辑都全文往返**，内容变化用增量 patch；首次加载才传全文

降级预案：若第一周的 WebView 编辑可行性验证（中文输入法 / 光标 / 滚动 / 折叠切换 resize 四项）不通过，编辑端退回 `TextArea`，预览端维持 Web 渲染，即方案 B。

## 4. 存储设计

### 4.1 目录

笔记库存放在应用沙箱（EL2 用户级加密区），通过 `UIAbilityContext.filesDir` 访问，无需任何权限申请。

```
filesDir/
  vault/                # 用户笔记，纯文件树，与 PC 端 Obsidian 库结构兼容
  .index/               # 后续搜索/双链索引（MVP 预留，不实现）
  drafts/               # 编辑中草稿，异常退出可恢复
databaseDir/
  app.db                # 应用元数据（最近打开、UI 偏好）
preferencesDir/
  app_prefs.xml         # 断点、主题、字体等轻量配置
```

### 4.2 写入策略（要点）

- **原子写**：先写 `xxx.md.tmp`，写完 `fs.renameSync` 覆盖目标文件，避免写一半崩溃导致笔记损坏
- **触发时机**：停止输入 3 秒 / 页面隐藏 / 返回键拦截 / 形态切换前
- **大目录遍历**放 TaskPool，不占 UI 线程；`fs.listFileSync` 对上千文件的目录要分页
- 编码统一 UTF-8，换行统一 LF

### 4.3 备份

工程已生成 `EntryBackupAbility`（backup extension）与 `backup_config.json`，MVP 阶段即可配置备份 `vault/` 目录，走系统备份恢复通道。

### 4.4 同步：GitHub 双向（isomorphic-git）

**决策**：在 Web 组件内运行 isomorphic-git（纯 JS 实现），支持 clone / pull / commit / push。手机端必须能回写，所以单向导入方案作废。库规模在数百篇量级，性能顾虑不成立。

不采用更轻的 Git Data API 的原因：既然要回写，完整 git 语义（本地历史、diff、分支）带来的收益超过那点额外成本，且冲突可以用"推分支"优雅解决。

#### 架构要点

1. **运行位置**：Web 组件加载 `resources/rawfile/gitbridge/index.html`（单文件内联，含打包好的 isomorphic-git + 桥接层，268 KB）。isomorphic-git 只做计算、不依赖 DOM，因此即使 M0.5 的编辑器 spike 失败、编辑端降级到 `TextArea`，这条链路依然可用。
2. **文件系统桥接**（核心工作量）：isomorphic-git 接受自定义 `fs` 对象，实现 `readFile / writeFile / readdir / mkdir / rmdir / stat / lstat / unlink / rename`，内部转发到 ArkTS，由 `@ohos.file.fs` 操作沙箱 `vault/`。**单一数据源必须留在沙箱**，不要在 Web 侧另存 IndexedDB 副本。
3. **网络（结论已修正）**：~~isomorphic-git 用 fetch 直连 GitHub~~ —— 早期假设 GitHub 支持 CORS，实测不成立：`github.com` 的 git 服务端点（`info/refs`、`git-upload-pack`）**不返回 CORS 头**，WebView 内 fetch 会被同源策略拦掉。因此改为注入**自定义 http client**，把请求转发给 ArkTS 的 `@ohos.net.http`，天然不受 CORS 限制。`module.json5` 已补 `ohos.permission.INTERNET`。
4. **认证**：PAT（fine-grained，Contents 读写）。**当前暂存在 preferences（不安全）**，正式版必须迁移到关键资产存储服务（Asset Store Kit），代码里已标 TODO。
5. **性能**：跨语言 fs 调用是主要开销。JS 侧做写缓冲，达到阈值（128 个文件 / 4 MB）才批量提交，避免逐文件跨桥；首次 clone 给进度条。

#### 桥接协议

- 通道：JS→ArkTS 用 `javaScriptProxy` 注入的 `window.__arkts.postMessage(json)`；ArkTS→JS 用 `runJavaScript` 调 `window.__gitBridge.onResult(id, ok, payloadB64)`。
- 所有路径与二进制内容一律 base64，规避中文路径、二进制报文在 JSON / 脚本传参时被破坏。
- payload 统一是「JSON 文本再做一次 base64」，从而不含引号与换行，避免脚本注入与转义问题。
- fs 操作路径一律是 vault 内相对路径，ArkTS 侧校验并拒绝 `..` 与绝对路径。
- 工作区 md 文件走 `tmp + rename` 原子写；`.git` 内部文件不做原子写（git 自身有完整性保障，且对象文件极多，原子写开销大）。
- `unlink` 做成幂等：isomorphic-git 结束时会删未必存在的 `.git/shallow`。

#### 已验证 / 待验证

**已验证**（`web/gitbridge/test/node_smoke.mjs`：用 node 伪造 ArkTS 后端，把打包产物真跑一遍，成功 clone 真实 GitHub 仓库并 checkout 出文件）。过程中修掉三个真坑：

1. `channel` 与调用方**重复解了一次 base64**，导致 `atob(undefined)`。
2. http 响应体**必须包成异步块迭代器**——直接给裸 `Uint8Array` 会被 `getIterator` 当成逐字节迭代（`Uint8Array` 自带 `Symbol.iterator`），表现为 `EmptyServerResponseError`。
3. isomorphic-git 的 `StreamReader` **强依赖 `Buffer`**（源码注释 #1855），WebView 里没有这个全局，已注入 `buffer` polyfill。

**待真机验证**：大 packfile 经 `runJavaScript` 回传的长度上限；Web 组件在 1×1 隐藏尺寸下 JS 是否正常执行。

#### 同步流程：读 main，写 main，冲突推分支

1. pull（fetch + 判断本地与远端是否分叉）
2. 无分叉 → 手机改动 commit 后直接 push 到 `main`
3. 分叉但可自动合并（不同文件，或同文件不同区域）→ 自动 merge → push `main`
4. **分叉且真冲突** → 把手机改动 commit 并 push 到 `xt2` 分支，本地 main 重置到远端最新；同时把手机版本另存到 `drafts/conflicts/`，UI 标注"这篇有未合并改动，已推送到 xt2 分支"
5. PC 端 `git merge xt2` 解冲突并推回 main；手机下次 pull 拿到合并结果，清除冲突标记

这样手机上**不需要任何合并 UI**，冲突永远不丢数据，解冲突交给 PC 端熟悉的 git 工具。

> 注意：git 无法把"未解决的冲突状态"直接 push（冲突是本地索引状态，不是可推送对象）。推到独立分支是达成同一目的的标准做法，而且比带 conflict marker 的文件更干净——PC 端看到的是两次正常提交。

#### 为什么不采用"生成冲突副本"

生成冲突副本 = 远端版本另存为 `xxx (远端版本).md`，本地保留手机版本，两边都在本地，回 PC 再挑。问题在于：① 库里多出待清理文件；② 它只是"留在本地不推"，解决不了"把改动推上去"。既然要双向，推分支更彻底。

`drafts/conflicts/` 保留手机版本仅用于"手机上还能看到自己写的内容"，不是冲突解决方案本身。

## 5. 架构与模块划分

MVP 阶段先不拆 HAR，全部放在 `entry` 内按目录分层，等模块边界稳定后再拆：

```
entry/src/main/ets/
  entryability/EntryAbility.ets     # 窗口监听、断点写入、沙箱初始化
  model/
    NoteFile.ets                    # 文件节点模型
    Breakpoint.ets                  # 断点常量与判定
  repository/
    VaultRepository.ets             # fs 操作封装（读、写、列目录、重命名、删除）
    DraftRepository.ets             # 草稿与恢复
    GitHubImportRepository.ets      # 下载 zipball、解压、原子替换 vault
    TokenStore.ets                  # PAT 的关键资产加密存取
  view/
    MainPage.ets                    # 三形态布局总装
    FileTree.ets                    # 文件树（LazyForEach + cachedCount）
    EditorPane.ets                  # 编辑器容器（Web 或 TextArea）
    PreviewPane.ets                 # 预览容器（Web 渲染）
  common/
    Bridge.ets                      # ArkTS <-> Web 通信约定
    Theme.ets                       # 明暗色与字号
```

状态管理：跨页面共享的只有断点与"当前笔记路径"，用 `AppStorage`；其余用组件内 `@State` / `@Provide`。不引入重型状态库。

## 6. 关键交互流程

1. **冷启动**：初始化沙箱 → 扫描 vault 根目录 → 渲染文件树 → 恢复上次打开的笔记
2. **打开笔记**：读取全文 → 传给编辑器 → 预览侧异步渲染
3. **编辑保存**：输入停止 3 秒 → 原子写落盘 → 更新草稿状态为已保存
4. **形态切换**：`windowSizeChange` → 更新断点 → 布局重排 → 回填光标与滚动位置
5. **返回拦截**：有未保存内容时弹出提示，避免直接丢内容

## 7. 里程碑

| 阶段 | 产出 | 完成判定 |
| --- | --- | --- |
| M0 | 断点系统 + 空三栏骨架 | 旋转/折叠时布局按断点正确切换 |
| M0.5 | WebView 编辑 spike | 中文输入法 / 光标 / 滚动 / 折叠 resize 四项给出结论 |
| M1 | 文件树 + 打开 md | 真实目录下能浏览并打开笔记 |
| M2 | 编辑器 + 自动保存 | 输入中文流畅，杀进程重进内容还在 |
| M3 | 预览渲染 | 表格/代码块/图片等语法正确渲染 |
| M3.5 | GitHub 双向同步 | clone 成功，手机改动能 push，冲突能正确推到 xt2 分支 |
| M4 | 三形态适配收口 | 形态切换不丢笔记、不丢光标 |
| M5 | 打磨 | 暗色模式、大文档性能、空状态 |

M0.5 的结论决定 M2 走方案 A 还是 B，属于前置关卡，不能跳过。

## 8. 验收标准（Definition of Done）

- 单屏 / 双屏 / 三屏展开三档布局均正确，无控件溢出
- 折叠展开切换后：当前笔记不变、滚动位置偏差不超过一屏
- 1000 篇笔记的目录下，文件树滚动不掉帧
- 打开 100KB 的 Markdown 文件耗时 < 1s
- 编辑后立即杀掉进程，重新进入内容不丢
- 写入过程中强制关闭应用，笔记文件不损坏（原子写生效）
- 从私有 GitHub 仓库 clone 笔记库成功，中途断网重试不产生半初始化的 `.git`
- 手机上改一篇笔记后 push 成功，PC 端能拉到该提交
- 人为制造冲突（PC 与手机改同一处）后，手机改动完整出现在 `xt2` 分支，本地不丢内容
- 暗色模式下编辑区与预览区均正常

## 9. 待定与风险

| 项 | 状态 | 说明 |
| --- | --- | --- |
| 编辑器方案 | 已定 A | spike（M0.5）结论决定是否需要降级到 B |
| `deviceTypes` | 待改 | 当前只有 phone/tablet，需补 `2in1` |
| 折痕 API | 待核对 | 按当前 API 版本确认接口名与返回值 |
| WebView 输入法 | 高风险 | 决定方案 A 是否成立，M0.5 必须验证 |
| 首帧加载 | 中风险 | WebView 初始化耗时，考虑预加载或骨架屏 |
| 大文档桥接 | 中风险 | 必须增量 patch，不能全文往返 |
| 网络权限 | 待改 | `module.json5` 需补 `ohos.permission.INTERNET` |
| Web 组件 CORS | 高风险 | isomorphic-git 用 fetch 直连 GitHub，需实测 HarmonyOS Web 组件是否放行；这是 M3.5 的前置验证项 |
| fs 桥接性能 | 中风险 | 每次文件读写都跨 JS↔ArkTS，必须批量化并放 Worker，否则 clone 会慢到不可用 |
| PAT 安全 | 中风险 | 必须走关键资产存储服务，禁止明文；权限最小化（Contents 读写） |
| 冲突后本地视图 | 中风险 | 冲突推分支后 main 被重置，手机上看不到刚写的内容，需靠 `drafts/conflicts/` 与 UI 标注兜住体验 |
