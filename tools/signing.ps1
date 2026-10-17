#Requires -Version 5.1
<#
.SYNOPSIS
    HarmonyOS 签名凭据管理（凭据放 .local，build-profile.json5 永久干净）。

.DESCRIPTION
    2026-10-17 起签名改由工程级 hvigorfile.ts 注入（config.ohos.overrides.signingConfig），
    凭据只存在于 .local/local-signing.json（已 gitignore），
    build-profile.json5 永久保持 "signingConfigs": [] —— 不再需要来回切换。

    日常只有两步：
      1) DevEco 做一次自动签名（它会把凭据写回 build-profile.json5）
      2) .\tools\signing.ps1 -Import      ← 把凭据抽到 .local 并还原干净版
    之后直接 .\tools\build.ps1 就是签名构建。

    -Import      从 build-profile.json5 抽取 signingConfigs[0].material
                 → 写 .local/local-signing.json → 还原 build-profile.json5 为干净版
    -Status      三态检查：build-profile 是否干净 / 本地凭据是否存在 / 钩子是否装了
    -Off        （应急）还原 build-profile.json5 为干净版，顺手刷新 .local 备份
    -InstallHook 安装 pre-commit 钩子，凭据被 git add 时直接拒绝提交
    -On         【已废弃】打印提示后退出，不做任何事

.EXAMPLE
    .\tools\signing.ps1 -Status
    .\tools\signing.ps1 -Import
    .\tools\signing.ps1 -InstallHook
#>
[CmdletBinding()]
param(
    [switch]$On,
    [switch]$Off,
    [switch]$Status,
    [switch]$Import,
    [switch]$InstallHook
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$target    = Join-Path $repoRoot 'build-profile.json5'
$localDir  = Join-Path $repoRoot '.local'
$backup    = Join-Path $localDir 'build-profile.signed.json5'
$localSigning = Join-Path $localDir 'local-signing.json'
$gitIgnore = Join-Path $repoRoot '.gitignore'

function Test-Signed([string]$path) {
    if (-not (Test-Path $path)) { return $false }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    return ($raw -match 'keyPassword' -or $raw -match 'storePassword' -or $raw -match 'certpath')
}

function Write-Line([string]$text, [string]$color = 'White') {
    Write-Host $text -ForegroundColor $color
}

# ---- -Status ----
if ($Status -or (-not ($On -or $Off -or $Import -or $InstallHook))) {
    Write-Line "仓库根 : $repoRoot"
    if (Test-Signed $target) {
        Write-Line "build-profile.json5 : ❌ 含明文凭据，必须清掉" 'Red'
        Write-Line "  -> 跑 .\tools\signing.ps1 -Import（会抽走凭据并还原）" 'Yellow'
    } else {
        Write-Line "build-profile.json5 : ✅ 干净（signingConfigs 为空，可提交）" 'Green'
    }
    if (Test-Path $localSigning) {
        $mtime = (Get-Item $localSigning).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        Write-Line "本地凭据 .local/local-signing.json : ✅ 存在（$mtime）" 'Green'
        Write-Line "  -> 直接 .\tools\build.ps1 即为签名构建（hvigorfile.ts 注入）" 'DarkGray'
    } else {
        Write-Line "本地凭据 .local/local-signing.json : ❌ 不存在 → 产物会是 unsigned" 'Red'
        Write-Line "  -> DevEco 自动签名后跑 .\tools\signing.ps1 -Import" 'Yellow'
    }
    $hookPath = Join-Path $repoRoot '.git/hooks/pre-commit'
    if (Test-Path $hookPath) {
        Write-Line "pre-commit 钩子 : ✅ 已安装" 'Green'
    } else {
        Write-Line "pre-commit 钩子 : 未安装 → .\tools\signing.ps1 -InstallHook" 'DarkGray'
    }
    return
}

# ---- 公共前置检查 ----
if (-not (Test-Path $target)) { throw "找不到 $target" }

# ---- -On（已废弃）----
if ($On) {
    Write-Line "-On 已废弃：签名现在由工程级 hvigorfile.ts 注入，不需要挂载签名版。" 'Yellow'
    Write-Line "  直接 .\tools\build.ps1 就是签名构建（凭据来自 .local/local-signing.json）。" 'DarkGray'
    Write-Line "  若 build-profile.json5 被 DevEco 写回了凭据，跑 .\tools\signing.ps1 -Import。" 'DarkGray'
    return
}

# ---- -Import（主力操作）----
if ($Import) {
    if (-not (Test-Path $target)) { throw "找不到 $target" }
    if (-not (Test-Signed $target)) {
        throw "build-profile.json5 里没有签名配置。请先在 DevEco 执行一次自动签名（File > Project Structure > Signing Configs），再跑 -Import。"
    }
    # json5 允许尾随逗号，先剥掉再解析
    $raw = Get-Content -LiteralPath $target -Raw -Encoding UTF8
    $normalized = [regex]::Replace($raw, ',(\s*[}\]])', '$1')
    $json = $normalized | ConvertFrom-Json
    $material = $json.app.signingConfigs[0].material
    $required = @('certpath', 'storeFile', 'storePassword', 'keyAlias', 'keyPassword', 'profile', 'signAlg')
    foreach ($key in $required) {
        if (-not $material.PSObject.Properties[$key]) { throw "签名配置缺少字段 $key，已中止。" }
    }
    if (-not (Test-Path $localDir)) { New-Item -ItemType Directory -Path $localDir | Out-Null }
    $material | ConvertTo-Json | Set-Content -LiteralPath $localSigning -Encoding UTF8
    Write-Line "已写入 $localSigning" 'Cyan'

    # .local 必须在忽略列表里
    $ig = Get-Content -LiteralPath $gitIgnore -Raw -Encoding UTF8
    if ($ig -notmatch '(?m)^\/\.local\/') {
        Add-Content -LiteralPath $gitIgnore -Value "`n/.local/" -Encoding UTF8
        Write-Line "已把 /.local/ 补进 .gitignore" 'Cyan'
    }

    # 再把 build-profile.json5 还原为干净版
    $headRaw = & git -C $repoRoot show HEAD:build-profile.json5 2>$null
    if (-not $headRaw) { throw "读取 HEAD:build-profile.json5 失败。" }
    if (($headRaw -join "`n") -match 'keyPassword|storePassword|certpath') {
        throw "HEAD 里的 build-profile.json5 已含凭据！历史被污染，请手工修正后再提交。"
    }
    & git -C $repoRoot checkout -- build-profile.json5
    if (Test-Signed $target) { throw "还原后仍是签名版，请手工检查 $target" }
    Write-Line "OK build-profile.json5 已还原为干净版。" 'Green'
    Write-Line "下一步：.\tools\build.ps1 —— 产物应为 entry-default-signed.hap" 'Green'
    return
}

# ---- -Off ----
if ($Off) {
    if (Test-Signed $target) {
        if (-not (Test-Path $localDir)) { New-Item -ItemType Directory -Path $localDir | Out-Null }
        Copy-Item -LiteralPath $target -Destination $backup -Force
        Write-Line "已把当前签名版备份到 $backup" 'Cyan'
    }
    # 用 HEAD 版本还原；先确认 HEAD 本身是干净的
    $headRaw = & git -C $repoRoot show HEAD:build-profile.json5 2>$null
    if (-not $headRaw) { throw "读取 HEAD:build-profile.json5 失败，请先确认已在 git 仓库内且该文件已入库。" }
    if (($headRaw -join "`n") -match 'keyPassword|storePassword|certpath') {
        throw "HEAD 里的 build-profile.json5 已经含凭据！历史被污染，不要用 git checkout 还原，请手工清掉 signingConfigs 后再提交修正。"
    }
    & git -C $repoRoot checkout -- build-profile.json5
    if (Test-Signed $target) {
        throw "还原后仍是签名版，请手工检查 $target"
    }
    Write-Line "OK 已还原为干净版，可以安全提交。" 'Green'
    if (-not (Test-Path $localSigning)) {
        Write-Line "⚠️ .local/local-signing.json 不存在，凭据没留住 —— 下次构建会是 unsigned。" 'Yellow'
        Write-Line "   正确做法：DevEco 自动签名后跑 .\tools\signing.ps1 -Import" 'Yellow'
    }
    return
}

# ---- -InstallHook ----
if ($InstallHook) {
    $src  = Join-Path $PSScriptRoot 'git-hooks/pre-commit'
    $hook = Join-Path $repoRoot '.git/hooks/pre-commit'
    if (-not (Test-Path $src)) { throw "找不到钩子源文件 $src" }
    if (-not (Test-Path (Split-Path -Parent $hook))) { throw "找不到 .git/hooks，当前目录不是 git 仓库根目录。" }
    Copy-Item -LiteralPath $src -Destination $hook -Force
    Write-Line "OK 已安装 pre-commit 钩子：$hook" 'Green'
    Write-Line "它会拦截任何把签名凭据加入暂存区的提交。" 'DarkGray'
    return
}
