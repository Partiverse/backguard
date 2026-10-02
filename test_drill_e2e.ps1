# test_drill_e2e.ps1 —— semantic.ps1 恢复演练（roadmap A2b 的 Windows 那一半）的端到端守卫
#
# 怎么跑（本机无 pwsh，仓库根挂 /repo）：
#   docker run --rm -v "$PWD":/repo:ro --entrypoint /bin/bash backguard-native:drill \
#     -c 'pwsh -NoProfile -File /repo/test_drill_e2e.ps1 -Repo /repo'
#   镜像要 restic + age + age-keygen + python3（bg 入口）+ rclone（场景10 的「云端」）：
#   `backguard-native:deps` 只有前三样，python3/rclone 用 apt 装上后 commit 成 `:drill`。
#   **镜像必须宿主原生架构**（arm64/amd64）：arm/v7 走 qemu 会在随机一条原生命令处崩
#   `Assertion failed: (dc->base.pc_next & 1) == 0`，那是模拟器的，不是被测实现的（同 test_rescue_e2e.ps1）。
#   windows job（CI 两步）：pwsh 7 一步 + Windows PowerShell 5.1 一步，同 rescue/init-keys 的口径。
# 期望最后一行 `DRILL-E2E-OK skipped=N`。**看到 OK 还要看 skipped 那一个数**：依赖不齐时真引擎
# 那几段整段 Skip——「没证据」不等于「通过」。
#
# 为什么这份守卫必须存在（不是把 bash 侧 test_drill_e2e.sh 复述一遍）：
#   Windows 侧此前**根本没有演练**——semantic.ps1 只密封 manifest.json.enc 然后就结束了，所以
#   「备份期记下源哈希」这一半即使做对了也仍是「记了没人用」。这一发把两半钉成一条链：
#   密封里真带了 sha256（场景1g 读的是 `[manifest] 演练样本内容哈希：n/N` 那行现场信号，
#   n=0 就是整段退化），演练里真按它比内容（场景2 换掉一个哈希必须当场露）。
#
# 覆盖：
#   ①全链路真跑（真 restic 三类别仓库 + 真 bg + 真 age）：快照目录、密封件、rescue-test.txt
#     三件都在；RESULT 行五个计数自洽；三个类别各有自己的 PASS 行（跨类别错配在这一条露头，
#     真机 10-01 就是它被放过）；抽样拉满时「仅比大小」必须为 0
#   ②篡改一个已记哈希 → 恰好 1 条 FAIL、报错写明「大小倒是一致」、Failed 判真（只比大小看不见）
#   ③30 天节流：产物 mtime 新 → Code=10 且**不改写**报告；SEM_DRILL_FORCE=1 绕开
#   ④SEM_DRILL=0：密封侧不带 --hash-drill-samples（解封后逐字节查 sha256 一个都不许有）、
#     演练侧 Code=20 且不落笔
#   ⑤缺主身份 / 缺 age → Code=20（不是「跑过了但 0 条」）
#   ⑥本轮没有某类别的快照 → 该条判 FAIL 并写明「无从取回」，绝不拿别的类别仓库去解
#   ⑦结论判定本身的死断言防线：缺 RESULT 行 / 两行 RESULT / 逐条 FAIL / 「0 FAIL」汇总行
#   ⑧隐私与凭据收尾清扫：整棵夹具不许留明文 manifest.json，日志与报告不许含 restic 口令值
#   ⑨红线 §1.1 的推送侧：Push-TreeToCloud 的 -ExcludeNames 真让 rescue-test.txt 上不了云，
#     而对照组（不带该参数）真把它推上去了——非空断言；返回值仍是单个整数（§1.4 的数组摊平坑）
#   ⑩--include 的形状：**用 argv 桩钉，不用真引擎钉**。posix 上「加不加前导斜杠」在 restic 那里
#     等价（10-03 复测：`src-files/note.txt` 与 `/src-files/note.txt` 都取回得到），真引擎抓不到
#     这一刀；桩把收到的 argv 原样落盘，判据是「反斜杠归成正斜杠、且不添前导斜杠」
#
# **不覆盖**（如实登记）：
#   - Windows 上 restic 归档内路径带盘符那一种形状（`C:/…` 被 bg 的 `_norm_path` 剥成 `Users/…`，
#     于是清单里的 path 是真归档路径的**后缀**）。容器证不到这一支：posix 上 `_norm_path` 只剥掉
#     前导斜杠，「把斜杠加回去」恒等于原形状，两种 --include 都能取回。场景11 钉住的是实现契约
#     （不添前导斜杠），真引擎那一支由 windows job 的同一份夹具跑真 restic 判，红了看得见。
#   - age 对 passphrase 只读终端的交互解封（恢复码路径 B，CI 打不了字；由 init-keys/rescue 那两份
#     守卫以桩证调用序列）。
#   - 网盘（123Pan WebDAV）语义：场景9 的「云端」是本地目录 + 真 rclone，不是 WebDAV。
#
# 变异台账（10-03，15 刀 / 15 咬住；每刀一份独立工作树 + 回读校验落刀 + 三份文件先过解析，
# 判据取**首条 FAIL 是不是这一刀主张的那件事**，不只看 rc。驱动 `backguard-native:drill` 容器）：
#   m01 密封侧不带 --hash-drill-samples → 场景1「内容哈希这一维真的生效」(hashed=0)
#   m02 splat 退回带括号的 @($hashArgs) → 场景1 结论行判出 `RESULT: FAIL（sample 没抽到条目…）`
#       （这一刀就是首轮那个真 bug：三个参数粘成一个 argv，而 bg 的报错与「参数真不认识」同形）
#   m03 只验「算得出哈希」不比值 → 场景2「判定为失败」
#   m04 抽到 0 条不判失败（退回 bash 旧口径 0/0）→ 场景4「空清单的报告写明原因」
#   m05 摘掉 30 天节流闸门 → 场景3「刚跑过 → Code=10」
#   m06 缺 age/主身份/密封件不报 Code=20 → 场景5「快照目录没密封件 → Code=20」
#   m07 样本仓库不按类别查（拿第一个仓库硬解）→ 场景1「无失败项」(PASS=2 FAIL=4)
#   m08 判定改回 grep 'RESULT: .*FAIL' → 场景7 a-「只有汇总行 0 失败」want=False
#   m09 结论行缺失/两行不判失败 → 场景7 c-「结论行缺失」want=True
#   m10 --include 强制前导斜杠 → 场景11「include 只把反斜杠归成正斜杠」
#       **这一刀容器里本来咬不住**（posix 上 restic 对加不加前导斜杠等价，10-03 复测两种写法都
#       取回得到），是场景11 的 argv 桩把它变成可判的；不删刀，把逃逸原因登记在这里
#   m11 取回命中改成按文件名相等（不按后缀）→ 场景1「无失败项」(PASS=0 FAIL=6)
#   m12 「仅比大小」的标注被砍短 → 场景4「每条 PASS 都写明依据」
#   m13 摘掉尺寸闸门 → 场景4「尺寸不符当场露」
#   m14 --exclude 根本没拼进 rclone 命令行 → 场景10「rescue-test.txt 没上云」
#   m15 时间轴调用点漏登记排除名（推送侧函数照旧，只有接线漏）→ 场景10「调用点登记了排除名」
#       这一刀的 catcher 只有静态断言：行为面（m14 那一档）抓不到「函数对、接线错」
param([string]$Repo = '')
if (-not $Repo) { $Repo = $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:fail = 0
$script:ok = 0
$script:skipped = @()
$script:isWin = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }

function Chk([string]$name, $cond, [string]$detail = '') {
    # 条件不收 [bool]：`-match` 左操作数是命令表达式时出来的是 Object[]，绑不进 [bool]
    $v = if ($null -eq $cond) { $false }
         elseif ($cond -is [System.Array]) { @($cond).Count -gt 0 }
         else { [bool]$cond }
    if ($v) { $script:ok++; Write-Host "ok   - $name $detail" }
    else { $script:fail++; Write-Host "FAIL - $name $detail" }
}
function Skip([string]$name, [string]$why) {
    Write-Host "skip - $name"
    $script:skipped = @($script:skipped) + "$name（$why）"
}
function Read-U8([string]$Path) {
    # 5.1 的 Get-Content 默认按 ANSI 码页读，而 semantic.ps1 写这些产物用的是 UTF-8 无 BOM
    # （[IO.File]::WriteAllLines）——5.1 那一步里中文会变成乱码，于是所有中文断言恒假。
    # 显式按 UTF-8 读，两个宿主同一份结论。
    @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
}
function New-Dir([string]$Rel) {
    $p = Join-Path $script:root $Rel
    [void][System.IO.Directory]::CreateDirectory($p)
    $p
}
function Write-U8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Run-Native([string[]]$A, [hashtable]$Env = @{}) {
    $prev = @{}
    foreach ($k in @($Env.Keys)) {
        $prev[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $Env[$k])
    }
    $o = @(); $rc = -1
    try {
        $ErrorActionPreference = 'Continue'   # restic/age 把进度与警告写 stderr：5.1 上是终止性异常
        $o = @(& $A[0] @($A[1..($A.Count - 1)]) 2>&1 | ForEach-Object { "$_" })
        $rc = $LASTEXITCODE
    } finally {
        foreach ($k in @($Env.Keys)) { [Environment]::SetEnvironmentVariable($k, $prev[$k]) }
    }
    @{ rc = $rc; lines = $o; text = ($o -join "`n") }
}

$script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('bgdrill-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($script:root)

function Result-Line {
    # 末行永远如实打：skip 计数与两条计数一起打，读 CI 日志的人不用猜
    Write-Host ("DRILL-E2E-FAIL count=" + $script:fail)
    if ($script:fail -eq 0) {
        Write-Host ("DRILL-E2E-OK skipped=" + $script:skipped.Count + " ok=" + $script:ok)
        foreach ($s in $script:skipped) { Write-Host "  skipped: $s" }
    }
    if ($env:BGDRILL_KEEP -ne '1') {
        Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit ([int]($script:fail -gt 0))
}

# ---------- 被测面与被测依赖 ----------
$semPs = Join-Path $Repo 'semantic/semantic.ps1'
$backupPs = Join-Path $Repo 'backup.ps1'
Chk 'semantic.ps1 在仓库里' (Test-Path -LiteralPath $semPs -PathType Leaf)
Chk 'backup.ps1 在仓库里' (Test-Path -LiteralPath $backupPs -PathType Leaf)
if ((-not (Test-Path -LiteralPath $semPs -PathType Leaf)) -or
    (-not (Test-Path -LiteralPath $backupPs -PathType Leaf))) {
    Write-Host 'DRILL-E2E-FAIL count=1 (no semantic.ps1/backup.ps1)'; exit 1
}
. $semPs

# 语法先过一遍：这份文件的断言全在函数体里，函数没解析出来时每条断言都会「FAIL」得没有信息量
$parseErr = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($semPs, [ref]$null, [ref]$parseErr)
Chk 'semantic.ps1 解析无语法错' (@($parseErr).Count -eq 0) ((@($parseErr) | ForEach-Object { $_.Message }) -join ' | ')

$resticCmd = Get-Command restic -ErrorAction SilentlyContinue
$ageCmd = Get-Command age -ErrorAction SilentlyContinue
$keygenCmd = Get-Command age-keygen -ErrorAction SilentlyContinue
$script:restic = if ($resticCmd) { $resticCmd.Source } else { '' }
$script:age = if ($ageCmd) { $ageCmd.Source } else { '' }
$script:keygen = if ($keygenCmd) { $keygenCmd.Source } else { '' }
$py = (Get-Command python3 -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command python -ErrorAction SilentlyContinue).Source }
$bgPy = Join-Path $Repo 'semantic/bg_semantic.py'
$script:bgReady = [bool]($py -and (Test-Path -LiteralPath $bgPy -PathType Leaf))
Write-Host ("# host PS " + [string]$PSVersionTable.PSVersion + " isWin=" + $script:isWin +
    " restic=" + [bool]$script:restic + " age=" + [bool]$script:age +
    " age-keygen=" + [bool]$script:keygen + " bg=" + [bool]$script:bgReady)

$script:haveReal = [bool]($script:restic -and $script:age -and $script:keygen -and $script:bgReady)
$script:pw = 'ci-drill-' + [guid]::NewGuid().ToString('N').Substring(0, 16)

# 宿主环境：Windows 上这些本来就有，容器（Linux）里一个都没设——不补就是 Join-Path 绑 null 崩。
$envDir = New-Dir 'appdata'
$localDir = New-Dir 'localappdata'
$tmpDir = New-Dir 'tmp'
$env:APPDATA = $envDir
$env:LOCALAPPDATA = $localDir
$env:TEMP = $tmpDir
$env:BACKUP_LOG = Join-Path $script:root 'backup.log'
Set-Content -LiteralPath $env:BACKUP_LOG -Value '' -Encoding utf8

# bg 入口：Windows 走生产那条回退（$PSScriptRoot\bg.pyz + python），Linux 必须显式给 BG——
# semantic.ps1 里那条回退拼的是反斜杠路径，posix 上永远不存在（同 AGENTS「别拿本机行为当保证」）
if (-not $script:isWin) {
    $wrap = Join-Path $script:root 'bgw'
    [void](Write-U8 $wrap ('#!/bin/sh' + "`n" + 'exec ' + $py + ' "' + $bgPy + '" "$@"' + "`n"))
    [void](Run-Native @('chmod', '700', $wrap))
    $env:BG = $wrap
}

function Age-KeyPaths {
    # identity.txt / recipients.txt 落在 semantic.ps1 自己算出来的那个位置（同一条 Join-Path 表达式，
    # 不在夹具里另拼一遍——拼错一次的后果是「密钥目录不存在」被读成「演练没跑」）
    $ident = Join-Path $env:APPDATA 'PartiverseBackup\age\identity.txt'
    $rec = Join-Path $env:APPDATA 'PartiverseBackup\age\recipients.txt'
    $d = Split-Path -Parent $rec
    [void][System.IO.Directory]::CreateDirectory($d)
    [void](Run-Native @($script:keygen, '-o', $ident))
    # 公钥来自 age-keygen -y：这一版 age **没有** -Y（`flag provided but not defined: -Y` 实测），
    # 而 init-keys.ps1 用的就是同一条 age-keygen -y。它把公钥写在 **stderr**，Run-Native 的
    # 2>&1 已合流，所以按行挑出 `^age1` 那一条，而不是整段 text 当公钥用。
    $pub = Run-Native @($script:keygen, '-y', $ident)
    $publine = @( @($pub.lines) | Where-Object { $_ -match '^age1' } )
    if ($pub.rc -ne 0 -or $publine.Count -eq 0) {
        Chk '夹具：age 主身份公钥取得' $false "rc=$($pub.rc) $($pub.text)"
        # 密钥这一步崩了就不许往下跑：后面每一条断言都会红，50 条红里没有一条是结论。
        # 走 Result-Line 如实报 1 红——区别于「跑过了但 0 条」。
        Result-Line
    }
    [void](Write-U8 $rec (@($publine)[0].Trim() + "`n"))
    # 主身份文件按 fixture 的临时目录处理，不给额外权限（容器里没有 NTFS ACL 可言）
    @{ ident = $ident; rec = $rec }
}
function Get-LatestSnap([string]$RepoPath) {
    $r = Run-Native @($script:restic, '-r', $RepoPath, 'snapshots', '--json')
    if ($r.rc -ne 0) { return '' }
    $s = @($r.text | ConvertFrom-Json)
    if ($s.Count -eq 0) { return '' }
    "$(@($s | Sort-Object time)[-1].id)"
}
function New-DrillItems([hashtable]$Repos) {
    # 与 Invoke-SemanticLayer 里同一份形状：对象而不是 bash 那种 cls:repo:arc 串（盘符里有冒号）
    $out = @()
    foreach ($cls in @($Repos.Keys)) {
        $id = Get-LatestSnap $Repos[$cls]
        if ($id) { $out += @{ cls = $cls; repo = $Repos[$cls]; snap = $id } }
    }
    @($out)
}

if (-not $script:haveReal) {
    Skip '场景1-6（需要真 restic + 真 age + python3(bg)）' 'deps missing'
} else {
    # ---------- 夹具：三个类别各存自己的子树，路径互不重叠（AGENTS 的夹具规矩）----------
    $srcDocs = New-Dir 'src-docs'; $srcPics = New-Dir 'src-pics'; $srcConf = New-Dir 'src-conf'
    Write-U8 (Join-Path $srcDocs 'note.txt') "note v1 content`n"
    Write-U8 (Join-Path $srcDocs 'deep.txt') "another payload here, longer than the other one`n"
    Write-U8 (Join-Path $srcPics 'pic.dat') ("pic" + ('x' * 40) + "`n")
    Write-U8 (Join-Path $srcConf 'app.conf') "conf payload`n"
    # 同尺寸不同内容的一对：只比大小时这条永远 PASS，是场景2 要抓的那一类
    Write-U8 (Join-Path $srcConf 'same.txt') ("A" * 24 + "`n")
    Write-U8 (Join-Path $srcPics 'same.txt') ("B" * 24 + "`n")

    $base = New-Dir 'base'
    $repos = @{ files = (Join-Path $base 'restic-files');
                config = (Join-Path $base 'restic-config');
                system = (Join-Path $base 'restic-system') }
    $srcOf = @{ files = $srcDocs; config = $srcConf; system = $srcPics }
    $env:RESTIC_PASSWORD = $script:pw
    $initAll = $true
    foreach ($cls in @($repos.Keys)) {
        $i = Run-Native @($script:restic, '-r', $repos[$cls], 'init')
        if ($i.rc -ne 0) { $initAll = $false }
        $b = Run-Native @($script:restic, '-r', $repos[$cls], 'backup', $srcOf[$cls])
        if ($b.rc -ne 0) { $initAll = $false; Write-Host "seed-fail ${cls}: $($b.text)" }
    }
    Chk '夹具：三类仓库各 init + backup 成功' $initAll

    $keys = Age-KeyPaths
    $done = @($repos.Keys | Sort-Object | ForEach-Object { @{ cls = $_; repo = $repos[$_] } })

    # ---------- 场景1：全链路真跑一次语义层（密封 + 演练都在里面）----------
    $env:SEM_DRILL = '1'; $env:SEM_DRILL_COUNT = '99'
    $env:SEM_TIMELINE_KEEP = '14'
    Remove-Item -LiteralPath $env:BACKUP_LOG -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $env:BACKUP_LOG -Value '' -Encoding utf8
    Invoke-SemanticLayer -Done $done -BackupBase $base -DeviceId 'ci-drill-host' `
        -TimeIso (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')

    $stage = Join-Path $base 'timeline'
    $rtPath = Join-Path $stage 'rescue-test.txt'
    $manifests = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Filter 'MANIFEST.txt' -ErrorAction SilentlyContinue)
    Chk '场景1 时间轴快照目录已生成' (@($manifests).Count -ge 1) "count=$(@($manifests).Count)"
    $snapDir = if (@($manifests).Count -ge 1) { $manifests[0].DirectoryName } else { $stage }
    Chk '场景1 manifest.json.enc 已密封' (Test-Path -LiteralPath (Join-Path $snapDir 'manifest.json.enc') -PathType Leaf)
    Chk '场景1 rescue-test.txt 落在时间轴根' (Test-Path -LiteralPath $rtPath -PathType Leaf)

    $script:drillItems = New-DrillItems $repos
    Chk '场景1 演练登记表覆盖三个类别' (@($script:drillItems).Count -eq 3) "items=$(@($script:drillItems).Count)"

    if (Test-Path -LiteralPath $rtPath -PathType Leaf) {
        $rep = Read-U8 $rtPath
        $resLine = @($rep | Where-Object { $_ -match '^RESULT: ' })
        Chk '场景1 结论行恰好一行' (@($resLine).Count -eq 1) "count=$(@($resLine).Count)"
        $m = if (@($resLine).Count -eq 1) { [regex]::Match($resLine[0], '^RESULT: (\d+) PASS / (\d+) FAIL（抽样 (\d+)；内容哈希 (\d+)，仅比大小 (\d+)）$') } else { [regex]::Match('', '') }
        Chk '场景1 结论行五个计数都解析得出' $m.Success ($resLine -join ' | ')
        if ($m.Success) {
            $p = [int]$m.Groups[1].Value; $f = [int]$m.Groups[2].Value
            $n = [int]$m.Groups[3].Value; $h = [int]$m.Groups[4].Value; $sz = [int]$m.Groups[5].Value
            Chk '场景1 无失败项' ($f -eq 0) "PASS=$p FAIL=$f"
            Chk '场景1 抽样数 = 通过 + 失败' ($n -eq ($p + $f)) "n=$n p+f=$($p + $f)"
            Chk '场景1 抽样拉满（三个类别都抽到）' ($n -ge 3) "n=$n"
            Chk '场景1 内容哈希这一维真的生效' ($h -ge 1) "hashed=$h"
            Chk '场景1 记了哈希就没有一条只比大小' ($sz -eq 0) "sizeOnly=$sz hashed=$h"
            Chk '场景1 哈希计数与 PASS 行标注自洽' `
                ($h -eq @($rep | Where-Object { $_ -match '^PASS ' -and $_.Contains('内容哈希一致') }).Count) "h=$h"
        }
        foreach ($cls in @('files', 'config', 'system')) {
            Chk "场景1 ${cls} 类有自己的 PASS 行（跨类别错配在这里露）" `
                (@($rep | Where-Object { $_ -match ('^PASS \[' + $cls + '\]') }).Count -ge 1)
        }
        Chk '场景1 没有「本轮没有该类别」这种行' `
            (-not (@($rep | Where-Object { $_ -match '无从取回' }).Count -gt 0))
    }
    $logText = if (Test-Path -LiteralPath $env:BACKUP_LOG -PathType Leaf) {
        (Read-U8 $env:BACKUP_LOG) -join "`n" } else { '' }
    $hm = [regex]::Match($logText, '\[manifest\] 演练样本内容哈希：(\d+)/(\d+)')
    Chk '场景1 现场信号那行真的进了备份日志' $hm.Success
    if ($hm.Success) {
        Chk '场景1 记哈希的分母 > 0（0/N＝这层证据整段退化）' ([int]$hm.Groups[2].Value -gt 0) $hm.Value
        Chk '场景1 记哈希的分子 > 0' ([int]$hm.Groups[1].Value -gt 0) $hm.Value
    }

    # ---------- 场景2：改掉一个已记哈希 → 必须当场露（同尺寸不同内容那一类）----------
    $plain = Join-Path (New-Dir 'unseal') 'manifest.json'
    $encPath = Join-Path $snapDir 'manifest.json.enc'
    $u = Run-Native @($script:age, '-d', '-i', $keys.ident, '-o', $plain, $encPath)
    Chk '场景2 密封件用主身份解得开' ($u.rc -eq 0 -and (Test-Path -LiteralPath $plain -PathType Leaf)) $u.text
    # 非空单独一条：密封件为空时 `Get-Content -Raw` 出来是 null，绑不进 ConvertFrom-Json——
    # 那是**终止性异常**，整份夹具在那一行就没了，后面九段一条都不跑（10-03 首轮实测）。
    # 守卫自己不许把「生产坏了」升级成「守卫崩了」。
    $plainTxt = Get-Content -LiteralPath $plain -Raw -ErrorAction SilentlyContinue
    Chk '场景2 解封出的清单非空' ($plainTxt -and $plainTxt.Trim().Length -gt 0) `
        "len=$(if ($plainTxt) { $plainTxt.Length } else { 'null' })"
    if ($u.rc -eq 0 -and $plainTxt) {
        $doc = ConvertFrom-Json $plainTxt
        # 只改**演练会抽中的那一条**：随便改一个非样本条目的哈希，drill 永远看不到。
        # 抽样在这里是拉满的（SEM_DRILL_COUNT=99），所以任何带哈希的条目都必然被抽中。
        $tEntry = $null; $tCls = ''
        foreach ($prop in @($doc.classes.PSObject.Properties)) {
            foreach ($e in @($prop.Value.entries)) {
                if ($e.PSObject.Properties['sha256'] -and "$($e.sha256)" -match '^[0-9a-f]{64}$') {
                    $tEntry = $e; $tCls = $prop.Name; break
                }
            }
            if ($tEntry) { break }
        }
        Chk '场景2 清单里有带哈希的条目可改' ($null -ne $tEntry) "cls=$tCls"
        if ($tEntry) {
            $tamperMark = 'f' * 64
            $origSha = "$($tEntry.sha256)"
            $tLabel = if ($tEntry.PSObject.Properties['raw']) { "$($tEntry.raw)" } else { "$($tEntry.path)" }
            $tEntry.sha256 = $tamperMark
            $newDoc = ConvertTo-Json $doc -Depth 12
            Chk '场景2 篡改真的落上（回读比对）' ($newDoc.Contains($tamperMark) -and -not $newDoc.Contains($origSha))
            Write-U8 $plain $newDoc
            $s2 = Run-Native @($script:age, '-R', $keys.rec, '-o', $encPath, $plain)
            Chk '场景2 重新密封成功' ($s2.rc -eq 0) $s2.text
            $env:SEM_DRILL_FORCE = '1'
            $d2 = Invoke-Drill -Stage $stage -SnapshotDir $snapDir -Items $script:drillItems `
                -AgeBin $script:age -Identity $keys.ident -ResticBin $script:restic
            Remove-Item env:SEM_DRILL_FORCE -ErrorAction SilentlyContinue
            Chk '场景2 篡改后仍算「真跑了」(Code=0)' ($d2.Code -eq 0) "code=$($d2.Code) note=$($d2.Note)"
            Chk '场景2 判定为失败（Failed 不靠 Fail 计数）' ($d2.Failed -eq $true)
            Chk '场景2 恰好 1 条 FAIL' ($d2.Fail -eq 1) "fail=$($d2.Fail)"
            Chk '场景2 通过数 = 抽样 - 1' ($d2.Pass -eq ($d2.Samples - 1)) "pass=$($d2.Pass) n=$($d2.Samples)"
            if (Test-Path -LiteralPath $rtPath -PathType Leaf) {
                $rep2 = Read-U8 $rtPath
                $failLines = @($rep2 | Where-Object { $_ -match '^FAIL ' })
                # 子串判定用 .Contains() 方法，不用 `-Contains` 运算符：后者的左操作数若是一个
                # **字符串**（不是集合），它做的是整项相等比较，永远为假——10-03 首轮三条断言
                # 就这样红在一份正确的报告上。`.Contains(` 是序号比对，路径里的 `[` 也不会被当通配。
                Chk '场景2 报错写明「大小倒是一致」' `
                    (@($failLines | Where-Object { $_.Contains('大小倒是一致') }).Count -eq 1) ($failLines -join ' | ')
                Chk '场景2 报错点名被改的那一条（证明 drill 真的消费了它）' `
                    (@($failLines | Where-Object { $_.Contains($tLabel) }).Count -eq 1) "label=$tLabel"
                Chk '场景2 报错里带着清单值与取回值' `
                    (@($failLines | Where-Object { $_.Contains($tamperMark) -and $_.Contains($origSha) }).Count -eq 1)
            }
            # 复原：把真哈希换回去，后面几段要的是干净状态
            $tEntry.sha256 = $origSha
            Write-U8 $plain (ConvertTo-Json $doc -Depth 12)
            [void](Run-Native @($script:age, '-R', $keys.rec, '-o', $encPath, $plain))
        }
    }

    # ---------- 场景3：30 天节流 ----------
    $before = (Read-U8 $rtPath) -join "`n"
    $d3 = Invoke-Drill -Stage $stage -SnapshotDir $snapDir -Items $script:drillItems `
        -AgeBin $script:age -Identity $keys.ident -ResticBin $script:restic
    Chk '场景3 刚跑过 → Code=10（节流）' ($d3.Code -eq 10) "code=$($d3.Code) note=$($d3.Note)"
    # 整段文本比，不比行数：重写一份同样行数的报告在这条上必须算「改了」
    Chk '场景3 节流时报告一个字节都没改' (((Read-U8 $rtPath) -join "`n") -eq $before)
    $env:SEM_DRILL_FORCE = '1'
    $d3f = Invoke-Drill -Stage $stage -SnapshotDir $snapDir -Items $script:drillItems `
        -AgeBin $script:age -Identity $keys.ident -ResticBin $script:restic
    Remove-Item env:SEM_DRILL_FORCE -ErrorAction SilentlyContinue
    Chk '场景3 FORCE 绕开节流' ($d3f.Code -eq 0) "code=$($d3f.Code) note=$($d3f.Note)"

    # ---------- 场景4：SEM_DRILL=0 时密封侧不记哈希、演练侧不落笔 ----------
    $rtBefore4 = (Read-U8 $rtPath) -join "`n"
    $env:SEM_DRILL = '0'
    Invoke-SemanticLayer -Done $done -BackupBase $base -DeviceId 'ci-drill-host' `
        -TimeIso ((Get-Date).AddMinutes(30) | Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    Remove-Item env:SEM_DRILL -ErrorAction SilentlyContinue
    Chk '场景4 关掉开关时演练不写报告（Code=20 那一档的不落笔）' `
        (((Read-U8 $rtPath) -join "`n") -eq $rtBefore4)
    $snap2 = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Filter 'manifest.json.enc' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    Chk '场景4 第二轮也密封出一份（开关只关哈希与演练）' (@($snap2).Count -ge 2) "enc=$(@($snap2).Count)"
    if (@($snap2).Count -ge 1) {
        $p2 = Join-Path (New-Dir 'unseal2') 'manifest.json'
        $u2 = Run-Native @($script:age, '-d', '-i', $keys.ident, '-o', $p2, $snap2[0].FullName)
        Chk '场景4 第二轮的密封件解得开' ($u2.rc -eq 0) $u2.text
        if ($u2.rc -eq 0) {
            $t2 = Get-Content -LiteralPath $p2 -Raw -ErrorAction SilentlyContinue
            # 「没有 sha256」必须建立在**清单非空**上：空文件同样没有那个键，却什么都没证
            Chk '场景4 关掉开关后清单非空且一个 sha256 都没有' `
                ($t2 -and $t2.Trim().Length -gt 0 -and -not $t2.Contains('"sha256"')) `
                "len=$(if ($t2) { $t2.Length } else { 'null' })"
        }
        Remove-Item -LiteralPath $p2 -Force -ErrorAction SilentlyContinue
    }
    # 把这份「没记哈希」的清单真喂给演练：A2b 的**退化路径**必须有现场形状——逐条写明
    # 「仅比大小：清单未记内容哈希」，而不是把 N 个 PASS 冒充成「取回内容对」。
    # 这一段的另一重身份是场景4 前半的取证面：只查清单里没 sha256，等于没证明演练会怎么处理它。
    if (@($snap2).Count -ge 1) {
        $env:SEM_DRILL_FORCE = '1'
        $d4 = Invoke-Drill -Stage $stage -SnapshotDir $snap2[0].DirectoryName `
            -Items $script:drillItems -AgeBin $script:age -Identity $keys.ident `
            -ResticBin $script:restic
        Remove-Item env:SEM_DRILL_FORCE -ErrorAction SilentlyContinue
        Chk '场景4 无哈希清单仍能真跑（Code=0）' ($d4.Code -eq 0) "code=$($d4.Code) note=$($d4.Note)"
        Chk '场景4 退化如实计数：哈希 0 条、全部退回比大小' `
            ($d4.Hashed -eq 0 -and $d4.SizeOnly -eq $d4.Samples -and $d4.Samples -ge 1) `
            "h=$($d4.Hashed) sz=$($d4.SizeOnly) n=$($d4.Samples)"
        $rep4 = Read-U8 $rtPath
        $pass4 = @($rep4 | Where-Object { $_.StartsWith('PASS ') })
        Chk '场景4 每条 PASS 都写明「仅比大小：清单未记内容哈希」' `
            ($pass4.Count -eq $d4.SizeOnly -and
             @($pass4 | Where-Object { $_.Contains('仅比大小：清单未记内容哈希') }).Count -eq $pass4.Count) `
            "pass=$($pass4.Count)"

        # 同一份无哈希清单再把**大小**改错：这一支走的是「取回失败或大小不符」，与内容哈希
        # 无关。没有这一段，「比大小」那道闸门在这份守卫里就只被「一切正常」的路径踩过。
        $p2b = Join-Path (New-Dir 'unseal2b') 'manifest.json'
        $u2b = Run-Native @($script:age, '-d', '-i', $keys.ident, '-o', $p2b, $snap2[0].FullName)
        Chk '场景4 无哈希清单第二次解封' ($u2b.rc -eq 0) $u2b.text
        if ($u2b.rc -eq 0) {
            $doc2 = ConvertFrom-Json (Get-Content -LiteralPath $p2b -Raw)
            $e2 = $null; $c2 = ''
            foreach ($prop in @($doc2.classes.PSObject.Properties)) {
                $cand = @($prop.Value.entries)
                if ($cand.Count -ge 1) { $e2 = $cand[0]; $c2 = $prop.Name; break }
            }
            Chk '场景4 无哈希清单里有条目可改大小' ($null -ne $e2) "cls=$c2"
            if ($e2) {
                $realSize = "$($e2.size)"
                $e2.size = 1234567
                $txt2 = ConvertTo-Json $doc2 -Depth 12
                # 落地校验按**回读后的值**比，不按「文本里有没有那串」：ConvertTo-Json 的分隔符
                # 与键序是宿主相关的，拿拼出来的 `"size": N,` 去 Contains 会时灵时不灵
                Chk '场景4 大小篡改真的落上（回读比对）' `
                    (@(ConvertFrom-Json $txt2).classes.$c2.entries[0].size -eq 1234567) "real=$realSize"
                [void](Write-U8 $p2b $txt2)
                [void](Run-Native @($script:age, '-R', $keys.rec, '-o', $snap2[0].FullName, $p2b))
                $env:SEM_DRILL_FORCE = '1'
                $d4b = Invoke-Drill -Stage $stage -SnapshotDir $snap2[0].DirectoryName `
                    -Items $script:drillItems -AgeBin $script:age -Identity $keys.ident `
                    -ResticBin $script:restic
                Remove-Item env:SEM_DRILL_FORCE -ErrorAction SilentlyContinue
                Chk '场景4 尺寸不符当场露：1 条 FAIL' ($d4b.Fail -eq 1 -and $d4b.Failed) `
                    "fail=$($d4b.Fail) failed=$($d4b.Failed)"
                Chk '场景4 通过数 = 抽样 - 1（只错那一条）' `
                    ($d4b.Pass -eq ($d4b.Samples - 1)) "pass=$($d4b.Pass) n=$($d4b.Samples)"
                $rep4b = Read-U8 $rtPath
                $flines = @($rep4b | Where-Object { $_.StartsWith('FAIL ') })
                Chk '场景4 报错写明「大小不符」并带上清单值与取回值' `
                    (@($flines | Where-Object { $_.Contains('大小不符') -and $_.Contains('1234567') }).Count -eq 1) `
                    ($flines -join ' | ')
                Chk '场景4 这一条不提内容哈希（无哈希清单本来就没有这层证据）' `
                    (@($flines | Where-Object { $_.Contains('内容哈希') }).Count -eq 0)
                # 复原：改坏过的 snap2 密封件会让「场景5 缺料」那几段的基线变成脏状态
                $e2.size = [long]$realSize
                [void](Write-U8 $p2b (ConvertTo-Json $doc2 -Depth 12))
                [void](Run-Native @($script:age, '-R', $keys.rec, '-o', $snap2[0].FullName, $p2b))
            }
            Remove-Item -LiteralPath $p2b -Force -ErrorAction SilentlyContinue
        }
    }
    # 抽不到条目时必须判**失败**，不许写成 bash 旧口径那句「RESULT: 0 PASS / 0 FAIL」蒙过去
    $emptySnap = New-Dir 'empty-snap'
    $emptyPlain = Join-Path $emptySnap 'manifest.json'
    [void](Write-U8 $emptyPlain '{"format":"backguard/manifest/1","classes":{}}')
    [void](Run-Native @($script:age, '-R', $keys.rec, '-o',
        (Join-Path $emptySnap 'manifest.json.enc'), $emptyPlain))
    Remove-Item -LiteralPath $emptyPlain -Force -ErrorAction SilentlyContinue
    $env:SEM_DRILL_FORCE = '1'
    $d4c = Invoke-Drill -Stage $stage -SnapshotDir $emptySnap -Items $script:drillItems `
        -AgeBin $script:age -Identity $keys.ident -ResticBin $script:restic
    Remove-Item env:SEM_DRILL_FORCE -ErrorAction SilentlyContinue
    Chk '场景4 空清单仍算真跑了（Code=0，不是缺料那一档）' ($d4c.Code -eq 0) "code=$($d4c.Code)"
    Chk '场景4 抽不到条目判失败而不是 0/0 通过' ($d4c.Failed -eq $true -and $d4c.Samples -eq 0) `
        "failed=$($d4c.Failed) samples=$($d4c.Samples)"
    Chk '场景4 空清单的报告写明原因（读的人知道是 bg 还是清单）' `
        (@(Read-U8 $rtPath | Where-Object { $_.StartsWith('RESULT: FAIL') -and $_.Contains('sample') }).Count -eq 1)
    # 记哈希那行整场只许出现一次：日志是累加的，所以判据是计数，不是「最后一行是什么」。
    $hashLines2 = @([regex]::Matches((Read-U8 $env:BACKUP_LOG) -join "`n", '\[manifest\] 演练样本内容哈希'))
    Chk '场景4 第二轮的日志里没有记哈希那行（开关真的管着密封侧）' ($hashLines2.Count -eq 1) "count=$($hashLines2.Count)"

    # ---------- 场景5：缺主身份 / 缺 age → 20 而不是「跑了 0 条」----------
    # 这一段全部带 FORCE：rescue-test.txt 是刚写过的，不绕开节流的话四种缺料全被读成 Code=10，
    # 而 10 与 20 的差别正是「调用方要不要在报告里看到这一轮」——那一层不能靠猜。
    $env:SEM_DRILL_FORCE = '1'
    $rtUntouched = ((Read-U8 $rtPath) -join "`n")
    $d5 = Invoke-Drill -Stage $stage -SnapshotDir (Join-Path $snapDir 'no-such-dir') `
        -Items $script:drillItems -AgeBin $script:age -Identity $keys.ident -ResticBin $script:restic
    Chk '场景5 快照目录没密封件 → Code=20' ($d5.Code -eq 20) "code=$($d5.Code) note=$($d5.Note)"
    $d5b = Invoke-Drill -Stage $stage -SnapshotDir $snapDir -Items $script:drillItems `
        -AgeBin $script:age -Identity (Join-Path $script:root 'no-identity.txt') -ResticBin $script:restic
    Chk '场景5 缺主身份 → Code=20' ($d5b.Code -eq 20 -and $d5b.Note -match 'missing') "code=$($d5b.Code) note=$($d5b.Note)"
    # 「没有 age」只能靠 PATH 造：传空串进函数会**触发它自己的 PATH 查找**（那是设计的兜底），
    # 传一个不存在的路径则是 CommandNotFoundException，两种都不是这一档要证的形状。
    $pathSaved = $env:PATH
    $emptyBin = New-Dir 'empty-bin'
    $env:PATH = $emptyBin
    $d5c = Invoke-Drill -Stage $stage -SnapshotDir $snapDir -Items $script:drillItems `
        -AgeBin '' -Identity $keys.ident -ResticBin $script:restic
    $env:PATH = $pathSaved
    Chk '场景5 找不到 age → Code=20' ($d5c.Code -eq 20 -and $d5c.Note -match 'missing') "code=$($d5c.Code) note=$($d5c.Note)"
    $d5d = Invoke-Drill -Stage $stage -SnapshotDir $snapDir -Items @() `
        -AgeBin $script:age -Identity $keys.ident -ResticBin $script:restic
    Chk '场景5 本轮没有归档 → Code=20' ($d5d.Code -eq 20 -and $d5d.Note -eq 'no-archive') "note=$($d5d.Note)"
    # 缺料时**不许**动报告：上面四条任何一条若把 rescue-test.txt 重写/删掉，读的人就丢了上一份取证。
    # 比的是整段文本而不是行数——同一结构重写一次也是同样的行数，只比行数等于没比。
    # 基线只能取 386 那一次（四步**之前**）；在这里再读一遍等于拿四步之后的内容和它自己比，
    # 是一条恒真的死断言（10-03 复查时正是这个形状）。
    Chk '场景5 缺料四步都没改写报告' `
        ((Test-Path -LiteralPath $rtPath -PathType Leaf) -and
         (((Read-U8 $rtPath) -join "`n") -eq $rtUntouched))
    Remove-Item env:SEM_DRILL_FORCE -ErrorAction SilentlyContinue

    # ---------- 场景6：只登记 files → 别的类别样本判「无从取回」而不是拿 files 硬解 ----------
    $env:SEM_DRILL_FORCE = '1'
    $filesOnly = @($script:drillItems | Where-Object { $_.cls -eq 'files' })
    $d6 = Invoke-Drill -Stage $stage -SnapshotDir $snapDir -Items $filesOnly `
        -AgeBin $script:age -Identity $keys.ident -ResticBin $script:restic
    Remove-Item env:SEM_DRILL_FORCE -ErrorAction SilentlyContinue
    Chk '场景6 缺类别时真跑了（Code=0）' ($d6.Code -eq 0) "code=$($d6.Code)"
    Chk '场景6 有失败项且判定为失败' ($d6.Fail -ge 1 -and $d6.Failed) "fail=$($d6.Fail)"
    $rep6 = Read-U8 $rtPath
    Chk '场景6 失败行写明「无从取回」' (@($rep6 | Where-Object { $_ -match '^FAIL ' -and $_.Contains('无从取回') }).Count -ge 1)
    Chk '场景6 缺的类别不止 config 一种时也各自成行' `
        (@($rep6 | Where-Object { $_ -match '^FAIL \[(config|system)\]' }).Count -ge 1)

    # ---------- 场景8：清扫（明文 manifest.json 与口令值）----------
    $plainLeft = @(Get-ChildItem -LiteralPath $script:root -Recurse -File -Filter 'manifest.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'unseal' })
    Chk '场景8 产物区没留明文 manifest.json（只有夹具自己解封的两份例外，且已删）' `
        (@($plainLeft).Count -eq 0) ($plainLeft | ForEach-Object { $_.FullName })
    $allTxt = @(Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.txt', '.md', '.json', '.enc', '.log') })
    $leak = @()
    foreach ($t in $allTxt) {
        if ($t.Name -eq 'manifest.json.enc') { continue }
        $c = try { [System.IO.File]::ReadAllText($t.FullName) } catch { '' }
        if ($c -and $c.Contains($script:pw)) { $leak += $t.Name }
    }
    Chk '场景8 restic 口令没落进任何产物/日志' (@($leak).Count -eq 0) ($leak -join ',')
    $rtAll = (Read-U8 $rtPath) -join "`n"
    Chk '场景8 rescue-test.txt 里没有口令' (-not $rtAll.Contains($script:pw))
    Remove-Item -LiteralPath $plain -Force -ErrorAction SilentlyContinue
}

# ---------- 场景7：结论判定本身的死断言防线（不需要真引擎，恒跑）----------
$caseDir = New-Dir 'cases'
function Case([string]$Name, [string[]]$Lines, [bool]$Want) {
    $p = Join-Path $caseDir ($Name -replace '[^A-Za-z0-9]', '')
    [System.IO.File]::WriteAllLines($p, [string[]]$Lines)
    Chk ("场景7 " + $Name) ((Test-DrillHasFailure -ReportPath $p) -eq $Want) "want=$Want"
}
Case 'a-只有汇总行0失败' @('RESULT: 3 PASS / 0 FAIL（抽样 3；内容哈希 3，仅比大小 0）') $false
Case 'b-汇总行含字面0FAIL且逐条失败' @('FAIL [files] a.txt（取回失败）', 'RESULT: 2 PASS / 1 FAIL（抽样 3）') $true
Case 'c-结论行缺失' @('# 恢复演练 rescue-test', 'PASS [files] a.txt') $true
Case 'd-结论行两行' @('RESULT: 1 PASS / 0 FAIL', 'RESULT: 2 PASS / 0 FAIL') $true
Case 'e-结论行不可解析' @('RESULT: 三 PASS') $true
Case 'f-全通过' @('PASS [files] a.txt (12 B, 内容哈希一致)', 'RESULT: 1 PASS / 0 FAIL（抽样 1；内容哈希 1，仅比大小 0）') $false

# ---------- 场景9：开关与默认值（与 bash 逐字同名的三个开关）----------
$envSaved = [Environment]::GetEnvironmentVariable('SEM_DRILL')
[Environment]::SetEnvironmentVariable('SEM_DRILL', $null)
Chk '场景9 SEM_DRILL 未设 → 默认开（与 bash ${SEM_DRILL:-1} 同）' ((Get-DrillSwitch) -eq '1') "got=$(Get-DrillSwitch)"
$env:SEM_DRILL = '0'
Chk '场景9 SEM_DRILL=0 → 关' ((Get-DrillSwitch) -eq '0')
$env:SEM_DRILL = 'yes'
Chk '场景9 非 1 的值一律当关' ((Get-DrillSwitch) -eq 'yes')
$env:SEM_DRILL_COUNT = 'abc'
Chk '场景9 非数字 count 回落默认 5' ((Get-DrillCount) -eq '5') "got=$(Get-DrillCount)"
$env:SEM_DRILL_COUNT = '12'
Chk '场景9 数字 count 照收' ((Get-DrillCount) -eq '12')
Remove-Item env:SEM_DRILL, env:SEM_DRILL_COUNT -ErrorAction SilentlyContinue
if ($envSaved) { $env:SEM_DRILL = $envSaved }
$mbSaved = [Environment]::GetEnvironmentVariable('SEM_DRILL_HASH_MAX_BYTES')
[Environment]::SetEnvironmentVariable('SEM_DRILL_HASH_MAX_BYTES', $null)
Chk '场景9 哈希尺寸上限默认 8388608（与 bash 同）' ((Get-DrillHashMaxBytes) -eq '8388608')
if ($mbSaved) { $env:SEM_DRILL_HASH_MAX_BYTES = $mbSaved }

# ---------- 场景10：红线 §1.1 推送侧——rescue-test.txt 上不了云 ----------
$rcloneCmd = Get-Command rclone -ErrorAction SilentlyContinue
if (-not $rcloneCmd) {
    Skip '场景10（需要真 rclone）' 'rclone missing'
} else {
    $srcTxt = [System.IO.File]::ReadAllText($backupPs)
    $mm = [regex]::Match($srcTxt, "(?ms)^# BEGIN-PUSH[^\r\n]*\r?\n(.*?)^# END-PUSH")
    if (-not $mm.Success) {
        Chk 'backup.ps1 的 Push-TreeToCloud 有成对哨兵' $false '生产改了标记，这份守卫必须先炸'
    } else {
        # Format-CloudDest 在 BEGIN-VERIFY 段里；这里给一个「目标=本地目录」的替身，
        # 被测面是 --exclude 有没有真的传到 rclone 并改变落盘形状，不是网盘路径归一
        function Format-CloudDest { param([string]$Target, [string]$SystemId, [string]$Sub) "$Target/$Sub" }
        Invoke-Expression $mm.Groups[1].Value
        $tree = New-Dir 'cloud-src'
        $snapLeaf = Join-Path $tree '2026-10-03/0234-night'
        [void][System.IO.Directory]::CreateDirectory($snapLeaf)
        Write-U8 (Join-Path $snapLeaf 'MANIFEST.txt') "MANIFEST`n"
        Write-U8 (Join-Path $tree 'rescue-test.txt') "FAIL [files] C:/Users/someone/secret/note.txt`n"
        Write-U8 (Join-Path $tree 'profile.json') "{}"
        $cloud = New-Dir 'cloud-dest'
        $rl = Join-Path $script:root 'rclone.log'

        $r1 = Push-TreeToCloud -SrcRoot $tree -Targets @($cloud) -Sub 'timeline' `
            -RcloneLog $rl -ExcludeNames @('rescue-test.txt')
        Chk '场景10 带 exclude 的推送返回单个整数 0' ($r1 -is [int] -and $r1 -eq 0) "got=[$r1] type=$($r1.GetType().Name)"
        $got1 = @(Get-ChildItem -LiteralPath (Join-Path $cloud 'timeline') -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name })
        Chk '场景10 时间轴明文照常上云' ($got1 -Contains 'MANIFEST.txt') ($got1 -join ',')
        Chk '场景10 rescue-test.txt 没上云（红线 §1.1）' (-not ($got1 -Contains 'rescue-test.txt')) ($got1 -join ',')

        # 对照组：同一个函数、不带那个参数，必须真的把它推上去。没有这一刀，上面那条
        # 「没上云」可能只是因为路径写错、压根没复制过任何文件
        $cloud2 = New-Dir 'cloud-dest2'
        [void](Push-TreeToCloud -SrcRoot $tree -Targets @($cloud2) -Sub 'timeline' -RcloneLog $rl)
        $got2 = @(Get-ChildItem -LiteralPath (Join-Path $cloud2 'timeline') -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name })
        Chk '场景10 对照组（不带 exclude）真的会推上去' ($got2 -Contains 'rescue-test.txt') ($got2 -join ',')

        # 调用点接线：backup.ps1 推时间轴那一句必须真的带上这个名字
        $call = [regex]::Match($srcTxt, 'Push-TreeToCloud[^\r\n]*timeline[^\r\n]*')
        $around = $srcTxt.Substring([Math]::Max(0, $call.Index), [Math]::Min(900, $srcTxt.Length - [Math]::Max(0, $call.Index)))
        Chk '场景10 时间轴调用点登记了排除名' ($around -match 'ExcludeNames')
        Chk '场景10 排除名逐字是 rescue-test.txt' ($around -match 'rescue-test\.txt')
    }
}

# ---------- 场景11：--include 的形状（钉 argv，不靠真引擎）----------
# 为什么这一条不能用真 restic 证：`_norm_path` 在 posix 上只剥掉前导斜杠（盘符段那一支根本不触发），
# 所以「把斜杠加回去」在容器里恒等于原形状——10-03 实测：相对备份的 `src-files/note.txt` 与
# `/src-files/note.txt` 两种 --include 都取回得到，变异「强制前导斜杠」因此在容器里咬不住。
# 真宿主不一样：restic 在 Windows 把 `C:/…` 存成快照根下的第一层，而 bg 把盘符段剥掉了，清单里的
# path 是**真归档路径的后缀**——这时给 --include 加前导斜杠等于把它锚到快照根，第一层就对不上
# （`Users` 对 `C:`），restic 一个文件都不解而**退出码仍是 0**：「取回失败」会伪装成「本轮没有样本」。
# 所以这里用桩记录真实 argv，两档宿主同一条判据；真引擎那一段（场景1）在 windows job 上照跑。
$incSample = 'C:\Users\partiverse\bgsrc\report.txt'
$incWant = 'C:/Users/partiverse/bgsrc/report.txt'
$stubDir = New-Dir 'argv-stub'
$stubLog = Join-Path $stubDir 'argv.txt'
[void](Write-U8 $stubLog '')
$stubExt = if ($script:isWin) { 'cmd' } else { 'sh' }
$stubPath = Join-Path $stubDir ('restic-stub.' + $stubExt)
if ($script:isWin) {
    # `%*` 原样吐出全部入参（项间单空格），所以夹具给的样本路径故意不含空格：含空格时 cmd 自己
    # 就把边界丢了，那是桩的限制不是被测面的限制，别拿它做判据
    Write-U8 $stubPath "@echo off`r`necho %*>>`"%STUB_LOG%`"`r`n"
} else {
    Write-U8 $stubPath "#!/bin/sh`nprintf `"%s\n`" `"`$*`" >> `"`$STUB_LOG`"`nexit 0`n"
    try { chmod 755 $stubPath } catch { }
}
# 桩把 argv 写到哪，由进程环境变量告诉它（Restore-DrillFile 不接受自定义 env，子进程继承本进程）
$env:STUB_LOG = $stubLog
try {
    [void](Restore-DrillFile -Bin $stubPath -Repo 'C:\bg\restic-files' -Snap 'c0ffee4' `
        -Include $incSample -Target $stubDir)
} finally {
    Remove-Item env:STUB_LOG -ErrorAction SilentlyContinue
}
$toks = @(((Read-U8 $stubLog) -join ' ') -split '\s+' | Where-Object { $_ })
$iIdx = [Array]::IndexOf($toks, '--include')
Chk '场景11 桩真的收到了 --include' ($iIdx -ge 0) "toks=$($toks -join '|')"
Chk '场景11 restore 与快照 id 各占一个 argv 项（没被拼成一串）' `
    (($toks -contains 'restore') -and ($toks -contains 'c0ffee4')) ($toks -join '|')
$gotInc = if ($iIdx -ge 0 -and ($iIdx + 1) -lt $toks.Count) { $toks[$iIdx + 1] } else { '' }
Chk '场景11 include 只把反斜杠归成正斜杠' ($gotInc -eq $incWant) "got=$gotInc"
Chk '场景11 不给 include 加强制前导斜杠（加了就锚到快照根，取回 0 文件却退 0）' `
    ($gotInc.Length -gt 0 -and -not $gotInc.StartsWith('/')) "got=$gotInc"

Result-Line
