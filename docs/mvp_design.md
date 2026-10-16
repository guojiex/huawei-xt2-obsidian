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
| F6 | 导入笔记库 | 从 GitHub 仓库拉取现有笔记库到沙箱 vault，让库不是空的 |

### 1.3 明确不做（v2 及以后）

全文搜索、双链 `[[wikilink]]` 与反链面板、关系图谱、标签与每日笔记、模板、插件系统、PDF 与附件预览、多 vault 切换。

Git **双向同步**（在手机上 commit + push 回 GitHub）暂不列入 MVP —— 只做单向拉取导入（F6）。理由是双向同步的真正难点不是 git 协议，而是冲突处理与合并策略，属于深水区，先把"能在手机上读和改"跑通。

理由同上：这些功能的共同前提是**全库索引**，而索引层本身是独立的工作量。先跑通"单文件闭环"，再谈"库级别智能"。

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

### 4.4 Vault 初始化：从 GitHub 拉取

沙箱目录在文件管理器里不可见，所以必须有一条"把已有笔记库搬进来"的通道，选定为 GitHub 仓库拉取。

| 路径 | 做法 | 成本 | 能力 |
| --- | --- | --- | --- |
| i. zipball 拉取（**MVP 采用**） | `@ohos.net.http` 拉 `https://api.github.com/repos/{owner}/{repo}/zipball/{branch}`，`@ohos.zlib` 解压到 vault | 低 | 只读导入 |
| ii. isomorphic-git（v2） | 在已有的 Web 组件内跑 isomorphic-git，clone / pull / commit / push | 中高 | 双向同步 |
| iii. libgit2（后置） | Native C++ 编译 libgit2 + NAPI 封装 | 高 | 双向且性能最好 |

MVP 采用路径 i，实现要点：

1. **认证**：私有库需要 PAT（fine-grained token，Contents 只读即可）。token 禁止明文存 preferences，必须用**关键资产存储服务**（Asset Store Kit）加密保存。
2. **目录剥离**：zipball 解压后顶层是 `{owner}-{repo}-{sha}/`，导入时需去掉这一层，内容直接铺到 `vault/`。
3. **过滤**：跳过 `.git/`、`.obsidian/`、`.DS_Store`，只导入 `.md` 与被引用到的图片资源。
4. **原子性**：先解压到 `vault_import_tmp/`，校验文件数 > 0 后再整体替换 `vault/`；失败则保留原库不动——和单文件写入同一原则，绝不"边下边写"。
5. **增量**：导入前请求 `GET /repos/{o}/{r}/commits/{branch}` 取最新 sha，与本地记录比对，未变化就不重复下载。
6. **网络与体验**：下载放进 TaskPool，提供进度条；失败可重试。

**取舍**：单向拉取 = 手机上改的笔记不会回到 GitHub。若手机定位是"读 + 轻量记录"，这可以接受；一旦要回写，必须升级到路径 ii，且要一并定下冲突策略（本地优先 / 生成冲突副本 / 阻塞提示）。

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
| M3.5 | GitHub 导入 | 填仓库地址与 token，拉取解压后文件树能看到真实笔记 |
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
- 从私有 GitHub 仓库导入 500 篇笔记成功，中途断网重试不产生半包数据
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
| zip 解压接口 | 待核对 | `@ohos.zlib` 解压 API 名称与流式能力需按当前版本确认 |
| GitHub 拉取限流 | 中风险 | 未认证请求限流严格，私有库必须带 token；大库下载耗时要给进度 |
| 单向导入的落差 | 已接受 | 手机改动不回写 GitHub，v2 再评估双向 |
