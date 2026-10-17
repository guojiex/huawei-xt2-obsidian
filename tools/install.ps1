# 把 HAP 装到真机 / 模拟器 —— 用 DevEco 自带的 hdc，全程不用打开 DevEco Studio。
#
# 前置（只做一次，详见 docs/harmonyos/真机运行.md）：
#   1) 真机开启开发者模式 + USB 调试，并点过「允许 USB 调试」
#   2) DevEco 里完成一次自动签名 —— 未签名 HAP 真机装不上（当前 build-profile.json5 的 signingConfigs 还是空的）
#
# 用法（PowerShell）：
#   .\tools\install.ps1                  # 装最新产物（优先签名包）
#   .\tools\install.ps1 -List            # 只列已连接设备
#   .\tools\install.ps1 -Reinstall       # 覆盖安装（保留应用数据），改了存储结构别用
#   .\tools\install.ps1 -Target <id>     # 连了多台设备时指定一台
#   .\tools\install.ps1 -Run             # 装完顺手拉起应用
#
# 常见坑：
#   list targets 为空          -> 没开 USB 调试 / 数据线只能充电 / 没点「允许 USB 调试」/ Windows 缺驱动
#   signature 相关报错         -> 产物未签名，先做自动签名（见文档），别指望 -Reinstall 能救
#   装完桌面找不到图标          -> debug 包正常，用 -Run 直接拉起；或 hdc shell aa start 手打

param(
    [switch]$List,
    [switch]$Reinstall,
    [switch]$Run,
    [string]$Target = '',
    [string]$DevEco = 'C:\Program Files\Huawei\DevEco Studio'
)

$ErrorActionPreference = 'Stop'

$hdc = Join-Path $DevEco 'sdk\default\openharmony\toolchains\hdc.exe'
if (-not (Test-Path $hdc)) {
    Write-Error "未找到 hdc：$hdc`n请修改 -DevEco 参数指向实际安装目录"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# ---------- 1. 设备 ----------
# ⚠️ hdc 的非零输出也可能走 stderr，在 Stop 模式下会被 PowerShell 当错误终止；
# 这里临时降级 + 合并流，改由我们自己读输出判定（与 build.ps1 同一个坑）。
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$raw = & $hdc list targets 2>&1 | Out-String
$ErrorActionPreference = $prevEap

$devices = @($raw -split "`n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' -and $_ -notmatch '^\[Empty\]' -and $_ -notmatch 'Empty' })

if ($List) {
    if ($devices.Count -eq 0) { Write-Host "没有发现设备。" -ForegroundColor Yellow }
    else { $devices | ForEach-Object { Write-Host $_ } }
    exit 0
}

if ($devices.Count -eq 0) {
    Write-Error @"
没有发现设备（hdc list targets 为空）。按顺序排查：
  1) 手机：设置 > 关于本机 > 连点「HarmonyOS 版本」7 次 开启开发者模式
  2) 手机：设置 > 系统与更新 > 开发人员选项 > 打开「USB 调试」
  3) 换一根能传数据的数据线（很多充电线不通数据），手机上点「允许 USB 调试」
  4) Windows 设备管理器里看有没有识别异常的设备（驱动问题装华为手机助手解决）
"@
}
if ($devices.Count -gt 1 -and $Target -eq '') {
    # ⚠️ 不要在双引号字符串里再嵌 "`n"（反引号会先把字符串截断） → 先取换行符变量
    $nl = "`n"
    Write-Error "检测到多台设备，请用 -Target 指定：$nl$($devices -join $nl)"
}
if ($Target -eq '') { $Target = $devices[0] }
Write-Host "device    : $Target"

# ---------- 2. 产物 ----------
$outDir = 'entry\build\default\outputs\default'
if (-not (Test-Path $outDir)) {
    Write-Error "没有构建产物目录 $outDir`n先跑 .\tools\build.ps1"
}
$haps = @(Get-ChildItem -Path $outDir -Filter *.hap | Sort-Object LastWriteTime -Descending)
if ($haps.Count -eq 0) {
    Write-Error "$outDir 下没有 .hap`n先跑 .\tools\build.ps1"
}

# 优先签名包；只有 unsigned 包时要拦下来 —— 真机一定装不上，早报错比看设备报错好懂
$signed = $haps | Where-Object { $_.Name -notmatch 'unsigned' } | Select-Object -First 1
if ($signed) {
    $hap = $signed
} else {
    $hap = $haps[0]
    Write-Host ""
    Write-Host "⚠️ 只找到未签名产物：$($hap.Name)" -ForegroundColor Yellow
    Write-Host "   真机安装会被签名校验拒绝。先在 DevEco 里做一次自动签名：" -ForegroundColor Yellow
    Write-Host "   File > Project Structure > Project > Signing Configs > 勾选 Automatically generate signature" -ForegroundColor Yellow
    Write-Host "   （未登录先 Sign In；本机系统时间需与北京时间一致，否则签名失败）" -ForegroundColor Yellow
    Write-Host "   签名后再跑 .\tools\build.ps1，产物会变成 entry-default-signed.hap" -ForegroundColor Yellow
    Write-Host ""
    $ans = Read-Host "仍要尝试安装吗？[y/N]"
    if ($ans -ne 'y' -and $ans -ne 'Y') { exit 1 }
}

Write-Host "hap       : $($hap.FullName)"
Write-Host "modified  : $($hap.LastWriteTime)"

# ---------- 3. 安装 ----------
# ⚠️ 变量名不能用 $args（PowerShell 自动变量，会被覆盖）
$hdcArgs = @('-t', $Target, 'install')
if ($Reinstall) { $hdcArgs += '-r' }
$hdcArgs += $hap.FullName

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$out = & $hdc @hdcArgs 2>&1 | Out-String
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap

Write-Host $out
if ($code -ne 0 -or $out -notmatch 'successfully') {
    Write-Error "安装未成功（exit=$code）。完整输出见上方。"
}
Write-Host "安装完成。" -ForegroundColor Green

# ---------- 4. 拉起 ----------
if ($Run) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $start = & $hdc -t $Target shell aa start -a EntryAbility -b com.jxg.huaweiobsidian 2>&1 | Out-String
    $ErrorActionPreference = $prevEap
    Write-Host $start
}
