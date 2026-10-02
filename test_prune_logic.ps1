# test_prune_logic.ps1 —— semantic.ps1 的 Prune-LocalTimeline + Format-IsoTime 逻辑测试
# （手工跑，不入 CI）。
#
# 怎么跑（本机无 pwsh，用 Linux 容器里的 pwsh 7；仓库根挂成 /repo）：
#   docker run --rm -v "$PWD":/repo:ro mcr.microsoft.com/powershell:lts \
#     pwsh -NoProfile -File /repo/test_prune_logic.ps1
# 期望最后一行 PRUNE-LOGIC-OK；变异验证同 bash 侧规矩（改实现的那一发，摘掉白名单/级联排序/
# 深度判定后这份必须报 FAIL，报不出就是断言是死的）。
#
# 覆盖范围与**不覆盖**的部分，说清楚免得把它当 Windows 真机：
#   覆盖：语法、cmdlet 参数绑定、排序键、叶子白名单、空壳级联、KEEP 的默认/关闭/垃圾值分支，
#         以及 Format-IsoTime 的四种类型分支（场景 7）
#         ——这些与 Windows 上的 pwsh 7 是同一份实现，也正是 CI 一轮 25 分钟才验一次的部分。
#   不覆盖：反斜杠路径与大小写不敏感（Linux 上造不出来，只有 windows job 那发守卫在真 Windows
#         文件系统上跑）、Windows PowerShell 5.1 那台宿主（Task Scheduler 注册的是 powershell.exe，
#         见 AGENTS §5 的 5.1 未验证面清单）。
#   所以它替代不了 ci.yml 里 windows job 的 `Assert local timeline retention`，两发的分工是
#   「逻辑先在这里几秒收敛，接线与环境留给 CI」。
param([string]$Repo = '/repo')

$fail = 0
function Chk([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "ok   - $name $detail" }
    else { Write-Host "FAIL - $name $detail"; $script:fail++ }
}

# 证据行 + 告警一起收进字符串：Write-Host 走 information(6)，Write-Warning 走 warning(3)，
# 少收一条流就会有断言恒假（CI 那两段守卫同样踩过这个面）
function Run-Prune([string]$Stage) {
    (@(Prune-LocalTimeline -Stage $Stage 3>&1 6>&1 | ForEach-Object { "$_" }) -join "`n")
}
function Get-SnapDirs([string]$Root) {
    $n = $Root.Length
    @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.Length -gt $n -and
            (($_.FullName.Substring($n).TrimStart('\', '/') -split '[\\/]').Count) -eq 4 })
}
function Seed([string]$Stage, [datetime]$When, [string]$Leaf = '0900-seed') {
    $rel = ($When.ToString('yyyy') + '/' + $When.ToString('MM') + '/' + $When.ToString('dd') + '/' + $Leaf)
    $p = Join-Path $Stage $rel
    [void][System.IO.Directory]::CreateDirectory($p)
    'seed' | Out-File (Join-Path $p 'marker.txt')
    $p
}
# 与 CI 守卫同形：3 份回推种子 + 1 个不合规叶子 + 1 份「本轮真快照」
function Seed-Tree([string]$Stage) {
    $now = Get-Date
    $script:Now = $now
    @{
        pNew  = Seed $Stage $now.AddDays(-60)
        pMid  = Seed $Stage $now.AddDays(-120)
        pOld  = Seed $Stage $now.AddDays(-180)
        pBad  = Seed $Stage $now.AddDays(-61) 'notes'
        pFar  = Seed $Stage $now.AddDays(-400)
        fresh = Seed $Stage $now '1412-night'
    }
}

$ErrorActionPreference = 'Stop'
$T = Join-Path ([System.IO.Path]::GetTempPath()) ('prune-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($T)
. (Join-Path $Repo 'semantic/semantic.ps1')
Chk 'dot-source 后函数存在' ($null -ne (Get-Command Prune-LocalTimeline -ErrorAction SilentlyContinue))

# ---- 场景 1：KEEP=1，5 个第 4 层目录 → 只留最新那份，不合规那份活着，空壳自深向浅收掉 ----
$s1 = Join-Path $T 's1'; [void][System.IO.Directory]::CreateDirectory($s1)
$d = Seed-Tree $s1
Chk '场景1 种子形状' (@(Get-SnapDirs $s1).Count -eq 6) "实际 $(@(Get-SnapDirs $s1).Count)"
$env:SEM_TIMELINE_KEEP = '1'
$ev1 = Run-Prune $s1
Chk '场景1 证据行 keep=1 snaps=6' ($ev1 -match 'timeline-retention window: keep=1 snaps=6') "实得: $ev1"
Chk '场景1 最旧已删' (-not (Test-Path -LiteralPath $d.pOld))
Chk '场景1 次旧已删' (-not (Test-Path -LiteralPath $d.pMid))
Chk '场景1 第三旧已删' (-not (Test-Path -LiteralPath $d.pNew))
Chk '场景1 窗口内那份留着' (Test-Path -LiteralPath $d.fresh)
Chk '场景1 不合规那份留着' (Test-Path -LiteralPath $d.pBad)
Chk '场景1 不合规那份内容也在' (Test-Path -LiteralPath (Join-Path $d.pBad 'marker.txt'))
Chk '场景1 白名单告警打过' ($ev1 -match '跳过非快照形态路径')
$shellOld = Split-Path $d.pOld -Parent
Chk '场景1 日期壳收掉' (-not (Test-Path -LiteralPath $shellOld))
Chk '场景1 月份壳一并收掉' (-not (Test-Path -LiteralPath (Split-Path $shellOld -Parent)))
# 跨年那份（-400 天）被裁后，它的 年/月/日 三层壳必须整条消失——一趟「先筛空再统一删」
# 只会收掉日期这一层，bash 侧 find -delete 隐含 -depth 会一路收到年
$farDay = Split-Path $d.pFar -Parent           # 2025/MM/DD
$farMon = Split-Path $farDay -Parent           # 2025/MM
$farYear = Split-Path $farMon -Parent          # 2025
Chk '场景1 跨年种子的日期壳收掉' (-not (Test-Path -LiteralPath $farDay))
Chk '场景1 跨年种子的月份壳收掉' (-not (Test-Path -LiteralPath $farMon))
Chk '场景1 跨年种子的年壳收掉' (-not (Test-Path -LiteralPath $farYear))
Chk '场景1 仍有内容的月壳留着(08)' (Test-Path -LiteralPath (Split-Path (Split-Path $d.pBad -Parent) -Parent))
Chk '场景1 只剩两份' (@(Get-SnapDirs $s1).Count -eq 2) "实际 $(@(Get-SnapDirs $s1).Count)"
# CI 第二段断言的是「合规快照只剩 1 份」而不是「总共只剩两份」——两条口径不同，
# notes 那份不合规但必须活着。把 CI 那条同形搬过来，免得 windows 那发是它唯一的读者
$okLeaves = @(Get-SnapDirs $s1 | ForEach-Object { $_.Name } | Where-Object { $_ -match '^[0-9]{4}-[a-z0-9-]+$' })
Chk '场景1 合规快照只剩 1 份（CI 第二段同一条）' ($okLeaves.Count -eq 1) "实剩: $($okLeaves -join ', ')"
Chk '场景1 stage 根没被删' (Test-Path -LiteralPath $s1)

# ---- 场景 2：不设 KEEP → 回落默认 14，5 份不裁 ----
$s2 = Join-Path $T 's2'; [void][System.IO.Directory]::CreateDirectory($s2)
[void](Seed-Tree $s2)
Remove-Item Env:\SEM_TIMELINE_KEEP -ErrorAction SilentlyContinue
$ev2 = Run-Prune $s2
Chk '场景2 证据行 keep=14 snaps=6' ($ev2 -match 'timeline-retention window: keep=14 snaps=6') "实得: $ev2"
Chk '场景2 一份都没删' (@(Get-SnapDirs $s2).Count -eq 6)

# ---- 场景 3：KEEP=0 → 显式关闭，不清理 ----
$s3 = Join-Path $T 's3'; [void][System.IO.Directory]::CreateDirectory($s3)
[void](Seed-Tree $s3)
$env:SEM_TIMELINE_KEEP = '0'
$ev3 = Run-Prune $s3
Chk '场景3 证据行标 disabled' ($ev3 -match 'keep=0 snaps=0 \(disabled\)') "实得: $ev3"
Chk '场景3 一份都没删' (@(Get-SnapDirs $s3).Count -eq 6)

# ---- 场景 4：KEEP 是垃圾串 → 回落 14，且不许抛异常（AGENTS §1.3 旁路没资格带走备份）----
$s4 = Join-Path $T 's4'; [void][System.IO.Directory]::CreateDirectory($s4)
[void](Seed-Tree $s4)
$env:SEM_TIMELINE_KEEP = 'abc; rm -rf /'
$ev4 = Run-Prune $s4
Chk '场景4 回落默认 14' ($ev4 -match 'keep=14 snaps=6') "实得: $ev4"
Chk '场景4 没抛异常' ($ev4 -notmatch 'aborted by exception')
Chk '场景4 一份都没删' (@(Get-SnapDirs $s4).Count -eq 6)

# ---- 场景 5：stage 根不存在 → 只报证据行，不炸、不动别处 ----
$ev5 = Run-Prune (Join-Path $T 'nope')
Chk '场景5 证据行标 no-stage' ($ev5 -match 'snaps=0 \(no-stage\)') "实得: $ev5"

# ---- 场景 6：深度不是 4 层的目录不许进候选（误删面）----
$s6 = Join-Path $T 's6'; [void][System.IO.Directory]::CreateDirectory($s6)
$now = Get-Date
$deep = Seed $s6 $now.AddDays(-200) 'x/0900-deep'          # 第 5 层
$shallow = Join-Path $s6 'shallow'; [void][System.IO.Directory]::CreateDirectory($shallow)
'stay' | Out-File (Join-Path $shallow 'marker.txt')
[void](Seed $s6 $now.AddDays(-60))
[void](Seed $s6 $now.AddDays(-120))
[void](Seed $s6 $now '1500-morning')
$env:SEM_TIMELINE_KEEP = '1'
$ev6 = Run-Prune $s6
Chk '场景6 只认出 4 个候选' ($ev6 -match 'keep=1 snaps=4') "实得: $ev6"
Chk '场景6 第 5 层没进候选' (Test-Path -LiteralPath $deep)
Chk '场景6 浅层目录没进候选' (Test-Path -LiteralPath $shallow)
Chk '场景6 第 5 层的叶子目录没被连坐删' (Test-Path -LiteralPath $deep)
Chk '场景6 深路径的第 4 层父目录靠白名单活着' ($ev6 -match '跳过非快照形态路径')
Chk '场景6 本轮快照留着' (Test-Path -LiteralPath (Join-Path $s6 ($now.ToString('yyyy/MM/dd') + '/1500-morning')))

# ---- 场景 7：Format-IsoTime——引擎 JSON 的 time 落到什么类型取决于宿主版本 ----
# restic snapshots --json 的 time 字段：pwsh 7.2 的 ConvertFrom-Json 交回 String（容器就是
# 这一档，所以下面第一条测的是透传），Windows PowerShell 5.1 与 pwsh 7.4+ 交回 [datetime]，
# 后者直接拼进命令行会变成文化格式的 `10/02/2026 06:31:11`——bg 在 generate 读它才崩，
# 而只有「存在上一份归档」的那一轮才会走到这里（10-02 windows job 集成段的真凶，见 §4.16b）。
$u7 = '2026-10-02T06:31:11.447503458+00:00'
Chk '场景7 String 原样透传' ((Format-IsoTime $u7) -ceq $u7) "实得: $(Format-IsoTime $u7)"
$utc7 = [datetime]::new(2026, 10, 2, 6, 31, 11, [DateTimeKind]::Utc)
Chk '场景7 DateTime(Utc) 转成 ISO 带 Z' ((Format-IsoTime $utc7) -ceq '2026-10-02T06:31:11Z') "实得: $(Format-IsoTime $utc7)"
$loc7 = [datetime]::new(2026, 10, 2, 6, 31, 11, [DateTimeKind]::Local)
$got7 = Format-IsoTime $loc7
Chk '场景7 DateTime(Local) 也是 ISO 形状' ($got7 -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') "实得: $got7"
Chk '场景7 不许落到文化分隔符' ($got7 -notmatch '/') "实得: $got7"
$off7 = [datetimeoffset]::new([datetime]::new(2026, 10, 2, 6, 31, 11), [TimeSpan]::FromHours(8))
Chk '场景7 DateTimeOffset 折算回 UTC' ((Format-IsoTime $off7) -ceq '2026-10-01T22:31:11Z') "实得: $(Format-IsoTime $off7)"
# 类型判别的反面：bg 侧要求「非 ISO 串一律读不动」，所以这里同时钉住「文化格式确实会炸」——
# 它证明场景 7 前四条不是空转：把 Format-IsoTime 摘成 [string]$Value，第一条仍绿而
# DateTime 那几条会当场报出 `10/02/2026 06:31:11`（变异验证的落点）
Chk '场景7 裸 ToString 就是那条坏串' ($utc7.ToString() -match '^\d{1,2}/\d{1,2}/\d{4}') "实得: $($utc7.ToString())"

Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { Write-Host "PRUNE-LOGIC-FAIL count=$fail"; exit 1 }
Write-Host "PRUNE-LOGIC-OK"
