# test_integrity_logic.ps1 —— backup.ps1 的 A2a 存储完整性校验逻辑测试
#
# 怎么跑（本机无 pwsh，用 Linux 容器里的 pwsh 7；仓库根挂成 /repo，rclone+restic 挂进 /rbinst）：
#   docker run --rm -v "$PWD":/repo:ro -v /tmp/rbin:/rbinst:ro --entrypoint /bin/bash \
#     mcr.microsoft.com/powershell:lts -lc 'PATH=/rbinst:$PATH pwsh -NoProfile -File /repo/test_integrity_logic.ps1'
# **别把二进制挂到 /opt**：那个镜像的 pwsh 就装在 /opt 下，挂上去等于把 pwsh 藏了。
# 在 Windows runner 上（CI 那一步）：pwsh -NoProfile -File test_integrity_logic.ps1
#   ——runner 上有真 restic（产品依赖那一步装的），所以真损坏那一档在 runner 上才真的走到。
# 期望最后一行 INTEGRITY-LOGIC-OK；变异验证同 bash 侧规矩（见文末台账）。
#
# 分工与 test_integrity.sh（bash 侧）一样：**桩**负责退出码分档（11 锁 / 1 坏数据 / 10 仓库没了 /
# 12 口令不对 / 127 引擎没跑成），**真实二进制**负责「健康仓库记 PASS、真损坏记 FAIL」——
# 只有真的 restic 才知道 pack 里那个字节坏了，桩只能告诉我「它说坏了」。
#
# 不覆盖的（在这里注册，别假装覆盖）：
#   - Linux 容器里造不出 Windows 的 `.cmd` 桩（那支只有 windows runner 走到）；反之容器走 `.sh`。
#     两者按宿主选，选中的那一支之外的另一支记 Skip。
#   - 真实 restic 的 rc=11（拿不到锁）：10-02 实测 `restic unlock` 清的是仓库内部的锁对象，
#     **不是**文件锁；并发 `restic check` 不会返回 11。所以这一档只能由桩证明，真机上它属于
#     「引擎会不会这么答」的未知项——不写进 PASS 口径，也不假装测过。
#
# 变异台账（摘 backup.ps1 的实现、这份必须报 FAIL；15 条实测：**13 条 CAUGHT**，剩下两条是
# 「同一条主张有两处实现」的登记（见 m13/m13b），不是覆盖。基线 57 ok / 2 skip，
# windows runner 上真 restic 让场景9 再多出 6 条）。驱动先校验锚点恰好出现一次、替换真的落上，
# 再把容器崩溃（rc=134）单独报成 UNDETERMINED——把「跑崩了」读成「没咬住」与把空 conclusion
# 读成「CI 过了」是同一种错法（本轮 m9 就是这样被负载下的 qemu 误判过一次，机器空下来重跑
# 当场 CAUGHT 在「场景5 汇总行的 checks 与逐条行数对得上」）。
#   m1 窗口判据写反（`-ge` 改 `-le`）        → 场景2「紧接着的第二轮不该重跑」
#   m2 INTEGRITY_VERIFY 开关摘掉              → 场景2 关掉后仍到期
#   m3 `== 1` 语义改成「非空就跑」            → 场景2 INTEGRITY_VERIFY=0 整段关掉
#   m4 没登记仓库时也写报告（checks=0 那份）  → 场景6 「空登记不落笔」断言
#   m5 rc=11 判成 FAIL                        → 场景4 锁档
#   m6 rc>=2 的其余非零当成 PASS              → 场景4「rc=10（仓库不存在）按最坏情况判 FAIL」
#   m7 逐仓库判定改成全局开关                 → 场景4 锁档（第二项不再有自己的行）
#   m8 报告里抄进引擎原文                     → 场景5 隐私断言
#   m9 汇总计数用写死的 0                     → 场景5 计数对不上
#   m10 校验失败仍让整轮退 0                  → 场景11「校验失败那支真的落 rc=1」
#   m11 `FULLY COMPLETE` 移到校验判定之前     → 场景11 的 IndexOf 先后断言
#   m12 引擎调用没带 `--read-data`（只查结构）→ 场景3 argv 逐字断言
#   m13 引擎没真的调起来时沿用上条 $LASTEXITCODE（两处一起摘）→ 场景3 的 rc=127 断言
#   m13b 只摘其中一处（初值 127 或事后 `if (-not $invoked)` 兜底）→ **预期 MUTATION-MISS**：
#        这条主张在实现里有两处，摘一处另一处接住（AGENTS §3「冗余守卫要一起变异」）。
param([string]$Repo = '')
if (-not $Repo) { $Repo = $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:fail = 0
function Chk([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "ok   - $name $detail" }
    else { Write-Host "FAIL - $name $detail"; $script:fail++ }
}
$script:skipped = @()
function Skip([string]$name, [string]$why) {
    Write-Host "skip - $name（$why）"
    $script:skipped = @($script:skipped) + $name
}

# ---------- 从生产源码里切出被测函数（哨兵约定同 test_log_rotation_logic.ps1） ----------
function Slice([string]$Tag) {
    $src = Get-Content -Raw (Join-Path $Repo 'backup.ps1')
    $m = [regex]::Match($src, "(?ms)^# BEGIN-$Tag[^\r\n]*\r?\n(.*?)^# END-$Tag")
    if (-not $m.Success) {
        throw "哨兵 # BEGIN-$Tag / # END-$Tag 在 backup.ps1 里没成对出现——生产改了标记，这份守卫必须先炸，不能安静地测一段旧代码"
    }
    $m.Groups[1].Value
}
. ([scriptblock]::Create((Slice 'INTEGRITY')))
Chk '切出了被测函数' ($null -ne (Get-Command Invoke-IntegrityCheck -ErrorAction SilentlyContinue) `
    -and $null -ne (Get-Command Test-IntegrityDue -ErrorAction SilentlyContinue) `
    -and $null -ne (Get-Command Invoke-ResticCheck -ErrorAction SilentlyContinue))

$srcPs1 = Get-Content -Raw (Join-Path $Repo 'backup.ps1')
$script:root = Join-Path ([System.IO.Path]::GetTempPath()) ("bgit-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:root | Out-Null

# ---------- 桩：按仓库目录里的小文件决定退出码/stderr ----------
$script:isWin = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
$script:stubLog = Join-Path $script:root 'stub-argv.log'
$script:stubExt = if ($script:isWin) { 'cmd' } else { 'sh' }
$script:stubPath = Join-Path $script:root ("restic-stub." + $script:stubExt)

# 约定：`-r <仓库> check --read-data`。桩把整条 argv 落到 $STUB_LOG（断言「真的带了
# --read-data」「真的带了那个仓库」要靠它），再读 `<仓库>/.stub_rc` 决定退出码、
# `<仓库>/.stub_msg` 决定往 stderr 写什么——**写 stderr 是 restic 的正常行为**（check 全程打进度），
# 所以这一支同时是「5.1 上旁路不许把旁路炸成终止性异常」的靶子。
if ($script:isWin) {
    @(
        '@echo off',
        'echo %*>> "%STUB_LOG%"',
        'set rc=0',
        'if exist "%~2\.stub_rc" set /p rc=<"%~2\.stub_rc"',
        'if exist "%~2\.stub_msg" type "%~2\.stub_msg" 1>&2',
        'echo create exclusive lock for repository',
        'exit /b %rc%'
    ) | Out-File -FilePath $script:stubPath -Encoding ascii
} else {
    @(
        '#!/usr/bin/env bash',
        'printf ''%s\n'' "$*" >> "$STUB_LOG"',
        'repo=""',
        'prev=""',
        'for a in "$@"; do',
        '  if [ "$prev" = "-r" ]; then repo="$a"; fi',
        '  prev="$a"',
        'done',
        'rc=0',
        'if [ -n "$repo" ] && [ -f "$repo/.stub_rc" ]; then rc="$(cat "$repo/.stub_rc")"; fi',
        'if [ -n "$repo" ] && [ -f "$repo/.stub_msg" ]; then cat "$repo/.stub_msg" >&2; fi',
        'echo "create exclusive lock for repository"',
        'exit "$rc"'
    ) | Out-File -FilePath $script:stubPath -Encoding ascii
    try { chmod 755 $script:stubPath } catch { }
}
$env:STUB_LOG = $script:stubLog

function New-Repo([string]$Name, [string]$Rc = '', [string]$Stderr = '') {
    $d = Join-Path $script:root $Name
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    if ($Rc -ne '') { Set-Content -LiteralPath (Join-Path $d '.stub_rc') -Value $Rc -NoNewline -Encoding ascii }
    if ($Stderr -ne '') { Set-Content -LiteralPath (Join-Path $d '.stub_msg') -Value $Stderr -Encoding ascii }
    return $d
}
function Get-Status([string]$Report, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Report)) { return '' }
    $line = Select-String -LiteralPath $Report -SimpleMatch "$Label " | Select-Object -First 1
    if (-not $line) { return '' }
    return ($line.Line -split '\s+')[0]
}
function Clear-EnvSwitch {
    Remove-Item Env:INTEGRITY_DAYS -ErrorAction SilentlyContinue
    Remove-Item Env:INTEGRITY_VERIFY -ErrorAction SilentlyContinue
}

try {
# ---------- 场景1：判定状态的归口只有一处 ----------
Clear-EnvSwitch
Reset-IntegrityState
Format-IntegrityNote PASS 'restic:files' '逐包读取通过'
Format-IntegrityNote FAIL 'restic:system' 'rc=1 后发现坏数据'
Format-IntegrityNote UNKNOWN 'restic:config' '拿不到锁'
Format-IntegrityNote SKIP 'restic:other' '这一类没备份'
Chk '场景1 四条都进了报告行' (@($script:IntegrityLines).Count -eq 4) "实得 $(@($script:IntegrityLines).Count)"
Chk '场景1 FAIL 计数只由状态列维护' ($script:IntegrityFailed -eq 1) "实得 $script:IntegrityFailed"
Chk '场景1 UNKNOWN 单独计数（它不许混进 FAIL）' ($script:IntegrityUnknown -eq 1) "实得 $script:IntegrityUnknown"
Chk '场景1 行首是状态列（bash 报告同形，供人 grep）' `
    ($script:IntegrityLines[1] -match '^FAIL\s+restic:system\s') "实得 $($script:IntegrityLines[1])"
Reset-IntegrityState
Format-IntegrityNote 'PASSED' 'restic:files' '拼错的状态'
Chk '场景1 认不出的状态既不记 PASS 也不记 FAIL' ($script:IntegrityFailed -eq 0) `
    "实得 $script:IntegrityFailed——把 FAIL 拼成 FATAL 之类不该让整轮看着没失败"

# ---------- 场景2：窗口节流本身是被测面 ----------
Clear-EnvSwitch
$rep = Join-Path $script:root 'timeline/INTEGRITY.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rep) | Out-Null
Chk '场景2 没有报告时到期（首轮必跑）' (Test-IntegrityDue -ReportPath $rep)
Set-Content -LiteralPath $rep -Value 'x' -Encoding utf8
Chk '场景2 刚跑过不到期（否则每晚整仓读一遍）' (-not (Test-IntegrityDue -ReportPath $rep))
(Get-Item -LiteralPath $rep).LastWriteTime = (Get-Date).AddDays(-31)
Chk '场景2 满 30 天到期' (Test-IntegrityDue -ReportPath $rep)
$env:INTEGRITY_DAYS = '45'
Chk '场景2 INTEGRITY_DAYS 拉长窗口后同一份报告不到期' (-not (Test-IntegrityDue -ReportPath $rep))
Remove-Item Env:INTEGRITY_DAYS
$env:INTEGRITY_DAYS = '0'
Chk '场景2 INTEGRITY_DAYS=0 是人工立刻跑的入口' (Test-IntegrityDue -ReportPath $rep)
Remove-Item Env:INTEGRITY_DAYS
$env:INTEGRITY_VERIFY = '0'
(Get-Item -LiteralPath $rep).LastWriteTime = (Get-Date).AddDays(-400)
Chk '场景2 INTEGRITY_VERIFY=0 整段关掉' (-not (Test-IntegrityDue -ReportPath $rep))
Remove-Item Env:INTEGRITY_VERIFY
$env:INTEGRITY_VERIFY = 'yes'
Chk '场景2 开关按「== 1 才跑」而不是「非空就跑」（与 backup.sh 同一条）' `
    (-not (Test-IntegrityDue -ReportPath $rep)) "INTEGRITY_VERIFY=yes 不该被当成 1"
Remove-Item Env:INTEGRITY_VERIFY
$missingRep = Join-Path $script:root 'nowhere/INTEGRITY.txt'
Chk '场景2 报告所在目录还没建起来时到期（首备路径）' (Test-IntegrityDue -ReportPath $missingRep)
# mtime 读不到（文件被别的进程占着 / 刚被删）按到期处理：宁可同一窗口多读一遍，
# 也不要因为一次 stat 失败把整月的校验机会跳过去
Chk '场景2 到期判据取的是产物自身 mtime（没有状态文件）' `
    ($srcPs1 -notmatch '\$env:INTEGRITY_LAST|\$\{?INTEGRITY_LAST') "源码里不许出现另一个时间戳状态"

# ---------- 场景3：引擎调用形状（逐字 argv） ----------
Clear-EnvSwitch
$r1 = New-Repo 'repo-files' '0'
Set-Content -LiteralPath $script:stubLog -Value '' -Encoding ascii -NoNewline
$c = Invoke-ResticCheck -Repo $r1 -ResticBin $script:stubPath
$argvLog = @(Get-Content -LiteralPath $script:stubLog -ErrorAction SilentlyContinue) -join "`n"
Chk '场景3 argv 逐字：-r <仓库> check --read-data' `
    ($argvLog -match '(?m)^-r .*repo-files check --read-data$') "实得: $argvLog"
Chk '场景3 引擎退出码原样透传' ($c.rc -eq 0) "实得 $($c.rc)"
Chk '场景3 耗时是整数秒（报告行要拼它）' ($c.durSec -is [int]) "实得 $($c.durSec.GetType().Name)"
$r2 = New-Repo 'repo-config' '11'
$c2 = Invoke-ResticCheck -Repo $r2 -ResticBin $script:stubPath
Chk '场景3 桩的 rc=11 也原样透传' ($c2.rc -eq 11) "实得 $($c2.rc)"
# 引擎没真的调起来（二进制不在）＝ 127，绝不能沿用上条命令留下的 $LASTEXITCODE
$c3 = Invoke-ResticCheck -Repo $r1 -ResticBin (Join-Path $script:root 'no-such-engine')
Chk '场景3 引擎调不起来时给非零码而不是沿用旧值' ($c3.rc -eq 127) `
    "实得 $($c3.rc)——沿用上一条的 0 会让「压根没跑成」记成 PASS"

# ---------- 场景4：三档判定 + 逐仓库不是全局开关 ----------
Clear-EnvSwitch
# 每个用例各自一份报告路径：窗口节流看的是**产物自身 mtime**，共用一份报告的话第二次调用会
# 被「刚跑过」挡回去（实测踩过——那让 rc=1/10 三档断言全成了空串，看着像实现没判红）。
function New-Report([string]$Name) {
    $d = Join-Path $script:root $Name
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return (Join-Path $d 'INTEGRITY.txt')
}
$rep4 = New-Report 't4'
$okRepo = New-Repo 'repo-ok' '0'
$lockRepo = New-Repo 'repo-lock' '11'
$badRepo = New-Repo 'repo-bad' '1'
$noRepo = New-Repo 'repo-missing' '10'
$passRepo = New-Repo 'repo-pass2' '0'
$res4 = Invoke-IntegrityCheck -RepoPairs @("lock:$lockRepo", "ok:$okRepo") `
    -ReportPath $rep4 -ResticBin $script:stubPath
Chk '场景4 拿不到锁记 UNKNOWN' ((Get-Status $rep4 'lock') -eq 'UNKNOWN') `
    "实得 $(Get-Status $rep4 'lock')"
Chk '场景4 只有一项被锁，另一项仍要 PASS（逐仓库不是全局开关）' `
    ((Get-Status $rep4 'ok') -eq 'PASS') "实得 $(Get-Status $rep4 'ok')"
Chk '场景4 UNKNOWN 不改本轮结论' ($res4.Failed -eq 0) "实得 Failed=$($res4.Failed)"
Chk '场景4 UNKNOWN 单独计数' ($res4.Unknown -eq 1) "实得 Unknown=$($res4.Unknown)"
$rep4b = New-Report 't4b'
$res4b = Invoke-IntegrityCheck -RepoPairs @("bad:$badRepo") -ReportPath $rep4b -ResticBin $script:stubPath
Chk '场景4 rc=1 判 FAIL' ((Get-Status $rep4b 'bad') -eq 'FAIL') "实得 $(Get-Status $rep4b 'bad')"
Chk '场景4 rc=1 计进 Failed（调用点只看这个数）' ($res4b.Failed -eq 1) "实得 Failed=$($res4b.Failed)"
$rep4c = New-Report 't4c'
$res4c = Invoke-IntegrityCheck -RepoPairs @("gone:$noRepo") -ReportPath $rep4c -ResticBin $script:stubPath
Chk '场景4 rc=10（仓库不存在）按最坏情况判 FAIL' ((Get-Status $rep4c 'gone') -eq 'FAIL') `
    "实得 $(Get-Status $rep4c 'gone')——仓库没了/口令不对都是真问题，不能当 flake"
Chk '场景4 报告里写明是 rc 几（判红要能看出为什么）' `
    (Select-String -LiteralPath $rep4c -Pattern 'rc=10' -Quiet)
# 非锁类的 rc=2 那一档在 restic 上不存在（引擎码表里没有 2），但「其余非零」这条必须真的兜住：
$odd = New-Repo 'repo-odd' '99'
$rep4d = New-Report 't4d'
$r2c = Invoke-IntegrityCheck -RepoPairs @("odd:$odd") -ReportPath $rep4d -ResticBin $script:stubPath
Chk '场景4 码表之外的非零也判 FAIL' ($r2c.Failed -eq 1) "实得 Failed=$($r2c.Failed)"

# ---------- 场景5：报告的内容口径 ----------
Clear-EnvSwitch
$rep5 = New-Report 't5'
$repo5 = New-Repo 'repo-files5' '1'
$i5 = Invoke-IntegrityCheck -RepoPairs @("files:$repo5") -ReportPath $rep5 `
    -ResticBin $script:stubPath -Sha 'abc1234'
$text5 = Get-Content -Raw -LiteralPath $rep5
Chk '场景5 报告落在时间轴根（调用点给的这个路径）' ($i5.Report -eq $rep5) "实得 $($i5.Report)"
$itemLines = @($text5 -split "`n" | Where-Object { $_ -match '^(PASS|FAIL|UNKNOWN|SKIP)\s' })
$sumLine = @($text5 -split "`n" | Where-Object { $_ -match '^# 汇总: ' }) | Select-Object -First 1
Chk '场景5 汇总行的 checks 与逐条行数对得上' `
    ($sumLine -match ('# 汇总: checks=' + ([string]$itemLines.Count) + ' ')) `
    "逐条行数 $($itemLines.Count)，实得 $sumLine"
Chk '场景5 汇总行带着 FAIL 计数' ($text5 -match '# 汇总: checks=\d+ FAIL=1 ')
Chk '场景5 判红的那一条逐行也在（光有汇总计数不够处置）' ($text5 -match '(?m)^FAIL\s+restic:files\s')
Chk '场景5 代码基写进报告头' ($text5 -match 'abc1234')
# 隐私红线 §1.1：这份报告随时间轴上云。仓库绝对路径、源码树路径、任何真实文件名都不许出现。
# 桩的引擎原文（"create exclusive lock for repository" + .stub_msg 的内容）也不许抄进去——
# restic/borg 的错误行里带仓库绝对路径。
$leakPath = $repo5.Replace('\', '/')
# 两种分隔符都要查：Windows 的 $script:root 带反斜杠，而报告里出现的可能是归一化后的正斜杠，
# 只查一种等于给「换个写法把路径抄进上云明文」留了门。
Chk '场景5 报告里没有仓库绝对路径（原样与归一化两种写法都不许出现）' `
    ($text5 -notmatch [regex]::Escape($script:root) -and `
     $text5 -notmatch [regex]::Escape($script:root.Replace('\', '/'))) `
    "报告是明文上云产物，路径只许进本地日志"
Chk '场景5 报告里没有桩写进 stderr 的引擎原文' `
    ($text5 -notmatch 'create exclusive lock|stderr-from-stub') "引擎原文一个字节都不许抄"
Chk '场景5 报告里带着类别名（处置时要知道是哪一类）' ($text5 -match 'restic:files')
# 目录不存在时报告要写得出来（Windows 侧没有语义层替我们建 timeline 的保证）
$rep5b = Join-Path $script:root 't5b/deep/INTEGRITY.txt'
$i5b = Invoke-IntegrityCheck -RepoPairs @("files:$repo5") -ReportPath $rep5b -ResticBin $script:stubPath
Chk '场景5 报告目录不在时自己建出来并落笔' (Test-Path -LiteralPath $rep5b) "实得 Report=$($i5b.Report)"
# 写不进去（路径指向一个目录 / 根不存在）时如实返回 Report=''，而不是假装落了盘
$badPath = $script:root
$i5c = Invoke-IntegrityCheck -RepoPairs @("files:$repo5") -ReportPath $badPath -ResticBin $script:stubPath
Chk '场景5 报告写失败时 Report 为空串（调用点的「详见」不能指向不存在的东西）' `
    ($i5c.Report -eq '') "实得 Report=$($i5c.Report)"

# ---------- 场景6：空登记不许写出一份「通过」 ----------
Clear-EnvSwitch
$rep6 = Join-Path $script:root 't6/INTEGRITY.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rep6) | Out-Null
Set-Content -LiteralPath $rep6 -Value '上一轮的真实报告' -Encoding utf8
(Get-Item -LiteralPath $rep6).LastWriteTime = (Get-Date).AddDays(-40)
$i6 = Invoke-IntegrityCheck -RepoPairs @() -ReportPath $rep6 -ResticBin $script:stubPath
Chk '场景6 空登记返回 Failed=0 但 Report 为空' ($i6.Failed -eq 0 -and $i6.Report -eq '') `
    "实得 Failed=$($i6.Failed) Report=$($i6.Report)"
Chk '场景6 空登记时不落笔（一份 checks=0 的「完整性通过」比没有更坏）' `
    ((Get-Content -Raw -LiteralPath $rep6) -match '上一轮的真实报告')
# 窗口没到：整段跳过，也不能碰报告
$rep6b = New-Report 't6b'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rep6b) | Out-Null
Set-Content -LiteralPath $rep6b -Value '这一轮没到窗口' -Encoding utf8
$i6b = Invoke-IntegrityCheck -RepoPairs @("files:$repo5") -ReportPath $rep6b -ResticBin $script:stubPath
Chk '场景6 未到窗口时 Skipped 为真且不重写报告' `
    ($i6b.Skipped -and (Get-Content -Raw -LiteralPath $rep6b) -match '这一轮没到窗口')
# 仓库目录读不到：UNKNOWN，不是 FAIL（这一项既没证成也没证败）
$rep6c = New-Report 't6c'
$i6c = Invoke-IntegrityCheck -RepoPairs @("files:$script:root/definitely-not-a-repo") `
    -ReportPath $rep6c -ResticBin $script:stubPath
Chk '场景6 仓库目录不在记 UNKNOWN 且不改退出码' `
    ($i6c.Unknown -eq 1 -and $i6c.Failed -eq 0) "实得 Unknown=$($i6c.Unknown) Failed=$($i6c.Failed)"
# 登记串形状不对（调用点拼错）不能安静地当成空登记
$rep6d = New-Report 't6d'
$i6d = Invoke-IntegrityCheck -RepoPairs @('no-colon-here') -ReportPath $rep6d -ResticBin $script:stubPath
Chk '场景6 登记串不是「类别:路径」时也留下证据' ($i6d.Unknown -eq 1) `
    "实得 Unknown=$($i6d.Unknown)——忘了登记/拼错格式整段消失是 A6 第一版藏缺陷的老路"

# ---------- 场景7：引擎往 stderr 写东西不许把旁路炸成异常 ----------
Clear-EnvSwitch
$rep7 = New-Report 't7'
$noisy = New-Repo 'repo-noisy' '0' 'stderr-from-stub: nothing wrong here'
$err = $null
try { $i7 = Invoke-IntegrityCheck -RepoPairs @("files:$noisy") -ReportPath $rep7 -ResticBin $script:stubPath }
catch { $err = $_ }
Chk '场景7 restic 写 stderr 时整段照常跑完（5.1 上 EAP=Stop 会把它变终止性异常）' `
    ($null -eq $err) "实得异常: $(if ($err) { $err.Exception.Message } else { '无' })"
Chk '场景7 噪声之后结论仍然记进报告' ((Get-Status $rep7 'files') -eq 'PASS') `
    "实得 $(Get-Status $rep7 'files')"

# ---------- 场景8：日志侧证据（引擎原文只进本地日志） ----------
Clear-EnvSwitch
$rep8 = New-Report 't8'
$log8 = Join-Path $script:root 't8/backup.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log8) | Out-Null
$quiet = New-Repo 'repo-quiet8' '1'
$i8 = Invoke-IntegrityCheck -RepoPairs @("files:$quiet") -ReportPath $rep8 `
    -ResticBin $script:stubPath -LogPath $log8
$logText = if (Test-Path -LiteralPath $log8) { Get-Content -Raw -LiteralPath $log8 } else { '' }
Chk '场景8 引擎原文进了本地日志' ($logText -match 'create exclusive lock for repository')
Chk '场景8 本地日志里有 rc 与耗时那行（判红时唯一能看的）' `
    ($logText -match '\[integrity\] restic check --read-data files -> rc=1 \(\d+s\)') "实得: $logText"
Chk '场景8 报告里不重复抄日志内容' ((Get-Content -Raw -LiteralPath $rep8) -notmatch 'create exclusive lock')

# ---------- 场景9：真实 restic——健康 PASS、真损坏 FAIL ----------
$realRestic = Get-Command restic -ErrorAction SilentlyContinue
if (-not $realRestic) {
    Skip '场景9 真实 restic 的健康/损坏两档' 'PATH 上没有 restic（容器要挂 /rbinst；windows runner 上产品依赖那一步已装）'
} else {
    $env:RESTIC_PASSWORD = 'e2e-integrity-pass'
    $src9 = Join-Path $script:root 'r9src'
    $repo9 = Join-Path $script:root 'r9repo'
    New-Item -ItemType Directory -Force -Path $src9 | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $src9 'a.txt'), (New-Object byte[] 4096))
    [System.IO.File]::WriteAllBytes((Join-Path $src9 'b.bin'), (New-Object byte[] 8192))
    $eap9 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & restic -r $repo9 init 2>&1 | Out-Null
    $initRc = $LASTEXITCODE
    & restic -q -r $repo9 backup --no-progress (Get-ChildItem -LiteralPath $src9 -File | ForEach-Object { $_.FullName }) 2>&1 | Out-Null
    $bkRc = $LASTEXITCODE
    $ErrorActionPreference = $eap9
    if ($initRc -ne 0 -or $bkRc -ne 0) {
        Skip '场景9 真实 restic 的健康/损坏两档' "建夹具仓库失败（init rc=$initRc backup rc=$bkRc）"
    } else {
        Clear-EnvSwitch
        $rep9 = Join-Path $script:root 't9/INTEGRITY.txt'
        $i9 = Invoke-IntegrityCheck -RepoPairs @("files:$repo9") -ReportPath $rep9
        Chk '场景9 健康仓库经真实 restic check --read-data 记 PASS' `
            ((Get-Status $rep9 'files') -eq 'PASS') "实得 $(Get-Status $rep9 'files') / Failed=$($i9.Failed)"
        Chk '场景9 健康仓库不产生任何失败计数' ($i9.Failed -eq 0 -and $i9.Unknown -eq 0) `
            "实得 Failed=$($i9.Failed) Unknown=$($i9.Unknown)"
        # 损坏面：pack 文件中间翻一个字节（尺寸不变）。这就是「备份还能跑、取回还能过、
        # 只有整仓读一遍才看得见」的那一类——10-01 在 borg 侧实测过同一件事。
        $packs = @(Get-ChildItem -LiteralPath (Join-Path $repo9 'data') -Recurse -File |
            Where-Object { $_.Length -gt 64 })
        if ($packs.Count -eq 0) {
            Skip '场景9 真损坏判 FAIL' '夹具仓库里没有可损坏的数据包（快照没落进 data/）'
        } else {
            $vp = $packs[0].FullName
            $bytes = [System.IO.File]::ReadAllBytes($vp)
            $bytes[40] = [byte](($bytes[40] + 1) % 256)
            $lenBefore = $bytes.Length
            [System.IO.File]::WriteAllBytes($vp, $bytes)
            Clear-EnvSwitch
            $rep9b = Join-Path $script:root 't9b/INTEGRITY.txt'
            $ghost = Join-Path $script:root 'no-such-repo9'
            $i9b = Invoke-IntegrityCheck -RepoPairs @("ghost:$ghost", "files:$repo9") -ReportPath $rep9b
            Chk '场景9 同尺寸不同内容的损坏被判 FAIL' `
                ((Get-Status $rep9b 'files') -eq 'FAIL') "实得 $(Get-Status $rep9b 'files')"
            Chk '场景9 损坏计入 Failed（调用点据此退出非零）' ($i9b.Failed -ge 1) `
                "实得 Failed=$($i9b.Failed)"
            Chk '场景9 损坏只牵连那一个仓库（其余登记项各自判定，不被全局带红）' `
                ((Get-Status $rep9b 'ghost') -eq 'UNKNOWN') "实得 $(Get-Status $rep9b 'ghost')"
            Chk '场景9 报告里没有损坏文件的绝对路径（真引擎的错误行里就带这种路径）' `
                ((Get-Content -Raw -LiteralPath $rep9b) -notmatch [regex]::Escape($script:root) -and `
                 (Get-Content -Raw -LiteralPath $rep9b) -notmatch [regex]::Escape($script:root.Replace('\', '/')))
        }
    }
}

# ---------- 场景10：桩/真实二进制的分工本身也要断言 ----------
# 这台宿主上实际用的桩是哪一支——另一支（Windows 的 .cmd / Linux 的 .sh）在这里注册为没测到，
# 别让它长成「两份都验过」。
$otherExt = if ($script:isWin) { 'sh' } else { 'cmd' }
Chk '场景10 本机用的桩形状与宿主一致' `
    ($script:stubPath -like ('*.' + $script:stubExt)) "实得 $script:stubExt"
Skip ("场景10 另一支桩（.{0}）" -f $otherExt) `
    ("本机是 {0}，只有 windows runner 会走 .cmd、只有容器会走 .sh" -f $(if ($script:isWin) { 'Windows' } else { '非 Windows' }))

# ---------- 场景11：生产接线（这一段是 backup.sh 那一版的对位） ----------
# 「校验失败仍宣布 FULLY COMPLETE」和「COMPLETE 移到校验之前」是两种坏法，报错必须各自对得上，
# 所以两条断言分开写、且诊断里写清是哪一条抓到的（AGENTS §3「一条主张配一个专属变异」）。
$idxIntegrity = $srcPs1.IndexOf('Invoke-IntegrityCheck -RepoPairs')
$idxComplete = $srcPs1.IndexOf('=== Backup FULLY COMPLETE ===')
Chk '场景11 主函数里真的调了存储完整性校验' ($idxIntegrity -gt 0 -and $idxComplete -gt 0) `
    "IndexOf 实得 Integrity=$idxIntegrity Complete=$idxComplete"
# 顺序断言不许靠 Substring 的负长度抛异常来「红」——抛异常会让整份守卫崩掉，读的人看不到
# 是哪一条抓到的（AGENTS §3「一条主张配一个专属变异」）。先判方向，再取片段。
Chk '场景11 哪条检查抓到了它排在它改退出码之前' `
    ($idxIntegrity -lt $idxComplete -and `
     ($srcPs1.Substring($idxIntegrity, $idxComplete - $idxIntegrity) -match 'integrity\.Failed -gt 0')) `
    '校验调用与 COMPLETE 之间必须能看到 Failed 判定（Integrity=$idxIntegrity Complete=$idxComplete）'
Chk '场景11 完整性失败时不许宣布 FULLY COMPLETE' ($idxIntegrity -lt $idxComplete) `
    'COMPLETE 在校验之前＝这一层永远白跑（A6 m11 同一课）'
$failBranch = [regex]::Match($srcPs1, 'if \(\$integrity -and \$integrity\.Failed -gt 0\) \{(?<body>.{0,500}?)\r?\n\s*\} else', 'Singleline')
Chk '场景11 校验失败那支真的落 rc=1' `
    ($failBranch.Success -and $failBranch.Groups['body'].Value -match 'script:RunRc = 1') `
    '旁路判红必须改变本轮退出码（红线 §1.4 同一条），不然告警通道收不到'
Chk '场景11 引擎调用带 --read-data（不带它只查结构，等于没读数据）' `
    ($srcPs1 -match '"check" "--read-data"') '见 Invoke-ResticCheck'
Chk '场景11 引擎路径只有一个入口（守卫的桩才换得动）' `
    (@([regex]::Matches($srcPs1, 'Invoke-ResticCheck -Repo')).Count -eq 1) `
    "实得 $(@([regex]::Matches($srcPs1, 'Invoke-ResticCheck -Repo')).Count) 处调用"
Chk '场景11 仓库登记表两条旁路共用同一处构造' `
    (@([regex]::Matches($srcPs1, '\$repoPairs = @\(\$semDone')).Count -eq 1) `
    '两处各建一遍＝漏登记那一类永远没人读（A6 第一版、A2b 同一课）'

} finally {
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { Write-Host "INTEGRITY-LOGIC-FAIL count=$fail"; exit 1 }
$sk = ''
if (@($script:skipped).Count -gt 0) { $sk = ' skipped=' + @($script:skipped).Count }
Write-Host "INTEGRITY-LOGIC-OK$sk"
exit 0
