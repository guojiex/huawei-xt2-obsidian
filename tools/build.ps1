# 命令行构建 HAP —— 不用打开 DevEco Studio。
#
# 前提：已安装 DevEco Studio（工具链与 SDK 都随它一起装好，无需另行下载）。
# 用法（PowerShell）：
#   .\tools\build.ps1                 # 构建 debug HAP（arm64，默认）
#   .\tools\build.ps1 -Task clean     # 清理
#   .\tools\build.ps1 -Abi x86_64     # 本机 x86_64 模拟器调试用，见下方说明
#
# -Abi 说明（重要）：
#   仓库提交的 entry/build-profile.json5 永远只有 arm64-v8a —— 真机 XT2 与
#   Apple Silicon Mac 上的模拟器都是 arm64，不能为了本机环境去改它。
#   Windows 版 DevEco 只提供 x86_64 模拟器镜像，arm64 镜像拿不到，arm64-only
#   的 HAP 会被 bm install 以 code:9568347（ABI 不匹配）拒绝。
#   传 -Abi x86_64 时本脚本临时改写 abiFilters，构建结束后无论成败都还原文件，
#   所以 git status 依旧干净。前置条件：先用 OHOS_ARCH=x86_64 编好 native：
#       OHOS_ARCH=x86_64 ./native/git2_napi/build.sh
#
# 常见坑：
#   spawn java ENOENT      -> 没设 JAVA_HOME，本脚本已指向 DevEco 自带的 jbr
#   Cannot find module ... -> 缺依赖，先跑 .\tools\build.ps1 -OhpmInstall
#   code:9568347           -> HAP 的 ABI 与设备不匹配，见上面的 -Abi 说明

param(
    [string]$Task = 'assembleHap',
    [ValidateSet('arm64-v8a', 'x86_64')]
    [string]$Abi = 'arm64-v8a',
    [switch]$OhpmInstall,
    [string]$DevEco = 'C:\Program Files\Huawei\DevEco Studio'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $DevEco)) {
    Write-Error "未找到 DevEco Studio：$DevEco`n请修改 -DevEco 参数指向实际安装目录"
}

# 打包阶段要用到 java，DevEco 自带 JBR；不设会报 `spawn java ENOENT`
$env:JAVA_HOME = Join-Path $DevEco 'jbr'
$env:HOS_SDK_HOME = Join-Path $DevEco 'sdk'
$env:DEVECO_SDK_HOME = Join-Path $DevEco 'sdk'
$env:PATH = (Join-Path $DevEco 'jbr\bin') + ';' +
            (Join-Path $DevEco 'tools\ohpm\bin') + ';' +
            (Join-Path $DevEco 'tools\hvigor\bin') + ';' + $env:PATH

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$hvigorw = Join-Path $DevEco 'tools\hvigor\bin\hvigorw.bat'
$nodeHome = Join-Path $DevEco 'tools\node'

if ($OhpmInstall) {
    & (Join-Path $DevEco 'tools\ohpm\bin\ohpm.bat') install
}

Write-Host "task      : $Task"
Write-Host "abi       : $Abi"
Write-Host "deveco    : $DevEco"
Write-Host "java home : $env:JAVA_HOME"

# 非默认 ABI 时临时改写 entry/build-profile.json5，构建结束后务必还原。
# 备份放内存而不是临时文件：避免残留备份、也不受删除保护钩子影响，且能按原始
# 字节（含 CRLF/BOM）原样写回。
$profilePath = Join-Path $repoRoot 'entry\build-profile.json5'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$originalProfileText = $null

if ($Abi -ne 'arm64-v8a') {
    $originalProfileText = [System.IO.File]::ReadAllText($profilePath)
    if (-not $originalProfileText.Contains('"arm64-v8a"')) {
        throw "entry/build-profile.json5 里找不到 arm64-v8a，放弃改写（配置格式可能有变）"
    }
    $patched = $originalProfileText.Replace('"arm64-v8a"', '"' + $Abi + '"')
    [System.IO.File]::WriteAllText($profilePath, $patched, $utf8NoBom)
    Write-Host "已临时把 abiFilters 改为 $Abi（构建结束后自动还原）" -ForegroundColor Cyan
}

# ⚠️ hvigor 的 WARN（如「未配置签名，跳过签名」）走 stderr。
# 在 $ErrorActionPreference='Stop' 下会被 PowerShell 当成 NativeCommandError 直接终止，
# 出现「明明 BUILD SUCCESSFUL 却报失败」的假失败。
# 故这里临时降级为 Continue + 把 stderr 并入 stdout，改以退出码判定成败。
$prevEap = $ErrorActionPreference
$exitCode = 0
try {
    $ErrorActionPreference = 'Continue'
    & $hvigorw $Task --mode module -p product=default --node-home $nodeHome 2>&1
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
    if ($null -ne $originalProfileText) {
        [System.IO.File]::WriteAllText($profilePath, $originalProfileText, $utf8NoBom)
        Write-Host "已还原 entry/build-profile.json5（arm64-v8a）" -ForegroundColor Cyan
    }
}

if ($exitCode -ne 0) {
    Write-Error "构建失败，exit=$exitCode"
}

# 产物提示按实际情况输出：签名由工程级 hvigorfile.ts 从 .local/local-signing.json 注入，
# 注入成功时是 signed，没有本地凭据时才是 unsigned（见 tools/signing.ps1 -Status）。
$outDir = Join-Path $repoRoot 'entry\build\default\outputs\default'
$signed = Get-ChildItem -LiteralPath $outDir -Filter '*-signed.hap' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($signed) {
    Write-Host "`n产物（已签名）：$($signed.Name)  $($signed.LastWriteTime)" -ForegroundColor Green
} else {
    Write-Host "`n产物（未签名）：entry\build\default\outputs\default\entry-default-unsigned.hap" -ForegroundColor Yellow
    Write-Host "  要签名构建：DevEco 自动签名后跑 .\tools\signing.ps1 -Import" -ForegroundColor Yellow
}
