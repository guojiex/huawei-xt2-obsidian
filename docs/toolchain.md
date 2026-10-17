# 命令行构建（不开 DevEco Studio）

## 结论：不用另外装 SDK 命令行

HarmonyOS 的命令行工具链（ohpm / hvigor / node / java / SDK）**随 DevEco Studio 一起安装**，
没有独立的"SDK 命令行安装包"这一说。已知位置（本机）：

| 组件 | 路径 |
| --- | --- |
| DevEco Studio 26.0.0.851 | `C:\Program Files\Huawei\DevEco Studio` |
| ohpm | `DevEco Studio\tools\ohpm\bin\ohpm.bat` |
| hvigor | `DevEco Studio\tools\hvigor\bin\hvigorw.bat` |
| Node（构建用，v24） | `DevEco Studio\tools\node` |
| Java（打包阶段必需，JBR） | `DevEco Studio\jbr` |
| HarmonyOS SDK | `DevEco Studio\sdk\default\{hms,openharmony}` |

> 如果要脱离 DevEco 做 CI，华为另外提供独立的 **Command Line Tools** 压缩包（含 ohpm/hvigor/sdkmanager），
> 但本机场景下没必要——上面这套已经齐全。

## 一键构建

```powershell
.\tools\build.ps1                  # 构建 HAP
.\tools\build.ps1 -OhpmInstall     # 先装依赖再构建
.\tools\build.ps1 -Task clean      # 清理
```

脚本做了三件事：指向 DevEco 自带的 JBR（JAVA_HOME）、指向 SDK、把 ohpm/hvigor 加进 PATH，
然后调 `hvigorw assembleHap --mode module -p product=default`。

## 手动版（等价）

```powershell
$DevEco = 'C:\Program Files\Huawei\DevEco Studio'
$env:JAVA_HOME      = "$DevEco\jbr"
$env:HOS_SDK_HOME   = "$DevEco\sdk"
$env:DEVECO_SDK_HOME = "$DevEco\sdk"
$env:PATH = "$DevEco\jbr\bin;$DevEco\tools\ohpm\bin;$DevEco\tools\hvigor\bin;" + $env:PATH

& "$DevEco\tools\hvigor\bin\hvigorw.bat" assembleHap `
    --mode module -p product=default --node-home "$DevEco\tools\node"
```

## 踩过的坑

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `spawn java ENOENT`（PackageHap 阶段） | 打包要 java，系统 PATH 里没有 | 设 `JAVA_HOME` 到 DevEco 的 `jbr`，并把 `jbr\bin` 加进 PATH |
| 在 Git Bash 里调 `.bat` 报"不是内部或外部命令" | Git Bash 把 Windows 路径转成 POSIX 形式 | 用 PowerShell 执行，不要 `cmd //c` |
| `oh_modules` 缺失导致编译失败 | 依赖没装 | `ohpm install` 或 `.\tools\build.ps1 -OhpmInstall` |
| `WARN: Will skip sign 'hos_hap'` | 工程没配签名 | 只是警告，产物是未签名 HAP；真机安装需在 DevEco 配签名 |

## 产物

`entry\build\default\outputs\default\entry-default-unsigned.hap`（未签名）。

## 关于 rawfile 内的 gitbridge

`web/gitbridge/` 是 Web 侧桥接层源码，产出 `entry/src/main/resources/rawfile/gitbridge/index.html`（单文件内联）。
改完 JS 后必须重新打包：

```bash
cd web/gitbridge && npm run build     # 需要 node + npm（任意版本均可）
```
