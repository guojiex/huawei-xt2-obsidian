# huawei-xt2-obsidian

曜石笔记 —— 为华为 XT2 三折叠打造的本地 Markdown 笔记应用（ArkTS · Stage 模型 · API 24）。

## 共享样例库与当前优先级

[sample_vault](sample_vault/README.md) 是原型、首次安装与渲染回归的共用内容源。修改 Markdown 后运行 `python3 tools/build_sample_vault.py`，用 `--check` 检查产物一致性。2026-10-25 排期：v0.5 样例与渲染基线 → **v0.7 Agent 对话与本地 mock（优先）** → **v0.8 笔记 / 文件夹 / 知识库分享** → v1.0 本地体验收口 → v1.1 全文搜索 → v1.2 双链与反链 → v1.3 丰富 Markdown；小艺与 Git 统一排在末尾外部依赖队列，条件未解除前不领取。版本号不代表执行顺序。

## Agent 工程版本

Agent 的 loop、上下文、Tools/Skills、提示词与运行恢复使用[独立需求清单](docs/agent/requirements_backlog.md)和[版本线](docs/agent/README.md)。App v0.7 集成 Agent v0.1；真实小艺接入仍后置，两者不共用发布编号。

## 版本记录

[changelog.json](changelog.json) 为内容真源，运行 `python3 tools/build_changelog.py` 生成 [完整记录](CHANGELOG.md)、App 版本记录数据和原型数据。关于展示最近 3 条，完整记录可在 App 内离线查看。维护方式见 [数据驱动页面技术储备](docs/engineering/数据驱动页面.md)。

## 文档入口

- **[`AGENTS.md`](AGENTS.md)** —— 开发手册（开工前必读：硬约束、已定决策、已知坑）
- **[`docs/releases/实施总清单.md`](docs/releases/实施总清单.md)** —— 当前实现进度、阻塞项和执行顺序
- [`docs/releases/README.md`](docs/releases/README.md) —— 版本规则与需求索引
- [`docs/mvp_design.md`](docs/mvp_design.md) —— MVP 设计主文档（范围 / 架构 / 里程碑 / 验收）
- [`docs/requirements_backlog.md`](docs/requirements_backlog.md) —— 需求池
- [`docs/open_questions.md`](docs/open_questions.md) —— 待决清单与 TODO 挂起项
- **[`docs/harmonyos/README.md`](docs/harmonyos/README.md)** —— 鸿蒙知识库：与官方 Agent 的问答与结论（单一真源）
- [`docs/prototype/index.html`](docs/prototype/index.html) —— 单文件交互原型（浏览器直接打开）

## 构建

```powershell
.\tools\build.ps1          # 命令行构建 HAP，不用开 DevEco Studio
```
