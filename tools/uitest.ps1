<#
.SYNOPSIS
    UI 自动化测试 harness：构建双 HAP → 装机 → aa test → 解析结果。

.DESCRIPTION
    hypium + @ohos.UiTest 仪器化套件（entry/src/ohosTest/ets/test/ui/）的一键执行入口。
    映射与约定见 docs/testing/UI自动化测试.md。

    模拟器 GUI 进程随启动它的终端调用结束被回收（emu.ps1 实测），所以
    「启动 → 装机 → 测试」必须在本脚本一次调用内跑完，不要拆开手动执行。

    用法（仓库根，脱离沙箱）：
      .\tools\uitest.ps1                  # 全量：UiLaunch,UiNoteFlow,UiPanels
      .\tools\uitest.ps1 -Suite UiLaunch  # 只跑指定套件（逗号分隔）
      .\tools\uitest.ps1 -Fresh           # 先卸载应用清数据再装（清测试残留）

    前置：
      - .local/local-abi.json 含 x86_64（.\tools\abi.ps1 -Set x86_64 或 -Dual）
      - 对应架构 libgit2 已编（native/git2_napi/build.sh）
      - x86_64 模拟器（Huawei_TripleFold，默认 HDC 127.0.0.1:5555）不在线时脚本会启动

    产物：.local/uitest/<时间戳>/（aa_test_raw.txt / hilog_after.txt / build_ohosTest.log）

    退出码：0 = 全部通过；1 = 存在失败/错误用例；2 = 环境或 harness 阻塞。

.EXAMPLE
    .\tools\uitest.ps1 -Suite UiLaunch
#>
[CmdletBinding()]
param(
    [string]$Suite = '',
    [switch]$Fresh,
    [string]$Port = '5555',
    [string]$Instance = 'Huawei_TripleFold',
    [string]$DevEco = 'C:\Program Files\Huawei\DevEco Studio'
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$Hdc       = Join-Path $DevEco 'sdk\default\openharmony\toolchains\hdc.exe'
$EmuExe    = Join-Path $DevEco 'tools\emulator\Emulator.exe'
$hvigorw   = Join-Path $DevEco 'tools\hvigor\bin\hvigorw.bat'
$nodeHome  = Join-Path $DevEco 'tools\node'
$Target    = "127.0.0.1:$Port"
$Bundle    = 'com.jxg.huaweiobsidian'
$TimeoutMs = 900000

function Write-Line([string]$t, [string]$c = 'White') { Write-Host $t -ForegroundColor $c }

function Get-Targets {
    return (& $Hdc list targets 2>&1) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}

function Wait-Target([int]$sec) {
    for ($i = 0; $i -lt $sec; $i += 5) {
        if ((Get-Targets) -contains $Target) { return $true }
        Start-Sleep -Seconds 5
    }
    return (Get-Targets) -contains $Target
}

function Start-Emu {
    if ((Get-Targets) -contains $Target) { Write-Line "模拟器已在线：$Target" 'Green'; return $true }
    if (-not (Test-Path -LiteralPath $EmuExe)) {
        Write-Line "未找到 Emulator.exe：$EmuExe" 'Red'; return $false
    }
    Write-Line '启动模拟器（约 90 秒开机）…' 'Cyan'
    Start-Process -FilePath $EmuExe -ArgumentList '-start', $Instance, '-hdcPort', $Port `
        -WorkingDirectory (Split-Path $EmuExe) | Out-Null
    if (Wait-Target 180) { Write-Line "模拟器已在线：$Target" 'Green'; return $true }
    Write-Line "等待超时，hdc 目标：$((Get-Targets) -join ', ')" 'Red'
    return $false
}

# 装机：9568332 = 签名不一致；9568263 = versionCode 变小（降级）→ 卸载重装
function Install-Hap([string]$hapPath) {
    $ins = (& $Hdc -t $Target install $hapPath 2>&1) -join ' '
    Write-Line ("  install " + (Split-Path -Leaf $hapPath) + " -> " + $ins) 'Gray'
    if ($ins -match '9568332|9568263|sign info inconsistent|version downgrade') {
        Write-Line '  签名不一致 / 版本降级 → 卸载后重装' 'Yellow'
        (& $Hdc -t $Target uninstall $Bundle 2>&1) | Out-Null
        Start-Sleep -Seconds 3
        $ins = (& $Hdc -t $Target install $hapPath 2>&1) -join ' '
        Write-Line ("  reinstall -> " + $ins) 'Gray'
    }
    if ($ins -match 'Fail|fail|Error|error') { return $false }
    return $true
}

# ---------------- 套件参数 ----------------
# 支持整套件（UiLaunch）或单用例（UiLaunch#more_menu_opens_and_closes，调试定位用）
$knownSuites = @('UiLaunch', 'UiNoteFlow', 'UiPanels', 'UiQuickSwitch', 'UiSmDrawer', 'UiTrash', 'UiSettingsExt', 'UiShare')
$suites = @()
if ($Suite.Trim() -ne '') {
    foreach ($s in ($Suite -split ',')) {
        $t = $s.Trim()
        if ($t -eq '') { continue }
        $suiteName = ($t -split '#')[0]
        $hit = $knownSuites | Where-Object { $_ -eq $suiteName } | Select-Object -First 1
        if (-not $hit) {
            Write-Line "未知套件：$t（可选：$($knownSuites -join ' / ')）" 'Red'
            exit 2
        }
        $suites += $t
    }
} else {
    $suites = $knownSuites
}
Write-Line "套件：$($suites -join ', ')$(if ($Fresh) { '（-Fresh：先卸载清数据）' })" 'Cyan'

# ---------------- ABI 前置检查 ----------------
# x86_64 模拟器只接受含 x86_64 的 HAP（code:9568347）。local-abi.json 由
# entry/hvigorfile.ts 注入；模块级 overrides 对 ohosTest target 同样生效
#（hvigor 合并语义：先合 overrides，target config 只补缺，已核实插件源码）。
$abiFile = Join-Path $repoRoot '.local\local-abi.json'
$abis = @()
if (Test-Path -LiteralPath $abiFile) {
    $abis = @((Get-Content -LiteralPath $abiFile -Raw | ConvertFrom-Json).abiFilters)
}
if ($abis.Count -eq 0) { $abis = @('arm64-v8a') }
Write-Line "本机 ABI 覆盖：$($abis -join ',')"
if ($abis -notcontains 'x86_64') {
    Write-Line '本机 ABI 覆盖不含 x86_64 —— x86_64 模拟器会拒绝安装（code:9568347）。' 'Red'
    Write-Line '  先跑 .\tools\abi.ps1 -Set x86_64（或 -Dual），编好对应 libgit2 后重试。' 'Yellow'
    exit 2
}
$abiDirs = @{
    'arm64-v8a' = @{ lib = 'arm64-v8a'; hdr = 'libgit2' }
    'x86_64'    = @{ lib = 'x86_64';    hdr = 'libgit2-x86_64' }
}
foreach ($a in $abis) {
    $info = $abiDirs[$a]
    if (-not $info) { Write-Line "不支持的 ABI：$a" 'Red'; exit 2 }
    $lib = Join-Path $repoRoot ("native\git2_napi\.build\out\libs\$($info.lib)\libgit2.so.1.9")
    $hdr = Join-Path $repoRoot ("native\git2_napi\.build\build\$($info.hdr)\include\git2.h")
    if (-not (Test-Path -LiteralPath $lib) -or -not (Test-Path -LiteralPath $hdr)) {
        Write-Line "缺少 $a 的 libgit2 产物（$lib / $hdr）。" 'Red'
        Write-Line '  先跑 native/git2_napi/build.sh（OHOS_ARCH 按架构），见 AGENTS.md Native 构建节。' 'Yellow'
        exit 2
    }
}

# ---------------- 证据目录 ----------------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir = Join-Path $repoRoot ".local\uitest\$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Write-Line "证据目录：$outDir" 'Gray'

# ---------------- 构建主 HAP ----------------
# 复用 tools/build.ps1：JAVA_HOME / 签名注入 / ABI 覆盖 / 失败诊断，同一套逻辑。
Write-Line "`n=== 构建主 HAP ===" 'Cyan'
try {
    & (Join-Path $PSScriptRoot 'build.ps1')
} catch {
    Write-Line "主 HAP 构建失败：$($_.Exception.Message)" 'Red'
    exit 2
}
$mainOutDir = Join-Path $repoRoot 'entry\build\default\outputs\default'
$mainHap = Get-ChildItem -LiteralPath $mainOutDir -Filter '*-signed.hap' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $mainHap) {
    $mainHap = Get-ChildItem -LiteralPath $mainOutDir -Filter '*-unsigned.hap' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not $mainHap) {
    Write-Line "主 HAP 产物缺失（$mainOutDir）" 'Red'; exit 2
}
Write-Line "主 HAP：$($mainHap.Name)  $($mainHap.LastWriteTime)" 'Green'

# ---------------- 构建 ohosTest HAP ----------------
# 同 v0.3 验收用的命令：hvigorw assembleHap --mode module -p module=entry@ohosTest。
# hvigor 的 WARN 走 stderr，$ErrorActionPreference='Stop' 下会假失败 → 临时降级，
# 以退出码判定（与 build.ps1 同一套坑）。
Write-Line "`n=== 构建 ohosTest HAP ===" 'Cyan'
$env:JAVA_HOME = Join-Path $DevEco 'jbr'
$env:HOS_SDK_HOME = Join-Path $DevEco 'sdk'
$env:DEVECO_SDK_HOME = Join-Path $DevEco 'sdk'
$env:PATH = (Join-Path $DevEco 'tools\ohpm\bin') + ';' +
            (Join-Path $DevEco 'tools\hvigor\bin') + ';' + $env:PATH

$script:buildLog = ''
$exitCode = 0
$prevEap = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & $hvigorw assembleHap --mode module -p module=entry@ohosTest -p product=default --node-home $nodeHome 2>&1 |
        ForEach-Object { $script:buildLog += [string]$_ + "`n"; $_ }
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}
$script:buildLog | Out-File -FilePath (Join-Path $outDir 'build_ohosTest.log') -Encoding utf8
if ($exitCode -ne 0) {
    Write-Line "ohosTest HAP 构建失败（exit=$exitCode），日志：$outDir\build_ohosTest.log" 'Red'
    exit 2
}
$testOutRoot = Join-Path $repoRoot 'entry\build\default\outputs'
$testHap = Get-ChildItem -LiteralPath $testOutRoot -Recurse -Filter 'entry-ohosTest-*.hap' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $testHap) {
    Write-Line "ohosTest HAP 产物缺失（$testOutRoot）" 'Red'; exit 2
}
Write-Line "测试 HAP：$($testHap.Name)  $($testHap.LastWriteTime)" 'Green'

# ---------------- 模拟器 ----------------
Write-Line "`n=== 模拟器 ===" 'Cyan'
if (-not (Start-Emu)) { exit 2 }

# ---------------- 装机 ----------------
Write-Line "`n=== 装机 ===" 'Cyan'
if ($Fresh) {
    Write-Line "卸载 $Bundle（清除应用数据与测试残留）…" 'Gray'
    (& $Hdc -t $Target uninstall $Bundle 2>&1) | ForEach-Object { Write-Line "  $_" 'Gray' }
    Start-Sleep -Seconds 3
}
if (-not (Install-Hap $mainHap.FullName)) { Write-Line '主 HAP 安装失败' 'Red'; exit 2 }
if (-not (Install-Hap $testHap.FullName)) { Write-Line '测试 HAP 安装失败' 'Red'; exit 2 }

# 停掉残留进程：UiLaunch 的冷启动用例需要应用未在运行。
# 这是常规停止（应用此时无未保存状态），不属于测试边界的「强杀/写入中断」实验。
Write-Line '停止残留进程（保证冷启动语义）…' 'Gray'
(& $Hdc -t $Target shell "aa force-stop $Bundle" 2>&1) | Out-Null
Start-Sleep -Seconds 2

# UiNoteFlow / UiSmDrawer 的 uitest* 残留清理（宿主侧，必须在应用停止后做，否则应用内存态文件树仍含旧行）：
#  - 测试进程够不到 entry 模块沙箱（getAppContext().filesDir 是 bundle 级目录，vault 在 haps/entry/files）；
#  - 残留不清会把新建行挤到文件树 LazyForEach 折叠线以下，控件树里查无（2026-11-07 183046 run 实测）。
if ($suites | Where-Object { $_ -like 'UiNoteFlow*' -or $_ -like 'UiSmDrawer*' }) {
    Write-Line '清理样例库 uitest* 残留…' 'Gray'
    $vaultDir = "/data/app/el2/100/base/$Bundle/haps/entry/files/vaults/曜石笔记教程"
    # 回收站 v1.5 起在 haps/entry/files/trash/<vaultKey>/（vaultKey 形如 vault-<ts>-<seq>，
    # 非库名）——旧 <vault>/.trash/ 已不存在，用 */ 通配各库键目录清理
    $trashBase = "/data/app/el2/100/base/$Bundle/haps/entry/files/trash"
    (& $Hdc -t $Target shell "rm -rf '$vaultDir/'uitest*" 2>&1) | Out-Null
    (& $Hdc -t $Target shell "rm -rf '$trashBase/'*/uitest*" 2>&1) | Out-Null
}

# ---------------- 运行 ----------------
# aa test 实测（2026-11-07 校准）：
#  - 设备侧重定向（> file 2>&1）拿不到输出：文件 0 字节，aa 的输出走 hdc 回传；
#  - host 侧用 cmd /c 把 hdc stdout 重定向到本地文件则字节保真，且绕开
#    PowerShell 管道按控制台宽度折长行的坑（xt2-emulator-regression Skill）。
# aa test 返回码（如 10106102）不代表测试结果，只认 OHOS_REPORT_* 输出。
$classArg = $suites -join ','
Write-Line "`n=== aa test（class=$classArg，timeout=$TimeoutMs ms）===" 'Cyan'
$rawFile = Join-Path $outDir 'aa_test_raw.txt'
if (Test-Path -LiteralPath $rawFile) { Remove-Item -LiteralPath $rawFile -Force }

$shellArg = "aa test -b $Bundle -m entry_test -s unittest OpenHarmonyTestRunner -s class $classArg -s timeout $TimeoutMs"
# cmd /c "..." 外层引号 + 内部引号的形式已实机验证；ProcessStartInfo.Arguments
# 传原始串，不经 PS 的参数重组。
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $env:ComSpec
$psi.Arguments = '/c ""' + $Hdc + '" -t ' + $Target + ' shell "' + $shellArg + '" > "' + $rawFile + '" 2>&1"'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$p = [System.Diagnostics.Process]::Start($psi)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not $p.HasExited) {
    if ($sw.Elapsed.TotalMinutes -gt 40) {
        Write-Line 'aa test 超过 40 分钟未返回，强制结束 —— 原始输出可能不完整' 'Red'
        & taskkill /PID $p.Id /T /F 2>&1 | Out-Null
        break
    }
    Start-Sleep -Seconds 20
    $tail = @(Get-Content -LiteralPath $rawFile -Tail 1 -ErrorAction SilentlyContinue |
        Where-Object { $_.Trim() -ne '' })
    if ($tail.Count -gt 0) {
        $compact = ($tail[0].Trim() -replace '\s+', ' ')
        Write-Line ("  [{0:mm\:ss}] {1}" -f $sw.Elapsed, $compact) 'DarkGray'
    }
}
Write-Line "aa test 进程退出（$([int]$sw.Elapsed.TotalSeconds) s）" 'Gray'
if (-not (Test-Path -LiteralPath $rawFile)) {
    Write-Line 'aa test 没有产生任何输出文件' 'Red'
    exit 2
}

# ---------------- hilog ----------------
$rawLog = & $Hdc -t $Target shell 'hilog -x' 2>&1
$rawLog | Out-File -FilePath (Join-Path $outDir 'hilog_after.txt') -Encoding utf8

# ---------------- 解析 ----------------
# 实测输出格式（2026-11-07 校准）：每个用例两段 STATUS 块——启动段
# STATUS_CODE: 1，结果段 STATUS_CODE: 0=pass / -1=error / -2=failure；
# 同一用例以最后一处 CODE 为准（启动标记被结果覆盖）。汇总行：
# OHOS_REPORT_RESULT: stream=Tests run: N, Failure: F, Error: E, Pass: P, Ignore: I
$lines = @(Get-Content -LiteralPath $rawFile -Encoding UTF8)
$cases = [ordered]@{}
$curClass = ''
$curTest = ''
foreach ($line in $lines) {
    if ($line -match '^OHOS_REPORT_STATUS:\s*class=(\S+)') { $curClass = $Matches[1] }
    elseif ($line -match '^OHOS_REPORT_STATUS:\s*test=(\S+)') { $curTest = $Matches[1] }
    elseif ($line -match '^OHOS_REPORT_STATUS_CODE:\s*(-?\d+)') {
        if ($curClass -ne '' -and $curTest -ne '') { $cases["$curClass#$curTest"] = [int]$Matches[1] }
    }
}
$summary = ''
foreach ($line in $lines) {
    if ($line -match '^OHOS_REPORT_RESULT:\s*stream=(.*)$') { $summary = $Matches[1] }
}

Write-Line "`n=== 结果 ===" 'Cyan'
if ($cases.Count -eq 0) {
    Write-Line '没有解析到任何用例结果 —— 测试没有真正运行（runner / 装机 / 屏幕锁定问题）。' 'Red'
    Write-Line '原始输出最后 30 行：'
    Get-Content -LiteralPath $rawFile -Tail 30 -Encoding UTF8 | ForEach-Object { Write-Line "  $_" 'DarkGray' }
    exit 2
}
$pass = 0; $fail = 0; $err = 0
foreach ($key in $cases.Keys) {
    $code = $cases[$key]
    if ($code -eq 0) {
        $pass++
        Write-Line ("  [PASS] {0}" -f $key) 'Green'
    } elseif ($code -eq -2) {
        $fail++
        Write-Line ("  [FAIL] {0}" -f $key) 'Red'
    } elseif ($code -eq -1) {
        $err++
        Write-Line ("  [ERROR] {0}" -f $key) 'Red'
    } else {
        $err++
        Write-Line ("  [UNKNOWN code=$code] {0}" -f $key) 'Yellow'
    }
}
Write-Line ("总计 {0}：pass {1} / fail {2} / error {3}" -f $cases.Count, $pass, $fail, $err) 'Cyan'
if ($summary -ne '') { Write-Line "汇总：$summary" 'Cyan' }
Write-Line "证据：$outDir（aa_test_raw.txt / hilog_after.txt / build_ohosTest.log）" 'Gray'

if ($fail -eq 0 -and $err -eq 0 -and $cases.Count -gt 0) {
    Write-Line '全部通过。' 'Green'
    exit 0
}
Write-Line '存在失败或错误用例，细节见 aa_test_raw.txt。' 'Red'
exit 1
