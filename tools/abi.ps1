#Requires -Version 5.1
<#
.SYNOPSIS
    本机 ABI 覆盖开关（只有 Windows 本机的 x86_64 模拟器才需要）。

.DESCRIPTION
    背景：entry/build-profile.json5 入库的 abiFilters 永远只有 arm64-v8a —— 真机 XT2
    与 Apple Silicon Mac 上的模拟器都是 arm64。但 Windows 版 DevEco 只提供 x86_64
    模拟器镜像（实测 system-image 落盘目录就是 phone_all_x86），arm64-only 的 HAP
    装上去会被 bm install 以 code:9568347 拒绝。

    本开关写 .local/local-abi.json（已 gitignore），由 entry/hvigorfile.ts 通过
    overrides.buildOption.externalNativeOptions.abiFilters 注入。注入点在 hvigor
    pipeline 里，所以 **IDE 里点「运行」同样生效** —— 这是关键：命令行脚本的参数
    IDE 读不到，只改 build.ps1 覆盖不到 IDE 部署路径。

    没有 .local/local-abi.json 时不做任何注入，行为与入库状态完全一致：另一台 Mac
    永远不会凭空多出这个文件，所以那边永远是 arm64。

    -Set x86_64   打开本机覆盖（该架构的 libgit2 需先编一次，见输出提示）
    -Dual         双架构覆盖 arm64-v8a + x86_64（推荐 Windows 本机长期开着）
    -Reset        删掉覆盖，回到 arm64-v8a
    -Status       只看状态（默认也是看状态）

.EXAMPLE
    .\tools\abi.ps1 -Status
    .\tools\abi.ps1 -Dual
    .\tools\abi.ps1 -Set x86_64
    .\tools\abi.ps1 -Reset

    -Dual 打出的包同时含两种 so：本机 x86_64 模拟器和 XT2 真机都能装，平时不必再切。
    代价是包体变大（两份 libgit2）；发布前跑 -Reset 回到单 arm64 再出包。

.NOTES
    ⚠️ 本文件必须是 UTF-8 with BOM：PowerShell 5.1 在没有 BOM 时会按系统 ANSI 代码页
    （GBK）读取，中文注释里的字节会被误解析成引号，产生莫名其妙的语法错误。
    变量也不要命名为 $profile —— 那是 PowerShell 自动变量（用户配置文件路径）。
    函数返回单元素数组时 PowerShell 会解包成标量，所以这里直接内联，不用函数。
#>
[CmdletBinding()]
param(
    [switch]$Status,
    [ValidateSet('arm64-v8a', 'x86_64')]
    [string]$Set,
    [switch]$Dual,
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$localDir = Join-Path $repoRoot '.local'
$abiFile  = Join-Path $localDir 'local-abi.json'
$buildProfile = Join-Path $repoRoot (Join-Path 'entry' 'build-profile.json5')

$specified = @()
if ($Set)   { $specified += '-Set' }
if ($Dual)  { $specified += '-Dual' }
if ($Reset) { $specified += '-Reset' }
if ($specified.Count -gt 1) {
    throw "-Set / -Dual / -Reset 只能用一个（本次给了：$($specified -join ' 和 ')）"
}

$committedAbis = @()
foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($buildProfile), '"(arm64-v8a|x86_64)"')) {
    $value = $m.Groups[1].Value
    if ($committedAbis -notcontains $value) { $committedAbis += $value }
}
$committedText = $committedAbis -join ','

Write-Host ''
Write-Host 'ABI 覆盖开关' -ForegroundColor Cyan

if ($Set) {
    if ($Set -eq 'arm64-v8a') {
        Write-Host 'arm64-v8a 是入库默认值 —— 按 -Reset 处理，删掉本机覆盖文件'
        if (Test-Path -LiteralPath $abiFile) { Remove-Item -LiteralPath $abiFile -Force }
    } else {
        if (-not (Test-Path -LiteralPath $localDir)) {
            $null = New-Item -ItemType Directory -Path $localDir -Force
        }
        $payload = [ordered]@{ abiFilters = @($Set) }
        ($payload | ConvertTo-Json -Compress) | Set-Content -LiteralPath $abiFile -Encoding ascii
        Write-Host "已写入 .local/local-abi.json：abiFilters = $Set" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  前置：该架构的 libgit2 需先编一次（之后不必重复）' -ForegroundColor Yellow
        Write-Host "      OHOS_ARCH=$Set OHOS_NDK=<DevEco>/sdk/default/openharmony/native bash ./native/git2_napi/build.sh" -ForegroundColor Yellow
        Write-Host '      Windows 上 OHOS_NDK 必须显式给，脚本默认值是 macOS 的' -ForegroundColor DarkYellow
    }
} elseif ($Dual) {
    if (-not (Test-Path -LiteralPath $localDir)) {
        $null = New-Item -ItemType Directory -Path $localDir -Force
    }
    $payload = [ordered]@{ abiFilters = @('arm64-v8a', 'x86_64') }
    ($payload | ConvertTo-Json -Compress) | Set-Content -LiteralPath $abiFile -Encoding ascii
    Write-Host '已写入 .local/local-abi.json：abiFilters = arm64-v8a,x86_64' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  前置：两种架构的 libgit2 都要先编一次（之后不必重复）' -ForegroundColor Yellow
    Write-Host '      bash ./native/git2_napi/build.sh                      # 默认 arm64-v8a' -ForegroundColor Yellow
    Write-Host '      OHOS_ARCH=x86_64 OHOS_NDK=<DevEco>/sdk/default/openharmony/native bash ./native/git2_napi/build.sh' -ForegroundColor Yellow
    Write-Host '      Windows 上 OHOS_NDK 必须显式给，脚本默认值是 macOS 的' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '  适合 Windows 本机长期开着：x86_64 模拟器与 XT2 真机都能装同一个包，' -ForegroundColor DarkYellow
    Write-Host '  不必来回切。代价是包体装两份 so；发布前先 -Reset 再出包。' -ForegroundColor DarkYellow
} elseif ($Reset) {
    if (Test-Path -LiteralPath $abiFile) {
        Remove-Item -LiteralPath $abiFile -Force
        Write-Host '已删除本机覆盖 —— 恢复默认 arm64-v8a' -ForegroundColor Green
    } else {
        Write-Host '本来就没有本机覆盖，已是默认 arm64-v8a' -ForegroundColor Green
    }
}

Write-Host ''

if (Test-Path -LiteralPath $abiFile) {
    $current = Get-Content -LiteralPath $abiFile -Raw | ConvertFrom-Json
    $abi = (@($current.abiFilters)) -join ','
    Write-Host "本机覆盖：开启 -> abiFilters = $abi" -ForegroundColor Yellow
    Write-Host '  影响范围：tools/build.ps1 与 DevEco IDE 的「运行」都会编这个架构'
} else {
    Write-Host '本机覆盖：关闭 -> abiFilters = arm64-v8a（入库默认）' -ForegroundColor Green
}

Write-Host "入库内容：entry/build-profile.json5 的 abiFilters = $committedText"
if ($committedAbis.Count -ne 1 -or $committedAbis[0] -ne 'arm64-v8a') {
    Write-Host '  警告：入库内容应为 arm64-v8a，不要为了本机环境改这个文件' -ForegroundColor Red
}

Write-Host ''
