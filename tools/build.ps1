# 命令行构建 HAP —— 不用打开 DevEco Studio。
#
# 前提：已安装 DevEco Studio（工具链与 SDK 都随它一起装好，无需另行下载）。
# 用法（PowerShell）：
#   .\tools\build.ps1                 # 构建 debug HAP（arm64，默认）
#   .\tools\build.ps1 -Task clean     # 清理
#   .\tools\build.ps1 -Abi x86_64     # 只本次构建编 x86_64
#
# -Abi 说明（重要）：
#   仓库提交的 entry/build-profile.json5 永远只有 arm64-v8a —— 真机 XT2 与
#   Apple Silicon Mac 上的模拟器都是 arm64，不能为了本机环境去改它。
#   Windows 版 DevEco 只提供 x86_64 模拟器镜像，arm64 镜像拿不到，arm64-only
#   的 HAP 会被 bm install 以 code:9568347（ABI 不匹配）拒绝。
#   -Abi 只影响这一次构建（用 .local/local-abi.json 叠加，**不碰 build-profile.json5**）。
#   想在 IDE 里点「运行」也能部署到本机模拟器，改用让它持续生效的开关：
#       .\tools\abi.ps1 -Set x86_64    # 之后命令行 + IDE 都编 x86_64
#       .\tools\abi.ps1 -Reset         # 恢复 arm64（真机 / 提交前必做）
#   前置条件：先用 OHOS_ARCH=x86_64 编好 native：
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

# 非默认 ABI 时叠加一个本机覆盖，构建结束后务必撤回。
# 与 tools/abi.ps1 是同一套机制（写 .local/local-abi.json，由 entry/hvigorfile.ts
# 注入 abiFilters）：差别只是 -Abi 只管这一次构建，abi.ps1 -Set 不撤回，用于让 IDE
# 里的「运行」也能编 x86_64。两处都不碰 entry/build-profile.json5。
# ⚠️ 不用「临时改写 build-profile.json5」的方案（更早的版本试过）：那样 git 工作树会
# 短暂出现改动，且某些环境对删除操作有保护钩子，finally 里删备份会报假失败。
$abiOverrideFile = Join-Path $repoRoot '.local\local-abi.json'
$abiOverrideCreated = $false

if ($Abi -ne 'arm64-v8a') {
    $previous = $null
    if (Test-Path -LiteralPath $abiOverrideFile) {
        $previous = Get-Content -LiteralPath $abiOverrideFile -Raw
    } else {
        $abiOverrideCreated = $true
    }
    $payload = [ordered]@{ abiFilters = @($Abi) }
    ($payload | ConvertTo-Json -Compress) | Set-Content -LiteralPath $abiOverrideFile -Encoding ascii
    Write-Host "已叠加本机 ABI 覆盖（$Abi），构建结束后撤回" -ForegroundColor Cyan
    if ($previous -ne $null) { Write-Host "  原有覆盖内容：$($previous.Trim())" -ForegroundColor DarkGray }
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
    if ($Abi -ne 'arm64-v8a') {
        if ($abiOverrideCreated) {
            Remove-Item -LiteralPath $abiOverrideFile -Force -ErrorAction SilentlyContinue
        } elseif ($null -ne $previous) {
            Set-Content -LiteralPath $abiOverrideFile -Value $previous -Encoding ascii
        }
        Write-Host "已撤回本次构建的 ABI 覆盖（$Abi）" -ForegroundColor Cyan
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
