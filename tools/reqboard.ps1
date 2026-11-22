# 需求看板一键启动：.\tools\reqboard.ps1
# 浏览器打开 http://127.0.0.1:7812 ；-Port 换端口，-NoOpen 不自动开浏览器。
param(
  [int]$Port = 7812,
  [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'

# 端口已占用时直接提示，避免看起来像脚本挂了
$listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listening) {
  $ownerPid = $listening[0].OwningProcess
  Write-Host "端口 $Port 已被进程 $ownerPid 占用。"
  Write-Host "如果那就是旧的需求看板，浏览器直接打开 http://127.0.0.1:$Port 即可；"
  Write-Host '否则先停掉旧进程，或换个端口：.\tools\reqboard.ps1 -Port 7813'
  exit 1
}

$env:REQBOARD_PORT = "$Port"
if ($NoOpen) { $env:REQBOARD_NO_OPEN = '1' }

$server = Join-Path $PSScriptRoot 'reqboard\server.mjs'
Write-Host "启动需求看板：http://127.0.0.1:$Port （Ctrl+C 停止）"
Write-Host '数据真源：docs/requirements_backlog.md · docs/releases/ ；编辑会直接写回这些 markdown 文件。'
& node $server
