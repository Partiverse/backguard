# test_status_emit_logic.ps1 —— backup.ps1 的 STATUS.jsonl 产出器（Add-StatusLine）逻辑测试
#
# 怎么跑（本机无 pwsh；deps 容器里 pwsh + 真 PS 宿主语义）：
#   docker run --rm -v "$PWD":/repo backguard-native:deps-prev pwsh -NoProfile -File /repo/test_status_emit_logic.ps1
# 在 windows runner 上（CI 那一步）：pwsh -NoProfile -File test_status_emit_logic.ps1（两档宿主）
# 期望最后一行 STATUS-EMIT-OK；bash 侧对应物是 test_status_line.sh（真 borg 两轮，E2E）。
#
# 为什么单独切出来测：产出器挂在脚本最末尾的退出点上，windows job 的产品轮只证明「跑过了」，
# 不证明「写出的每一行都长该长的样子」。它有三类纯逻辑面可以在夹具上钉死：
#   ①字段与顺序和 backup.sh 的 append_status_line 逐字对齐（两份实现一个口径）；
#   ②零文件名、零绝对路径（红线 §1.1：这份文件随 timeline 上云）——诱饵 token 植进
#     $BackupBase 与设备名的每个角落，任何字段都不许把它们带出去；
#   ③落盘编码是 UTF-8 无 BOM（§11 续18/续19 的定案：5.1 的重定向写 UTF-16LE、
#     Add-Content 的 utf8 带 BOM，只有 AppendAllText + UTF8Encoding($false) 两档宿主同形）。
#
# 状态位口径：cv/ig 的 state 由 $script:RoundCvRan / $script:RoundIgRan 决定——「没跑」与
# 「跑了且全过」必须分得开（bash 侧同一课：SKIP_WEBDAV 时计数器停在 0，从计数器反推就是
# 把「没跑」演成「全过」）。本测试直接摆布这些位，每种组合各来一行。
#
# 变异台账：
#   st01 ts 字段换成 (Get-Item $BackupBase).FullName（绝对路径入体）
#       BITTEN count=2  首条=隐私：行里出现了夹具绝对路径
#   st02 追加改覆写（AppendAllText 换 WriteAllText）
#       BITTEN count=1  首条=第二次调用后应两行
#   st03 cv_state 不再看 RoundCvRan（没跑也报 pass）
#       BITTEN count=1  首条=没跑自证时 state 必须 skipped
param([string]$Repo = '')
if (-not $Repo) { $Repo = $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:fail = 0
function Chk([string]$name, $cond, [string]$detail = '') {
    $ok = if ($null -eq $cond) { $false }
          elseif ($cond -is [System.Array]) { @($cond).Count -gt 0 }
          else { [bool]$cond }
    if ($ok) { Write-Host "ok   - $name $detail" }
    else { Write-Host "FAIL - $name $detail"; $script:fail++ }
}

function Slice([string]$Tag) {
    $src = Get-Content -Raw (Join-Path $Repo 'backup.ps1')
    $m = [regex]::Match($src, "(?ms)^# BEGIN-$Tag[^\r\n]*\r?\n(.*?)^# END-$Tag")
    if (-not $m.Success) {
        throw "哨兵 # BEGIN-$Tag / # END-$Tag 在 backup.ps1 里没成对出现——生产改了标记，这份守卫必须先炸"
    }
    $m.Groups[1].Value
}
. ([scriptblock]::Create((Slice 'STATUS')))
# Get-RunGitSha 也在 BEGIN-BOUNDARY 段里，产出器要调它——一并切进来
. ([scriptblock]::Create((Slice 'BOUNDARY')))
Chk '切出了被测函数' ($null -ne (Get-Command Add-StatusLine -ErrorAction SilentlyContinue))

$script:root = Join-Path ([System.IO.Path]::GetTempPath()) ("bgstatusemit-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:root | Out-Null

$script:srcPs1 = Get-Content -Raw (Join-Path $Repo 'backup.ps1')
$secretName = "秘密文档-不出现.txt"

# ---------- 夹具：timeline（含快照两层、诱饵 rescue-test）+ 状态位各摆一档 ----------
function New-Timeline {
    $base = Join-Path $script:root ("tl-" + [guid]::NewGuid().ToString('N'))
    # 路径分隔符用 /：夹具要在 pwsh7/Linux 容器与 5.1/Windows 两档宿主上都长出**真**四层——
    # 反斜杠字面量在 Linux 上是一个目录名（AGENTS §2「分隔符改掉就不再是被测的那份脚本」同一条）
    $snap = "$base/timeline/2026/10/03/2230-night"
    New-Item -ItemType Directory -Force -Path $snap | Out-Null
    Set-Content -LiteralPath (Join-Path $snap "STORY.md") -Value "story" -Encoding utf8
    Set-Content -LiteralPath "$base/timeline/rescue-test.txt" -Value "RESULT: 6 PASS / 0 FAIL（抽样 6；内容哈希 6，仅比大小 0）" -Encoding utf8
    return $base   # 与生产同参：产出器吃的是 BACKUP_BASE，自己拼 timeline
}
function Read-Lines([string]$base) {
    # 与生产同参：吃 BACKUP_BASE，自己拼 timeline（少拼一层=永远读不到，10-03 踩过一次）
    $p = Join-Path (Join-Path $base "timeline") "STATUS.jsonl"
    # 调用方必须 @(...) 接：单行文件时 Get-Content 交回标量字符串，不包 @() 的话
    # `[0]` 取到首字符（rescue.ps1 m02 同一类陷阱，10-03 在这份守卫自己身上又撞了一次；
    # 函数内**不要**再套前导逗号——与调用点的 @() 叠加会把整个数组包成单个元素）
    @((Get-Content -LiteralPath $p -ErrorAction SilentlyContinue) | Where-Object { "$_".Trim() })
}
# 摆状态位：每个场景自己给，避免上一场景的位漏进下一场景（测试里的全局同样会「跨轮残留」）
function Set-Flags {
    param([bool]$CvRan, [bool]$IgRan)
    $script:RoundCvRan = $CvRan
    $script:RoundIgRan = $IgRan
    $script:RoundEngineFailed = 0
    $script:RoundCloudFailed = 0
    $script:VerifyFailed = 0; $script:VerifyHealed = 0; $script:VerifyUnknown = 0
    $script:IntegrityFailed = 0
    $script:IntegrityLines = @('PASS a', 'PASS b', 'PASS c')
}
$env:DEVICE_ID = "e2e-status"

# ---------- 场景1：全绿位 → 单行、合法 JSON、字段齐、与 bash 同序 ----------
$tl1 = New-Timeline
Set-Flags -CvRan $true -IgRan $true
Add-StatusLine -BackupBase $tl1 -Rc 0 -DurationSec 42
$lines1 = @(Read-Lines $tl1)
Chk '场景1 一次调用 = 恰好一行' (@($lines1).Count -eq 1) "实得 $(@($lines1).Count) 行"
$row1 = $null
try { $row1 = $lines1[0] | ConvertFrom-Json } catch { }
Chk '场景1 行是合法 JSON' ($null -ne $row1) "$($lines1[0])"
Chk '场景1 format 与 bash 同一串' ($row1 -and "$($row1.format)" -eq 'backguard/status/1') "实得 $(if ($row1) { $row1.format })"
$wantOrder = @('format','ts','device','engine','sha','rc','dur_s','engine_failed','cloud_push_failed',
    'cv_state','cv_failed','cv_healed','cv_unknown','ig_state','ig_checks','ig_failed',
    'drill_pass','drill_total','drill_age_d','snapshots')
$gotOrder = if ($row1) { @($row1.PSObject.Properties | ForEach-Object { $_.Name }) } else { @() }
$same = ($gotOrder.Count -eq $wantOrder.Count)
if ($same) { for ($i = 0; $i -lt $wantOrder.Count; $i++) { if ($gotOrder[$i] -ne $wantOrder[$i]) { $same = $false } } }
Chk '场景1 字段顺序与 backup.sh 逐字对齐' $same "实得: $($gotOrder -join ',')"
Chk '场景1 引擎字段 = restic（这一侧只有 restic）' ($row1 -and "$($row1.engine)" -eq 'restic') "实得 $(if ($row1) { $row1.engine })"
Chk '场景1 cv_state=pass / ig_state=pass checks=3' (
    $row1 -and "$($row1.cv_state)" -eq 'pass' -and "$($row1.ig_state)" -eq 'pass' -and $row1.ig_checks -eq 3) `
    "实得 cv=$($row1.cv_state) ig=$($row1.ig_state)/$($row1.ig_checks)"
Chk '场景1 演练 6 pass / 0 fail 解析自 rescue-test' (
    $row1 -and $row1.drill_pass -eq 6 -and $row1.drill_total -eq 0) `
    "实得 $($row1.drill_pass)/$($row1.drill_total) @$($row1.drill_age_d)d"
Chk '场景1 快照计数认到第 4 层' ($row1 -and $row1.snapshots -eq 1) "实得 $($row1.snapshots)"

# ---------- 场景2：隐私——绝对路径与文件名都不许进体 ----------
Chk '场景2 隐私：行里没有夹具绝对路径' (-not ("$($lines1[0])".Contains($script:root))) "见行"
Chk '场景2 隐私：行里没有源文件名' (-not ("$($lines1[0])".Contains($secretName))) "见行"
Chk '场景2 隐私：诱饵 rescue-test 的 RESULT 行本体没被抄进去（只取数字）' (
    -not ("$($lines1[0])".Contains('内容哈希'))) "见行"

# ---------- 场景3：追加不改写；坏位组合各占一行 ----------
Add-StatusLine -BackupBase $tl1 -Rc 0 -DurationSec 43
Chk '场景3 第二次调用后两行（AppendAllText 不是 WriteAllText）' (@(Read-Lines $tl1).Count -eq 2) `
    "实得 $(@(Read-Lines $tl1).Count) 行"

$tl2 = New-Timeline
Set-Flags -CvRan $false -IgRan $false
Add-StatusLine -BackupBase $tl2 -Rc 0 -DurationSec 1
$row2 = @(Read-Lines $tl2)[0] | ConvertFrom-Json
Chk '场景3 没跑自证/完整性 → 两档 state 都是 skipped（不把「没跑」演成「全过」）' (
    "$($row2.cv_state)" -eq 'skipped' -and "$($row2.ig_state)" -eq 'skipped') `
    "实得 cv=$($row2.cv_state) ig=$($row2.ig_state)"

$tl3 = New-Timeline
Set-Flags -CvRan $true -IgRan $false
$script:VerifyFailed = 2; $script:VerifyHealed = 1
Add-StatusLine -BackupBase $tl3 -Rc 1 -DurationSec 1
$row3 = @(Read-Lines $tl3)[0] | ConvertFrom-Json
Chk '场景3 fail 压过 healed（不一致时结论必须是 fail）' (
    "$($row3.cv_state)" -eq 'fail' -and $row3.cv_failed -eq 2 -and $row3.cv_healed -eq 1) `
    "实得 cv=$($row3.cv_state) f=$($row3.cv_failed) h=$($row3.cv_healed)"
Chk '场景3 rc=1 原样进字段' ($row3.rc -eq 1) "实得 $($row3.rc)"

# ---------- 场景4：落盘编码 = UTF-8 无 BOM（续18/续19 的字节判据）----------
$tl4 = New-Timeline
Set-Flags -CvRan $false -IgRan $false
Add-StatusLine -BackupBase $tl4 -Rc 0 -DurationSec 1
$bytes4 = [IO.File]::ReadAllBytes((Join-Path (Join-Path $tl4 "timeline") "STATUS.jsonl"))
$head4 = ($bytes4 | Select-Object -First 3 | ForEach-Object { $_.ToString('X2') }) -join ' '
Chk '场景4 无 BOM（前 3 字节不是 EF BB BF）' ($head4 -ne 'EF BB BF') "head=$head4"
$nul4 = @($bytes4 | Where-Object { $_ -eq 0 }).Count
Chk '场景4 无 NUL（不是 UTF-16LE 躺着）' ($nul4 -eq 0) "nul=$nul4"
$ascii4 = [regex]::IsMatch([Text.Encoding]::UTF8.GetString($bytes4), '^[ -~\r\n{}":,_/.a-z-]+$')
Chk '场景4 全 ASCII（状态行没有中文字段，两档宿主同形）' $ascii4 '字段值只来自受控词表与数字'

# ---------- 场景5：timeline 不存在 → 静默跳过（旁路，§1.3）----------
$tl5 = Join-Path $script:root "tl-absent"
$threw5 = ''
try { Add-StatusLine -BackupBase $tl5 -Rc 0 -DurationSec 0 } catch { $threw5 = $_.Exception.Message }
Chk '场景5 timeline 缺失不抛、不建目录' ($threw5 -eq '' -and -not (Test-Path -LiteralPath $tl5)) "threw=$threw5"

Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host "STATUS-EMIT-FAIL count=$script:fail"
    exit 1
}
Write-Host '=== STATUS-EMIT-OK ==='
exit 0
