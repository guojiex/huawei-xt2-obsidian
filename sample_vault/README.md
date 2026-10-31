# 共享样例笔记库

内容真源为 `notes/`，顺序与稳定 id 在 `manifest.json`。全部内容为原创公开样例，只参考用户 Obsidian 库的语法特征，不复制私人内容。

```bash
python3 tools/generators/build_sample_vault.py
python3 tools/generators/build_sample_vault.py --check
```

生成设计稿内嵌数据与 App `SampleVaultData.ets`，保持离线可用。不要手改生成区。全新安装创建空白个人库“我的笔记”和预置本样例的“曜石笔记教程”，首次进入教程库；既有安装和用户修改不受自动预置影响。只有用户明确确认设置内“重置所有数据”后，才在重新打开时恢复初始双库与教程样例。样式边界见 [v0.5 样式基线](../docs/releases/v0.5/样式基线.md)，小艺练习不是接入成功证明。
