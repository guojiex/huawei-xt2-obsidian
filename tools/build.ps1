# 命令行构建 HAP —— 不用打开 DevEco Studio。
#
# 前提：已安装 DevEco Studio（工具链与 SDK 都随它一起装好，无需另行下载）。
# 用法（PowerShell）：
#   .\tools\build.ps1                 # 构建 debug HAP
#   .\tools\build.ps1 -Task clean     # 清理
#
# 常见坑：
#   spawn java ENOENT      -> 没设 JAVA_HOME，本脚本已指向 DevEco 自带的 jbr
#   Cannot find module ... -> 缺依赖，先跑 .\tools\build.ps1 -OhpmInstall

param(
    [string]$Task = 'assembleHap',
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
Write-Host "deveco    : $DevEco"
Write-Host "java home : $env:JAVA_HOME"

# ⚠️ hvigor 的 WARN（如「未配置签名，跳过签名」）走 stderr。
# 在 $ErrorActionPreference='Stop' 下会被 PowerShell 当成 NativeCommandError 直接终止，
# 出现「明明 BUILD SUCCESSFUL 却报失败」的假失败。
# 故这里临时降级为 Continue + 把 stderr 并入 stdout，改以退出码判定成败。
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $hvigorw $Task --mode module -p product=default --node-home $nodeHome 2>&1
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap

if ($exitCode -ne 0) {
    Write-Error "构建失败，exit=$exitCode"
}

Write-Host "`n产物：entry\build\default\outputs\default\entry-default-unsigned.hap (未签名)" -ForegroundColor Green
