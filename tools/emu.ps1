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
    [switch]$Seed,
    [switch]$Ui,
    [switch]$Tree,
    [switch]$Sel,
    [string]$Note = '',
    [string]$Tap = '',
    [switch]$Uitest,
    [string]$Fill = '',
    [string]$Shell = '',
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

# ---------------- 样例笔记 ----------------
# 为什么要有：文件树读的是沙箱里的真实目录，库里空着就验证不了展开/缩进/选中/按库记忆。
function New-SeedNotes([string]$VaultId) {
    $tmp = Join-Path $repoRoot '.local\seed'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    # 刻意混进一个非 md 文件（不该出现在树里）
    $spec = @(
        'README.md',
        '快速开始.md',
        'docs/架构设计.md',
        'docs/API说明.md',
        'docs/子模块/切入点.md',
        '工程/流式系统/Dataflow四要素.md',
        '工程/流式系统/实战笔记.md',
        '杂项/临时想法.md',
        '不该出现在树里.txt'
    )

    $base = "/data/app/el2/100/base/$Bundle/files/vaults/$VaultId"
    & $Hdc -t $Target shell mkdir -p $base | Out-Null

    foreach ($rel in $spec) {
        $src = Join-Path $tmp ($rel -replace '/', '\')
        $dir = Split-Path -Parent $src
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $title = Split-Path $rel -Leaf
        Set-Content -LiteralPath $src -Value "# $title`n`n这是样例笔记，用于验证文件树。" -Encoding UTF8

        $parts = $rel -split '/'
        for ($i = 0; $i -lt $parts.Length - 1; $i++) {
            $sub = ($parts[0..$i] -join '/')
            & $Hdc -t $Target shell mkdir -p "$base/$sub" | Out-Null
        }
        $send = (& $Hdc -t $Target file send $src "$base/$rel" 2>&1) -join ' '
        if ($send -match 'Fail|fail|Error|error') { Write-Line "    灌入失败 $rel : $send" 'Yellow' }
        else { Write-Line "    灌入 $rel" 'Gray' }
    }
    # hdc 写入的文件属主是 root，应用进程可能读不到 → 放权（仅模拟器验证用途）
    & $Hdc -t $Target shell chmod -R 777 /data/app/el2/100/base/$Bundle/files/vaults 2>&1 | Out-Null
}

# ---- 装机 + 拉起（几个模式共用）----
function Install-Launch {
    if (-not (Test-Path $hap)) { Write-Line "缺少 HAP：$hap（先跑 .\tools\build.ps1）" 'Red'; return $false }
    Write-Line "`n=== 装机 ===" 'Cyan'
    $ins = (& $Hdc -t $Target install $hap 2>&1) -join ' '
    Write-Line $ins 'Gray'
    # 9568332 = 签名不一致；9568263 = versionCode 变小（降级）。两者都只能先卸载再装
    if ($ins -match '9568332|9568263|sign info inconsistent|version downgrade') {
        Write-Line '签名不一致 / 版本降级 → 先卸载旧包再装' 'Yellow'
        (& $Hdc -t $Target uninstall $Bundle 2>&1) | Select-Object -Last 2
        Start-Sleep -Seconds 3
        (& $Hdc -t $Target install $hap 2>&1) | Select-Object -Last 2
    }
    Start-Sleep -Seconds 3
    Write-Line '=== 拉起应用 ===' 'Cyan'
    (& $Hdc -t $Target shell "aa start -a $Ability -b $Bundle" 2>&1) | Select-Object -Last 2
    Start-Sleep -Seconds 6
    return $true
}

# ---- UI 行动 ----
# 为什么需要：我看不了截图（GUI 图片内容在会话里被过滤），只能靠**文本证据**验证。
# 模拟器提供 -uiLayout（导出控件树，含 id 与坐标）、-click <widgetId>、-fill "<widgetId> <text>"，
# 于是「点哪个 / 输入什么」都能脚本化，不需要肉眼确认。
function Get-UiLayout {
    param([switch]$All)
    if ($All) { return (& $EmuExe -instance $Instance -uiLayout -i 2>&1) }
    return (& $EmuExe -instance $Instance -uiLayout 2>&1)
}

# uitest 的 uiInput：比 Emulator 的 -click 更可靠，且支持「给已聚焦控件输入文本」
function Invoke-UiInput([string]$args) {
    $r = (& $Hdc -t $Target shell "uitest uiInput $args" 2>&1) -join ' '
    Start-Sleep -Seconds 1
    return $r
}

function Invoke-Tap([string]$widgetId) {
    $r = (& $EmuExe -instance $Instance -click $widgetId 2>&1) -join ' '
    Start-Sleep -Milliseconds 600
    return $r
}

function Invoke-Fill([string]$widgetId, [string]$text) {
    $r = (& $EmuExe -instance $Instance -fill "$widgetId $text" 2>&1) -join ' '
    Start-Sleep -Milliseconds 400
    return $r
}

function Invoke-TapXY([int]$x, [int]$y) {
    # ⚠️ Emulator.exe -click 会报 "Scenario simulation success" 但**实际不生效**（实测 2026-10-18：
    # 点了新建笔记，控件树毫无变化）。真能注入点击的是 `uitest uiInput click <x> <y>`。
    if ($script:UseUitest) {
        $r = (& $Hdc -t $Target shell "uitest uiInput click $x $y" 2>&1) -join ' '
    } else {
        $r = (& $EmuExe -instance $Instance -click $x $y 2>&1) -join ' '
    }
    Start-Sleep -Seconds 1
    return $r
}
$script:UseUitest = $Uitest

function Get-Log([string]$tagFilter, [int]$lines = 80) {
    # `-x` 是一次性导出并清空环形缓冲，第二次再跑就拿不到东西了 → 先把原始输出落盘
    $raw = (& $Hdc -t $Target shell "hilog -x" 2>&1)
    $raw | Out-File -FilePath (Join-Path $shotDir 'log_raw.txt') -Encoding utf8
    if ($tagFilter) { $raw = $raw | Select-String $tagFilter }
    return $raw | Select-Object -Last $lines
}

# ---- 导出 UI 控件树（找 widgetId / 坐标用）----
if ($Ui) {
    if (-not (Start-Emu)) { exit 1 }
    if (-not (Install-Launch)) { exit 1 }
    # Web 页面加载 + onPageEnd + ready 事件有延迟；spike 排查期等 12s 看注入能否追上
    Start-Sleep -Seconds 12
    Write-Line "`n=== UI 控件树 ===" 'Cyan'
    $lay = Get-UiLayout -All
    $lay | Out-File -FilePath (Join-Path $shotDir 'ui_ui.md') -Encoding utf8
    Write-Line "已保存 ui_ui.md（$($lay.Count) 行）" 'Gray'
    # hilog 必须在同一次调用里抓：模拟器进程随启动它的终端调用结束而被回收
    Write-Line "`n=== hilog（EditorWebView / NoteService / FileTree）===" 'Cyan'
    $log = (& $Hdc -t $Target shell "hilog -x 2>/dev/null | grep -E 'EditorWebView|NoteService|FileTree|ArkWeb' | tail -25" 2>&1)
    $log | Out-File -FilePath (Join-Path $shotDir 'log_ui.txt') -Encoding utf8
    $log | ForEach-Object { Write-Line ("  $_") 'DarkGray' }
    exit 0
}

# ---- 用 UI 新建笔记（沙箱不可外部写入，只能走 App 自己的 UI）----
# 关键事实（2026-10-18 实测）：
#  - `Emulator.exe -click` 会报 success 但**不生效**；真正注入点击的是 `uitest uiInput click x y`；
#  - 坐标是**设备物理像素**（三屏态 3184×2232），不是 vp；
#  - 中文 "> 模拟器输入会编码错乱，样例笔记一律用 ASCII 名字（树结构才是要验证的东西）。
if ($Note) {
    if (-not (Start-Emu)) { exit 1 }
    if (-not (Install-Launch)) { exit 1 }
    # 这里必须用 uitest 注入：Emulator 的 -click 假成功（见下方关键事实）
    $script:UseUitest = $true
    # 侧栏底部「新建笔记」按钮中心（三屏态实测：left 541 / top 1923 / 484×115）
    $newBtnX = 783; $newBtnY = 1980

    # 对话框是居中的，但**拉起软键盘后整体上移**（实测上移约 139px），所以坐标必须每次量，
    # 不能写死 —— 这是上一轮失败的直接原因（点在了旧位置，输入框没拿到焦点，文本也就没进去）。
    $newBtnX = 783; $newBtnY = 1980   # 侧栏底部「新建笔记」（不受键盘影响）

    function Get-Box([object[]]$lay, [string]$pattern, [switch]$Last) {
        $hit = $null
        $hi = -1
        for ($k = 0; $k -lt $lay.Count; $k++) { if ($lay[$k] -match $pattern) { $hit = $lay[$k]; $hi = $k } }
        return @{ Line = $hit; Index = $hi }
    }

    function Box-Center([string]$line) {
        if ($line -match 'top:\s*(\d+),\s*left:\s*(\d+),\s*width:\s*(\d+),\s*height:\s*(\d+)') {
            return @([int]$Matches[2] + [int]($Matches[3] / 2), [int]$Matches[1] + [int]($Matches[4] / 2))
        }
        return $null
    }

    function Read-Ui([string]$label) {
        # $label 可能是 `notes/a` 这种含斜杠的路径 → 直接当文件名会抛错并被静默吞掉
        $safe = (($label -replace '[^A-Za-z0-9_]', '_') + '_' + (Get-Date -Format 'HHmmss'))
        $lay = Get-UiLayout -All
        $save = Join-Path $shotDir ("ui_{0}.md" -f $safe)
        $lay | Out-File -FilePath $save -Encoding utf8
        return $lay
    }

    foreach ($name in ($Note -split ';')) {
        Write-Line "`n=== 新建笔记：$name ===" 'Cyan'
        Invoke-TapXY $newBtnX $newBtnY | Out-Null
        Start-Sleep -Seconds 1

        $lay = Read-Ui $name

        # 输入法首次拉起会弹隐私声明 SheetPage：必须先「同意」，否则后面所有点击都被它吃掉
        $sheet = Get-Box $lay 'SheetPage'
        if ($sheet.Index -ge 0) {
            Write-Line '  输入法隐私页 → 点同意' 'Gray'
            Invoke-TapXY 1922 1817 | Out-Null
            Start-Sleep -Seconds 2
            $lay = Read-Ui $name
        }

        $inLine = (Get-Box $lay 'TextInput').Line
        if (-not $inLine) { Write-Line '  没找到输入框，跳过' 'Yellow'; continue }
        $c = Box-Center $inLine
        Write-Line ("  输入框中心 {0},{1}" -f $c[0], $c[1]) 'Gray'
        Invoke-TapXY $c[0] $c[1] | Out-Null
        Start-Sleep -Seconds 1

        # 再量一次：点了输入框之后软键盘可能已经把对话框顶上去了
        $lay2 = Get-UiLayout -All
        $c = Box-Center (Get-Box $lay2 'TextInput').Line
        Write-Line ("  焦点后输入框中心 {0},{1} → 输入" -f $c[0], $c[1]) 'Gray'
        Invoke-UiInput "inputText $($c[0]) $($c[1]) $name" | Out-Null
        Start-Sleep -Milliseconds 800

        # 「创建」= 输入框之后最后一个「窄宽 Text」（提示文字宽 ~771px，按钮 ~165px）
        $lay3 = Get-UiLayout -All
        $hi = (Get-Box $lay3 'TextInput').Index
        $btnLine = $null
        for ($k = $hi + 1; $k -lt $lay3.Count; $k++) {
            if ($lay3[$k] -match '^\s*- Text .*width:\s*(\d+)') {
                if ([int]$Matches[1] -le 600) { $btnLine = $lay3[$k] }
            }
        }
        if (-not $btnLine) { Write-Line '  没找到确认按钮，跳过' 'Yellow'; continue }
        $bc = Box-Center $btnLine
        Write-Line ("  点确认 {0},{1}" -f $bc[0], $bc[1]) 'Gray'
        Invoke-TapXY $bc[0] $bc[1] | Out-Null
        Start-Sleep -Seconds 2
    }

    Write-Line "`n=== UI 控件树 ===" 'Cyan'
    Get-UiLayout
    Write-Line "`n=== hilog ===" 'Cyan'
    Get-Log 'FileTree|NoteService' 80
    exit 0
}

# ---- UI 坐标点击序列（分号分隔的 "x y"）+ 导出控件树 / 日志 ----
# 为什么用坐标而不是 widgetId：widgetId 是当次遍历的序号，页面内容一变整体重排；
# 坐标在固定折叠态下是稳定的（三屏态 3184×2232 已实测），调试期够用。
if ($Tap) {
    if (-not (Start-Emu)) { exit 1 }
    if (-not (Install-Launch)) { exit 1 }

    Write-Line "`n=== 点击序列 ===" 'Cyan'
    foreach ($pair in ($Tap -split ';')) {
        $xy = ($pair.Trim() -split '\s+')
        if ($xy.Count -ne 2) { Write-Line "  跳过非法坐标：$pair" 'Yellow'; continue }
        if ($Fill) {
            # -fill "<widgetId> <text>"：填 Bob之意是往当前焦点控件写，故放在点击列表之前先跑一次
            Write-Line "  fill $Fill" 'Gray'
            $parts = ($Fill -split '=', 2)
            Invoke-Fill $parts[0] $parts[1] | Out-Null
            $Fill = ''
        }
        $r = Invoke-TapXY ([int]$xy[0]) ([int]$xy[1])
        Write-Line ("  click {0},{1} -> {2}" -f $xy[0], $xy[1], $r) 'Gray'
    }

    Write-Line "`n=== UI 控件树（合并窗口）===" 'Cyan'
    $lay = Get-UiLayout
    $lay | Out-File -FilePath (Join-Path $shotDir 'ui_tap.md') -Encoding utf8
    Write-Line "已保存 ui_tap.md（$($lay.Count) 行）" 'Gray'
    Write-Line "`n=== UI 控件树（含独立子窗口 / 对话框）===" 'Cyan'
    Get-UiLayout -All
    Write-Line "`n=== hilog（关键词 FileTree / NoteService / Index）===" 'Cyan'
    Get-Log 'FileTree|NoteService' 60
    exit 0
}

# ---- 文件树逐项验证（1.1 浏览 / 1.2 展开折叠 / 1.3 按库记忆 / 1.5 层级缩进）----
# 输出全落 .local/shots/ui_treeNN_*.md，靠**数值**验收：
#  行高应=56vp(161px)；每级缩进应让子行的 chevron 左边界右移 24vp(69px)。
if ($Tree) {
    if (-not (Start-Emu)) { exit 1 }
    if (-not (Install-Launch)) { exit 1 }
    $script:UseUitest = $true

    function Save-Ui([string]$step) {
        $lay = Get-UiLayout -All
        $lay | Out-File -FilePath (Join-Path $shotDir "ui_tree${step}.md") -Encoding utf8
        Write-Line "  [saved] ui_tree${step}.md （$($lay.Count) 行）" 'Gray'
        return $lay
    }

    Write-Line "`n=== STEP1 初始（应全部折叠）===" 'Cyan'
    Save-Ui '1_init' | Out-Null

    # docs 行：ListItem 实测 [top:595, left:46, width:1013, height:161] → 中心
    Write-Line "`n=== STEP2 点 docs 展开 ===" 'Cyan'
    Invoke-TapXY 552 675 | Out-Null
    Start-Sleep -Seconds 2
    Save-Ui '2_expand' | Out-Null

    Write-Line "`n=== STEP3 杀进程重启（验展开状态是否记住）===" 'Cyan'
    (& $Hdc -t $Target shell "aa force-stop $Bundle" 2>&1) | Out-Null
    Start-Sleep -Seconds 3
    (& $Hdc -t $Target shell "aa start -a $Ability -b $Bundle" 2>&1) | Out-Null
    Start-Sleep -Seconds 6
    Save-Ui '3_restart' | Out-Null

    Write-Line "`n=== STEP4 点 README.md（验选中路由到编辑区）===" 'Cyan'
    # README.md 行在展开后位置会变，用 hilog 前的布局动态定位最后一个 Text 'README.md'
    $lay = Get-UiLayout -All
    $target = $null
    foreach ($ln in $lay) { if ($ln -match '^\s*- Text README\.md') { $target = $ln } }
    if ($target -and $target -match 'top:\s*(\d+),\s*left:\s*(\d+),\s*width:\s*(\d+),\s*height:\s*(\d+)') {
        # 点整行的中心：行宽覆盖整个侧栏，点文件名文本区域也一样进同一个 Row
        $tx = [int]$Matches[2] + [int]($Matches[3] / 2)
        $ty = [int]$Matches[1] + [int]($Matches[4] / 2)
        Invoke-TapXY $tx $ty | Out-Null
        Write-Line "  tap README.md at $tx,$ty" 'Gray'
    } else { Write-Line '  没找到 README.md' 'Yellow' }
    Start-Sleep -Seconds 2
    Save-Ui '4_select' | Out-Null

    Write-Line "`n=== hilog ===" 'Cyan'
    Get-Log 'FileTree|TempSeed|NoteService' 60
    exit 0
}

# ---- 最短路径：只验证「点文件行 → 编辑区标题变成该笔记」----
if ($Sel) {
    if (-not (Start-Emu)) { exit 1 }
    if (-not (Install-Launch)) { exit 1 }
    $script:UseUitest = $true

    # 进程号前后对比：点完若 PID 变了，说明应用崩了重启 —— 那样状态全丢，
    # 看起来就和「点击没生效」一样（本次排查的怀疑方向之一）
    $pidBefore = ((& $Hdc -t $Target shell "pidof $Bundle" 2>&1) -join ' ').Trim()

    $lay = Get-UiLayout -All
    $target = $null
    foreach ($ln in $lay) { if ($ln -match '^\s*- Text README\.md') { $target = $ln } }
    if (-not $target) { Write-Line 'NOT-FOUND README.md row' 'Yellow'; exit 1 }
    $null = $target -match 'top:\s*(\d+),\s*left:\s*(\d+),\s*width:\s*(\d+),\s*height:\s*(\d+)'
    $tx = [int]$Matches[2] + [int]($Matches[3] / 2)
    $ty = [int]$Matches[1] + [int]($Matches[4] / 2)
    Write-Line "TAP $tx $ty" 'Cyan'
    Invoke-TapXY $tx $ty | Out-Null
    Start-Sleep -Seconds 2

    # 紧跟点击抓日志：放在 pidof/uiLayout 之后 hdc 会偶发 "Not match target founded"（原因未明，
    # 2026-10-18 连丢两次证据，怀疑 uitest 把 hdc 与模拟器的连接打抖）。抓完再测 PID。
    # 恢复手段：hdc kill 重启 PC 侧 hdc server（不动模拟器），等 target 重新出现再抓。
    $logOk = $false
    for ($try = 0; $try -lt 4 -and -not $logOk; $try++) {
        $raw = (& $Hdc -t $Target shell 'hilog -x' 2>&1)
        $joined = ($raw -join "`n")
        if ($raw -and $joined -notmatch 'Not match target|need connect-key') {
            $raw | Out-File -FilePath (Join-Path $shotDir 'log_sel.txt') -Encoding utf8
            $logOk = $true
        } else {
            Write-Line "  hilog 第 $($try + 1) 次失败（hdc 抖动）→ kill hdc server 恢复" 'Yellow'
            & $Hdc kill 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            for ($w = 0; $w -lt 10; $w++) {
                if ((Get-Targets) -contains $Target) { break }
                Start-Sleep -Seconds 2
            }
        }
    }
    if (-not $logOk) { Write-Line 'hilog 抓取失败（hdc target 抖动，重试 4 次）' 'Red' }

    $pidAfter = ((& $Hdc -t $Target shell "pidof $Bundle" 2>&1) -join ' ').Trim()
    Write-Line "PID before=[$pidBefore] after=[$pidAfter]" 'Cyan'

    Get-UiLayout -All | Out-File -FilePath (Join-Path $shotDir 'ui_sel.md') -Encoding utf8
    Write-Line 'SAVED ui_sel.md / log_sel.txt' 'Cyan'
    exit 0
}

# ---- 跑一条 hdc shell 命令（排查沙箱路径 / 权限用）----
if ($Shell) {
    if (-not (Start-Emu)) { exit 1 }
    Write-Line "hdc -t $Target shell $Shell" 'Cyan'
    (& $Hdc -t $Target shell $Shell 2>&1)
    exit 0
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
    if (-not (Install-Launch)) { exit 1 }

    if ($Seed) {
        Write-Line "`n=== 灌样例笔记 ===" 'Cyan'
        New-SeedNotes 'local'
        # 灌完后必须重启 Ability：文件树只在建组件/切库时扫描，没有监听文件变化
        (& $Hdc -t $Target shell "aa force-stop $Bundle" 2>&1) | Out-Null
        Start-Sleep -Seconds 3
        (& $Hdc -t $Target shell "aa start -a $Ability -b $Bundle" 2>&1) | Select-Object -Last 2
        Start-Sleep -Seconds 6
    }

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
