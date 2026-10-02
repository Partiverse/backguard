# test_log_rotation_logic.ps1 —— backup.ps1 的日志轮转 + run 边界行逻辑测试
#
# 怎么跑（本机无 pwsh，用 Linux 容器里的 pwsh 7；仓库根挂成 /repo）：
#   docker run --rm -v "$PWD":/repo:ro mcr.microsoft.com/powershell:lts \
#     pwsh -NoProfile -File /repo/test_log_rotation_logic.ps1
# 在 Windows runner 上（CI 那一步）：
#   pwsh -NoProfile -File backup-test 即 pwsh -NoProfile -File test_log_rotation_logic.ps1
# 期望最后一行 ROTATE-LOGIC-OK；变异验证同 bash 侧规矩（见文末清单）。
#
# 它测的是**逻辑**，接线由 ci.yml windows job 的「行为」那一步在同一台真 Windows 上验：
#   本文件从 backup.ps1 里按哨兵标记**原样切出**两个函数（不是复制粘贴——复制的实现对不上
#   生产，守卫就成了摆设，与 test_bsd_probe.sh 同一条约定）。所以「哨兵还在、还连着这两个
#   函数」本身是第一条断言：改生产时把标记挪走或改名，这里当场炸，而不是安静地切出一段
#   旧代码继续全绿。
#   不覆盖的：反斜杠路径与大小写不敏感（Linux 容器造不出来，留给 windows job）、
#   Windows PowerShell 5.1 那台宿主（另有一步用 shell: powershell 跑同一份文件）。
#
# 变异台账（摘 backup.ps1 的实现、这份必须报 FAIL；10-02 实测逐条 CAUGHT）：
#   m1 形态白名单摘掉（`Where-Object { $true }`）→ 场景3 keepme 被删 + copies/removed 变 9/5
#   m2 「必须是普通文件」摘掉                 → 场景3 整轮抛异常（Remove-Item 对非空目录）
#   m3 尺寸闸门摘掉（`if ($false) { return 0 }`）→ 场景1 没超限也切了
#   m4 `Select-Object -Skip $Keep` 变 `-Skip 0`  → 场景2 刚切的那份自己被删光
#   m5 按 Name 排序代替按 mtime                → 场景3 窗口里剩的是最旧那三份
#   m6 边界行 Add-Content 变 Set-Content       → 场景4 只剩一行（覆盖不是追加）
#   m7b `Get-Command git` 缺失那支的 nogit 退化摘掉 → 场景6 交回空串
#   已知**测不到**的一支：`Get-RunGitSha` 末尾那条 `return "nogit"`（容器里没有 git，函数在
#   上面一行就返回了）。它由 windows runner 走到——那台有 git，而 $T 不是仓库；5.1 那一步跑
#   同一份文件时覆盖。同理 `Rotate-LogFile` 的 `-PathType Leaf` 被尺寸判定掩盖（见函数内注释）。
param([string]$Repo = '')
if (-not $Repo) { $Repo = $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$fail = 0
function Chk([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "ok   - $name $detail" }
    else { Write-Host "FAIL - $name $detail"; $script:fail++ }
}
$script:skipped = @()
function Skip([string]$name, [string]$why) {
    Write-Host "skip - $name（$why）"
    $script:skipped = @($script:skipped) + $name
}

# ---------- 从生产源码里切出被测函数 ----------
function Slice([string]$Tag) {
    $src = Get-Content -Raw (Join-Path $Repo 'backup.ps1')
    $m = [regex]::Match($src, "(?ms)^# BEGIN-$Tag[^\r\n]*\r?\n(.*?)^# END-$Tag")
    if (-not $m.Success) {
        throw "哨兵 # BEGIN-$Tag / # END-$Tag 在 backup.ps1 里没成对出现——生产改了标记，这份守卫必须先炸，不能安静地测一段旧代码"
    }
    $m.Groups[1].Value
}
. ([scriptblock]::Create((Slice 'ROTATE')))
. ([scriptblock]::Create((Slice 'BOUNDARY')))
Chk '切出了被测函数' ($null -ne (Get-Command Rotate-LogFile -ErrorAction SilentlyContinue) `
    -and $null -ne (Get-Command Write-RunBoundary -ErrorAction SilentlyContinue))

$shape = 'backup\.log\.[0-9]{8}-[0-9]{6}'

# 证据行 + 返回值 + 抛出的异常一起收进字符串：Write-Host 走 information(6)、函数的
# return 走 success(3)，少收一条流就会有断言恒假；而「函数里抛终止性异常被上层 catch 降
# 成 warning」与「压根没被调用」在产物上长得一模一样，所以异常也得进证据（AGENTS §3 那条）。
function Run-Rotate([string]$Path, [long]$Max, [int]$Keep) {
    try {
        @(Rotate-LogFile -Path $Path -MaxBytes $Max -Keep $Keep 3>&1 6>&1 | ForEach-Object { "$_" }) -join "`n"
    } catch {
        "ROTATE-THREW: $($_.Exception.Message)"
    }
}
function Seed-File([string]$Dir, [string]$Name, [int]$Bytes, [datetime]$When) {
    $p = Join-Path $Dir $Name
    ('x' * $Bytes) | Set-Content -LiteralPath $p -NoNewline -Encoding ascii
    (Get-Item -LiteralPath $p).LastWriteTime = $When
    $p
}
function Rotated-Count([string]$Dir, [string]$Base) {
    @(Get-ChildItem -LiteralPath $Dir -Force -File | Where-Object { $_.Name -like "$Base.*" }).Count
}

$T = Join-Path ([System.IO.Path]::GetTempPath()) ('rot-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($T)

# ---------- 1：没超阈值不切 ----------
$d1 = Join-Path $T 's1'; [void][System.IO.Directory]::CreateDirectory($d1)
$log1 = Seed-File $d1 'backup.log' 2048 (Get-Date)
$ev1 = Run-Rotate $log1 4194304 7
Chk '场景1 现役日志原样还在' (Test-Path -LiteralPath $log1)
Chk '场景1 没切出副本' ((Rotated-Count $d1 'backup.log') -eq 0)
Chk '场景1 一行证据都不许有' ($ev1 -notmatch 'ROTATE') "实得: $ev1"

# ---------- 2：超阈值才切，切完现役日志是空的（历史噪音离开现役日志＝A4 的立论）----------
$d2 = Join-Path $T 's2'; [void][System.IO.Directory]::CreateDirectory($d2)
$log2 = Seed-File $d2 'backup.log' 3000 (Get-Date)
$ev2 = Run-Rotate $log2 1024 7
$cop2 = @(Get-ChildItem -LiteralPath $d2 -Force -File | Where-Object { $_.Name -like 'backup.log.*' })
Chk '场景2 切出了恰好一份副本' ($cop2.Count -eq 1) "实得 $($cop2.Count)"
Chk '场景2 副本名是轮转形态' ($cop2.Count -eq 1 -and $cop2[0].Name -match "^$shape$") `
    "实得 $(if ($cop2.Count) { $cop2[0].Name } else { '(无)' })"
Chk '场景2 内容搬进副本而不是截断' ($cop2.Count -eq 1 -and (Get-Item -LiteralPath $cop2[0].FullName).Length -eq 3000)
Chk '场景2 现役日志已让位（下一轮从头写）' (-not (Test-Path -LiteralPath $log2))
Chk '场景2 证据行报出 size/max/keep' ($ev2 -match 'ROTATE backup\.log size=3000 max=1024 keep=7 copies=1 removed=0') "实得: $ev2"

# ---------- 3：KEEP 封顶 + 两道删除守卫各挡一种坏法 ----------
$d3 = Join-Path $T 's3'; [void][System.IO.Directory]::CreateDirectory($d3)
$log3 = Seed-File $d3 'backup.log' 3000 (Get-Date)
$keep3 = @()
$seeded3 = @()
for ($i = 1; $i -le 6; $i++) {
    $n = 'backup.log.{0:D8}-{1:D6}' -f (20250100 + $i), 23400
    $when = [datetime]::new(2025, 1, $i, 2, 34, 0)
    [void](Seed-File $d3 $n 10 $when)
    # mtime 必须逐个写死：同秒并列会让「留哪几份」变成运气（bash 侧同一条规矩）
    $seeded3 += $n
    if ($i -ge 5) { $keep3 += $n }        # 排序后最新的前两份旧副本 = 窗口内
}
# 形态守卫要放过的：宽 glob 捞得到、但不是轮转形态（mtime 落在删除段）
$keepme = Seed-File $d3 'backup.log.keepme' 10 ([datetime]::new(2024, 12, 1, 2, 34, 0))
# 「必须是普通文件」那道守卫要放过的：同名**形态合规的目录**，里面有内容
$dirOld = Join-Path $d3 'backup.log.20241231-235900'
[void][System.IO.Directory]::CreateDirectory($dirOld)
'marker' | Set-Content -LiteralPath (Join-Path $dirOld 'marker.txt')
(Get-Item -LiteralPath $dirOld).LastWriteTime = [datetime]::new(2024, 12, 31, 2, 34, 0)

$ev3 = Run-Rotate $log3 1024 3
$left3 = @(Get-ChildItem -LiteralPath $d3 -Force -File | Where-Object { $_.Name -match "^$shape$" } |
    ForEach-Object { $_.Name } | Sort-Object)
Chk '场景3 轮转副本封顶在 KEEP=3' ($left3.Count -eq 3) "实剩 $($left3.Count) 份: $($left3 -join ', ')"
Chk '场景3 窗口内那两份旧副本留着' ($left3 -contains 'backup.log.20250106-023400' -and
    $left3 -contains 'backup.log.20250105-023400') "实剩: $($left3 -join ', ')"
Chk '场景3 本轮刚切的那份占住最新一格' (@($left3 | Where-Object { $seeded3 -notcontains $_ }).Count -eq 1) `
    "非种子的那份: $(@($left3 | Where-Object { $seeded3 -notcontains $_ }) -join ', ')"
Chk '场景3 超出窗口的四份旧副本都清理了' (@(1, 2, 3, 4 | Where-Object {
    Test-Path -LiteralPath (Join-Path $d3 ('backup.log.{0:D8}-023400' -f (20250100 + $_))) }).Count -eq 0) `
    "仍在的编号: $(@(1, 2, 3, 4 | Where-Object { Test-Path -LiteralPath (Join-Path $d3 ('backup.log.{0:D8}-023400' -f (20250100 + $_))) }) -join ',')"
Chk '场景3 形态白名单守住了 backup.log.keepme' ((Test-Path -LiteralPath $keepme) -and
    (Get-Content -LiteralPath $keepme -Raw) -match 'x')
# 这道守卫的代价不是「少删一个」而是「连内容一起递归删」：Remove-Item 对目录等于数据丢失
Chk '场景3 同名合规目录没被当成超额副本删掉' (Test-Path -LiteralPath $dirOld)
Chk '场景3 那个目录里的内容还在' (Test-Path -LiteralPath (Join-Path $dirOld 'marker.txt'))
Chk '场景3 证据行 copies/removed 对得上' ($ev3 -match 'copies=8 removed=4') "实得: $ev3"
Chk '场景3 整轮没抛异常' ($ev3 -notmatch 'ROTATE-THREW') "实得: $ev3"

# ---------- 4：run 边界行——一轮一行、三字段齐、追加不覆盖 ----------
$d4 = Join-Path $T 's4'; [void][System.IO.Directory]::CreateDirectory($d4)
$bl4 = Join-Path $d4 'backup.log'
Write-RunBoundary -Path $bl4 -Sha 'abc1234' -Rc 0 -DurationSec 42
Write-RunBoundary -Path $bl4 -Sha 'def5678' -Rc 1 -DurationSec 7
$lines4 = @(Get-Content -LiteralPath $bl4)
Chk '场景4 两轮各一行（追加不是覆盖）' ($lines4.Count -eq 2) "实得 $($lines4.Count) 行: $($lines4 -join ' | ')"
Chk '场景4 字段形状 sha=/rc=/dur=' ($lines4[0] -match '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] run boundary: sha=abc1234 rc=0 dur=42s$') "实得: $($lines4[0])"
Chk '场景4 失败轮的 rc 如实记 1' ($lines4[1] -match 'sha=def5678 rc=1 dur=7s') "实得: $($lines4[1])"
Chk '场景4 边界行是纯 ASCII（同一文件由 Tee-Object 写，编码在 5.1/7 不同档）' ($lines4[0] -notmatch '[^\x00-\x7F]')

# ---------- 5：两处旁路都不得反过来终止备份 ----------
# 用**正斜杠**拼一个父目录不存在的目标：`Join-Path $T 'no-such-dir\backup.log'` 在 Linux
# 容器里是一整个合法文件名（反斜杠不是分隔符），而 $T 存在 → Add-Content 直接写成功，
# 断言恒假（windows runner 上才成立的那条路，在逻辑测试里必须先保证两端同形）
$missing5 = [System.IO.Path]::Combine($T, 'no-such-dir', 'backup.log')
$ev5 = try {
    @(Write-RunBoundary -Path $missing5 3>&1 6>&1 | ForEach-Object { "$_" }) -join "`n"
} catch { "BOUNDARY-THREW: $($_.Exception.Message)" }
Chk '场景5 日志目录不在时只告警不抛' ($ev5 -notmatch 'BOUNDARY-THREW') "实得: $ev5"
Chk '场景5 告警自己报了原因' ($ev5 -match 'BOUNDARY-WRITE-FAILED') "实得: $ev5"

# ---------- 6：代码基标记取不到就退化成 nogit ----------
$d6 = Join-Path $T 's6'; [void][System.IO.Directory]::CreateDirectory($d6)
Chk '场景6 非仓库目录退化成 nogit' ((Get-RunGitSha -Path $d6) -ceq 'nogit') "实得: $(Get-RunGitSha -Path $d6)"
Chk '场景6 路径压根不存在也不许抛' ((Get-RunGitSha -Path (Join-Path $T 'nope-none')) -ceq 'nogit')
if (Get-Command git -ErrorAction SilentlyContinue) {
    $r6 = Join-Path $T 'repo6'; [void][System.IO.Directory]::CreateDirectory($r6)
    & git -C $r6 init -q 2>$null
    & git -C $r6 -c user.email=e@e -c user.name=e commit -q --allow-empty -m e 2>$null
    $s6 = Get-RunGitSha -Path $r6
    Chk '场景6 真仓库交回短 sha' ($s6 -match '^[0-9a-f]{7,40}$') "实得: $s6"
} else {
    Skip '场景6 真仓库那一支' '容器里没有 git，只有 windows job 那台宿主能验'
}

Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { Write-Host "ROTATE-LOGIC-FAIL count=$fail"; exit 1 }
$sk = if ($script:skipped) { " skipped=$($script:skipped.Count)" } else { ' skipped=0' }
Write-Host "ROTATE-LOGIC-OK$sk"
# 必须显式 exit 0：CI 那两步都读 `$LASTEXITCODE`，而宿主在没有 exit 语句时拿**最后一条
# 原生命令**的退出码当宿主退出码（云端失败可见性那条守卫实测过：四条断言全过、打了 OK 行，
# step 仍 rc=1）。不写这行，「逻辑测试全绿」会伪装成「它红了」。
exit 0
