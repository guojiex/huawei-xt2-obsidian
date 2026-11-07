---
name: xt2-emulator-regression
description: 在 API26 模拟器上执行曜石笔记回归（docs/testing 用例）：区分 Windows x86_64 与 Mac arm64 宿主环境，控制环境前置检查、EM-C0 探针、执行范围与证据记录。用于模拟器回归、冒烟或版本验收的模拟器部分；不外推 API24 / XT2，不替代真机验收。
---

# 模拟器回归执行

目标是在**当前宿主环境**的 API26 模拟器上，把 `docs/testing/模拟器回归用例.md` 中指定范围的用例执行完并留下可信证据。不把环境阻塞记成用例失败，也不把模拟器结果写成设备验收。

## 入口与范围

- 用例唯一来源：`docs/testing/模拟器回归用例.md`；环境、边界与记录规则见同目录 `README.md`，本 Skill 不复制用例清单。
- 执行前先确认范围：冒烟子集（用例文件 §0）、全量、用户指定的组或单条；未指定时默认冒烟子集。
- 负面清单（用例文件末节）中的项不执行，即使顺手可做。

## 环境前置（按宿主二选一）

先做两项通用检查，不通过则本轮记「环境阻塞」并停止：

1. 在线：`hdc list targets` 出现 `127.0.0.1:5555`；`hdc shell param get const.ohos.apiversion` 为 26。
2. 可见窗口：`hdc shell aa dump -a` 中应用窗口不是 `window attached #0`；宿主桌面锁定 / 无附着窗口时给出恢复步骤后停止，不逐条空跑。

### Windows（DevEco 仅提供 x86 镜像）

- ABI：先 `.\tools\abi.ps1 -Status`。需要 x86_64 时，前提是 `.build/out/libs/` 下已有 `arm64-v8a` 与 `x86_64` 两套 libgit2；缺则设 `OHOS_NDK` 指向 DevEco native SDK 后运行 `OHOS_ARCH=x86_64 bash ./native/git2_napi/build.sh`，再 `.\tools\abi.ps1 -Dual`（推荐，真机 / 模拟器共用同一包）或 `-Set x86_64`。出上架包前必须 `-Reset`。
- 构建安装：`.\tools\build.ps1` → `.\tools\install.ps1 -Run`。IDE 点运行报 code:9568347 时先查 `-Status`（覆盖可能已被撤回）。
- 证据边界：x86_64 模拟器只用于 UI 验收，证据不外推 API 24 / XT2 真机。

### Mac（Apple Silicon，arm64 镜像）

- ABI：默认 arm64，无需覆盖；首次或换机器先 `bash ./native/git2_napi/build.sh`。
- 构建：`./hvigorw assembleHap --mode module -p product=default`（JBR / SDK / Node 可用 `DEVECO_CONTENTS` 指定 DevEco 的 `Contents` 目录）；`tools/*.ps1` 是 PowerShell，Mac 不直接可用，安装与拉起参考 `tools/install.ps1` 内同款 `hdc` / `aa` 命令。
- 历史阻塞：Mac 锁屏时应用 `window attached #0`、DevEco 桌面控制返回 `AXError.cannotComplete` —— 先恢复可见窗口再执行；禁止把这类阻塞记为用例失败。
- 覆盖安装失败先核对签名类型匹配（unsigned HAP 对应 `appSignType=none`）；签名链必须同源，要求见 `AGENTS.md` 硬约束 19。

## 探针与执行

- 每轮先跑 **EM-C0**（IME 可用性探针）：不可输入时，C 组依赖文本输入的用例整组记「环境阻塞」，其余组照常执行。**x86 宿主预期直接命中「不可输入」**——API24 x86 与 API26 x86_64 均实测失败、arm64 API26 历史证据可用，该限制按 CPU 架构成立、与 API 版本无关（api_notes Z3，对照 B6 / L-8）；同轮原生 TextInput 注入正常可作对照取证，不因此怀疑构建。
- 逐条按用例步骤与预期执行；视觉 / 交互结论须截图或 HDC 控件树佐证，纯白截图不得凭视觉模型「看出」内容（`api_notes` L-8）。
- 不制造崩溃、强杀或写入中断；触控手势类用例只走按钮路径；Git 用例只做本地 commit，不碰真实远端。

## 设备操控与取证工具链

- 文本注入：`devecocli ui text` 必须先点击聚焦目标输入框（不聚焦注入无效），不支持 `-d` 参数；`uitest uiInput inputText` 同理，且两者在 x86 模拟器对 Web 面均无效（api_notes L-8 / Z3）。原生 TextInput 是模拟器上唯一可靠注入对象。
- 截图：devecocli 无 screenshot 命令，用 `hdc shell "snapshot_display -f /data/local/tmp/x.jpeg"` + `hdc file recv`。
- 控件树：`uitest dumpLayout -p <path>` + `hdc file recv` 后解析 JSON；无障碍字段是 `attributes.text` / `attributes.description`（没有 `contentDescription`）。**Web 组件内部 DOM 不入树**——Web 面的内容结论必须截图佐证，不能靠 dump。
- 进程基线：开轮先记 `hdc shell pidof com.jxg.huaweiobsidian`，关键节点复核；**pid 变化 = 存在并行安装 / 重装**，此前运行时证据作废，须重建基线（重装、重新打开夹具）再继续，不混用两代证据。
- 磁盘取证：应用沙箱文件权限 600，`hdc shell cat` 报 Permission denied 属正常——存在性用 `ls` / `find` 验证；回收站在**应用级** `files/trash/vault-<id>-<n>/`，不在库目录内；删除生效判据 = 库根目标消失 + trash 内出现 + 撤销条 / 回收站计数 UI 变化。
- 面位认知：从文件树 / 最近打开进入的笔记落在 **mdpreview 预览面**（横跨中右栏），mdeditor 编辑面不随打开挂载；探针或 C 组用例需要「编辑面」时，先从 dump 的 Web `resource` 字段确认是 `mdeditor/index.html` 还是 `mdpreview/index.html`，别把预览面当编辑面。
- 左滑 SwipeBar 注入（`uitest uiInput swipe x1 y x2 y 时长`）本机两例一次成功，比用例注记「不可靠」表现好；仍不作通过 / 失败的唯一依据（用例注记优先），失败时改走按钮路径复验。
- PowerShell 脚本化取证陷阱：`@()` 捕获 git / hdc 原生输出会**按控制台宽度折长行**（保字节用 `cmd /c "... > file"` 或直接 `file recv`）；`Select-Object -First N` 静默截断会误判「节点缺失」；双引号串内反引号是转义符（锚点 / 正则用单引号）；函数返回单元素数组会解包成标量。

## 记录与退出

- 执行完（或阻塞停止）后：结果按用例逐条写入**对应版本需求文档 §6 验收记录**，注明宿主环境（Windows x86_64 / Mac arm64）与模拟器目标；不回填 `docs/testing/` 用例文件，不维护通过计数。
- 阻塞项写清已完成用例、失败证据、原因和恢复步骤；「环境阻塞」与「用例失败」分开表述，已确认失败的用例保留失败结论。
- 模拟器通过不代表版本验收完成：API24 / XT2 由用户手动执行，真机证据单独记录。
- 提交只含本轮产物（验收记录更新等）；截图存 `.local/shots/`（gitignore）不入库，暂存与提交节奏遵守 `xt2-release-delivery` 的约束。
