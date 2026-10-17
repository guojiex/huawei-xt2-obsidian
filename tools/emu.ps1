<#
.SYNOPSIS
    三折叠模拟器（Huawei_TripleFold）验证工具：启动 → 装机 → 切折叠态 → 截图。

.DESCRIPTION
    ⚠️ 为什么必须有这个脚本：
    模拟器的 GUI 进程会随「启动它的那次终端调用」结束而被回收（实测：Start-Process 启动后
    调用一结束进程就没了）。所以「启动 + 等开机 + 装机 + 切态 + 截图」必须在**一次调用里**跑完，
    不能拆成好几步。本脚本就是那个「一次调用」。

    ⚠️ 另一个前提：模拟器跑在沙箱外，hdc 连它必须脱离沙箱执行
    （沙箱内 hdc list targets 看不到 127.0.0.1:15001）。

    用法（都在仓库根，且需要脱离沙箱）：
      .\tools\emu.ps1 -Scenario            # 启动 → 装机 → 四种折叠态各截一张图
      .\tools\emu.ps1 -Scenario -FoldList 'folded,expanded'
      .\tools\emu.ps1 -ProbeFold           # 只探测 -foldedState 的合法取值
      .\tools\emu.ps1 -Shot -Tag after     # 已开机时只截一张当前态

    产物：.local/shots/<Tag>_<state>_<HHmmss>.png（.local 已 gitignore）

.EXAMPLE
    .\tools\emu.ps1 -Scenario
#>
[CmdletBinding()]
param(
    [switch]$Scenario,
    [switch]$ProbeFold,
    [switch]$Shot,
    [string]$FoldList = '',
    [string]$Tag = 'emu',
    [string]$Port = '15001'
)

$ErrorActionPreference = 'Continue'
$DevEco   = 'C:\Program Files\Huawei\DevEco Studio'
$EmuExe   = Join-Path $DevEco 'tools\emulator\Emulator.exe'
$Hdc      = Join-Path $DevEco 'sdk\default\openharmony\toolchains\hdc.exe'
$Instance = 'Huawei_TripleFold'
$Target   = "127.0.0.1:$Port"
$Bundle   = 'com.jxg.huaweiobsidian'
$Ability  = 'EntryAbility'

$repoRoot = Split-Path -Parent $PSScriptRoot
$shotDir  = Join-Path $repoRoot '.local\shots'
$hap      = Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'

function Write-Line([string]$t, [string]$c = 'White') { Write-Host $t -ForegroundColor $c }

if (-not (Test-Path $shotDir)) { New-Item -ItemType Directory -Path $shotDir -Force | Out-Null }

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
    Write-Line '启动模拟器（约 90 秒开机）…' 'Cyan'
    Start-Process -FilePath $EmuExe -ArgumentList '-start', $Instance, '-hdcPort', $Port `
        -WorkingDirectory (Split-Path $EmuExe) | Out-Null
    if (Wait-Target 180) { Write-Line "模拟器已在线：$Target" 'Green'; return $true }
    Write-Line "等待超时，hdc 目标：$(Get-Targets -join ', ')" 'Red'
    return $false
}

function Invoke-Fold([string]$state) {
    $out = & $EmuExe -instance $Instance -foldedState $state 2>&1
    return ($out -join ' ')
}

function Take-Shot([string]$name) {
    $file = Join-Path $shotDir ($name + '_' + (Get-Date -Format 'HHmmss') + '.png')
    & $EmuExe -instance $Instance -screenshot -screenshotPath $shotDir 2>&1 | Out-Null
    # 模拟器按自己的规则命名，取目录里最新的 png 改名归位
    Start-Sleep -Seconds 2
    $latest = Get-ChildItem $shotDir -Filter '*.png' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest -and ($latest.FullName -ne $file)) {
        Copy-Item $latest.FullName $file -Force
    }
    if (Test-Path $file) { Write-Line "  截图 → $file" 'Gray'; return $file }
    Write-Line "  截图失败（目录里没有 png）" 'Yellow'
    return $null
}

# ---- 只探测 foldedState 取值 ----
if ($ProbeFold) {
    if (-not (Start-Emu)) { exit 1 }
    $cands = @('folded', 'expanded', 'half', 'half_folded', 'single', 'double', 'triple',
        'FOLDED', 'EXPANDED', '1', '2', '3', '0')
    Write-Line "`n=== 探测 -foldedState 合法取值 ===" 'Cyan'
    foreach ($c in $cands) {
        $r = Invoke-Fold $c
        $ok = ($r -notmatch 'not started|not exist|Failed|failed|Error|error')
        Write-Line ("{0,-14} {1}  {2}" -f $c, $(if ($ok) { 'OK ' } else { '✗  ' }), $r)
    }
    exit 0
}

# ---- 只截一张当前态 ----
if ($Shot) {
    if (-not (Start-Emu)) { exit 1 }
    Take-Shot $Tag | Out-Null
    exit 0
}

# ---- 完整场景 ----
if ($Scenario) {
    if (-not (Start-Emu)) { exit 1 }

    if (-not (Test-Path $hap)) { Write-Line "缺少 HAP：$hap（先跑 .\\tools\\build.ps1）" 'Red'; exit 1 }
    Write-Line "`n=== 装机 ===" 'Cyan'
    $ins = (& $Hdc -t $Target install $hap 2>&1) -join ' '
    Write-Line $ins 'Gray'
    if ($ins -match '9568332|sign info inconsistent') {
        # 模拟器里已有旧签名版本（或真机装过别的签名包）：先卸载再装
        Write-Line '签名不一致 → 先卸载旧包再装' 'Yellow'
        (& $Hdc -t $Target uninstall $Bundle 2>&1) | Select-Object -Last 2
        Start-Sleep -Seconds 3
        (& $Hdc -t $Target install $hap 2>&1) | Select-Object -Last 2
    }
    Start-Sleep -Seconds 3
    Write-Line '=== 拉起应用 ===' 'Cyan'
    (& $Hdc -t $Target shell "aa start -a $Ability -b $Bundle" 2>&1) | Select-Object -Last 2
    Start-Sleep -Seconds 5

    # 三折叠模拟器实测合法取值只有这三个（见 -ProbeFold 输出）
    $states = if ($FoldList) { $FoldList -split ',' | ForEach-Object { $_.Trim() } }
    else { @('single', 'double', 'triple') }

    Write-Line "`n=== 逐态截图 ===" 'Cyan'
    foreach ($s in $states) {
        Write-Line "-- foldedState=$s" 'White'
        $r = Invoke-Fold $s
        if ($r -match 'not started|not exist|Failed|failed') { Write-Line "   切换失败：$r" 'Yellow' }
        Start-Sleep -Seconds 6
        Take-Shot ($Tag + '_' + $s) | Out-Null
    }

    Write-Line "`n=== 产物 ===" 'Cyan'
    Get-ChildItem $shotDir -Filter '*.png' | Sort-Object LastWriteTime -Descending | Select-Object -First 8 |
        ForEach-Object { Write-Line ("  {0}  {1}" -f $_.LastWriteTime.ToString('HH:mm:ss'), $_.Name) }
    exit 0
}

Write-Line '请指定 -Scenario / -ProbeFold / -Shot' 'Yellow'
