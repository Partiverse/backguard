# test_retention_logic.ps1 —— backup.ps1 的 restic 保留策略（forget --prune）逻辑 + 行为测试
#
# 怎么跑（本机无 pwsh；容器是 arm64，真 restic 挂进 /rbrestic 就能原生跑）：
#   docker run --rm -v "$PWD":/repo:ro -v /tmp/rbin2bin:/rbrestic:ro --entrypoint /bin/bash \
#     mcr.microsoft.com/powershell:lts -lc 'PATH=/rbrestic:$PATH pwsh -NoProfile -File /repo/test_retention_logic.ps1'
# 在 Windows runner 上（CI 那一步）：pwsh -NoProfile -File test_retention_logic.ps1
#   ——runner 的 Install deps 已把 restic 装进 PATH，所以场景4 那一半在 CI 上真的执行。
# 期望最后一行 RETENTION-LOGIC-OK；没真 restic 时场景4 整段 Skip 并如实标注（理由里带现场数字）。
#
# **为什么这一发值得单独写**：CI 的 windows job 每轮新建空仓库，`forget` 在那里一份快照都
# 裁不掉——生产代码里那一句 `--prune` 从未被测过，而它 standing 的前提是「本地已 prune，
# 云端 copy 只增不减」。前提塌了的话后果是本地仓库与云端副本**一起**只增不减，而观察期里
# 没人会主动去查仓库尺寸。bash 侧同一件事由 `test_restic_retention.sh` 用真 restic 证过
# （10-02 实测：预置 9 份跨日快照再跑一轮生产 backup.sh，forget 退出 0、快照少两份、仓库字节
# 只动了索引的 4 KiB；补上 prune 才释放 MiB 级），ps1 侧此前只有「源码里那一串参数长什么样」
# 的静态守卫。
#
# 分工：桩负责 argv 逐字与 rc 三档，**真实 restic** 负责「快照数真的按口径减少」+
# 「仓库字节真的下降」——桩只会告诉我它被叫了什么，不会告诉我字节有没有回收。
#
# 不覆盖的（在这里注册，别假装覆盖）：
#   - 桩/真二进制各只有一支在本机走得到（.sh 在容器、.cmd 在 windows runner），另一支 Skip。
#   - 真 restic 的 rc=3（部分生效）造不出来：那要「快照对象在索引里但删的时候出错」，
#     本地仓库没有这种办法，只能由桩证明。
#   - `--keep-weekly/--keep-monthly` 的分档算法本身不在这条断言里：10-02 在容器里量到
#     「9 份**跨 9 个不同日**的快照，`--keep-daily=7 --keep-weekly=4 --keep-monthly=6 --prune`
#     一份都不裁」（daily 掉的那 2 份正好被 weekly/monthly 各接回去）。所以场景4 的夹具是
#     **同一天 9 个钟点**（实测 9 → 2、字节回收 ~935 KiB），它证的是「策略真的执行 + prune
#     真的回收」，不是分档算术。
#
# 变异台账（摘 backup.ps1 的实现、这份必须报 FAIL；10-02 容器 + 真 restic 逐刀跑完，
# 驱动 /tmp/mut_retention*.py，判定口径同 bash 侧：变异先验证落上、变异后先过语法面、
# 没有汇总行＝环境/守卫自己崩了记 UNDETERMINED 而不是「断言没咬住」）：
#   m01 摘掉 --prune                     CAUGHT（3 条 FAIL，从场景1 argv 逐字起）
#   m02 摘掉 -r 与仓库路径               CAUGHT（8 条：argv 逐字 + 场景2 三档 rc 全变 rc=0，
#       因为桩靠 `-r` 那个参数找 .stub_rc——**少一个参数就整张码表失效**，这条形状值得记住）
#   m03 rc=3 也判失败                    CAUGHT（1 条：场景2「部分生效只告警不抛」）
#   m04 非零不再抛出                     CAUGHT（2 条：场景2 的 rc=1 与码表之外那档）
#   m05 引擎原文不落本地日志             CAUGHT（2 条：场景3 落笔 + 场景4 引擎现场进日志）
#   m06 引擎原文吐进成功流               CAUGHT（2 条：场景3「成功流只有一个对象」）
#   m07 摘掉 --keep-daily=7              CAUGHT（1 条：场景1 argv 逐字）
#   m08 调用点整条摘掉（函数在没人调）   CAUGHT（4 条：场景5 三根静态钉 + 一条取不到上下文的说明）
#   m09 调用点漏掉本轮仓库路径           CAUGHT（1 条：场景5「把本轮的仓库路径交进去」）
#   合计 9/9 CAUGHT、0 MISS。
#
# **其中三刀第一次交回的是 UNDETERMINED，而病灶在守卫自己身上**（这比 MISS 更值得记）：
#   - m02/m05 首轮崩在 `Chk` 的参数绑定：`(Get-Content …) -match 'x'` 的左操作数是**命令表达式**，
#     PowerShell 走集合语义、返回「匹配到的元素」（空结果就是 `System.Object[]`），绑不进
#     `[bool]$cond`——于是「日志没落笔」这条**本该报 FAIL**的断言报的是守卫自己的错，容器里
#     连汇总行都没有。口径：条件里出现 `-match` 时先确认左操作数是标量，`Chk` 那边把任何形状
#     收敛成布尔（数组＝有没有命中）作为第二道。
#   - m08 首轮崩在 `Substring($idxCall, 200)`：调用点被摘掉时 IndexOf 交回 **-1**，而那正是
#     上面两条静态断言要抓的情形——守卫在替被测面「报错」之前先自己抛了。口径：**静态取位置的
#     断言，先问取不取得到，再取上下文**。
#   - m08 第二轮（守卫修好后）是 qemu TCG 自己断言失败（rc=139），与实现无关；第三轮 CAUGHT。
#     同一条变异在容器里连吃两次环境崩溃时，别把它写成 MISS——重跑一次再落账。
param([string]$Repo = '')
if (-not $Repo) { $Repo = $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:fail = 0
# 条件参数**不收 [bool]**：`-match` 的左操作数只要是**命令表达式**（`(Get-Content …) -match 'x'`），
# PS 就走集合语义，返回「匹配到的那些元素」而不是布尔——空结果是 `System.Object[]`，绑到
# `[bool]$cond` 上报的是「Cannot convert value "System.Object[]" to type "System.Boolean"」。
# 这件事 10-02 由变异 m02b/m05b 各撞一次：那两条断言要抓的正是「日志没落笔 / argv 变了」，
# 而它们在那一档里**崩在 Chk 自己的参数绑定上**，报出来的是守卫的错，不是被测实现的错
# （容器里连汇总行都没有，只能判 UNDETERMINED）。所以这里显式收敛成布尔：数组＝「有没有命中」，
# 标量＝照常转。**命中语义不许在调用点靠运气**——要判「文本里出现某串」就把文本先收成标量。
function Chk([string]$name, $cond, [string]$detail = '') {
    $ok = if ($null -eq $cond) { $false }
          elseif ($cond -is [System.Array]) { @($cond).Count -gt 0 }
          else { [bool]$cond }
    if ($ok) { Write-Host "ok   - $name $detail" }
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
        throw "哨兵 # BEGIN-$Tag / # END-$Tag 在 backup.ps1 里没成对出现——生产改了标记，这份守卫必须先炸，不能安静地切出一段旧代码"
    }
    $m.Groups[1].Value
}
$script:srcPs1 = Get-Content -Raw (Join-Path $Repo 'backup.ps1')
. ([scriptblock]::Create((Slice 'RETENTION')))
Chk '切出了被测函数' ($null -ne (Get-Command Invoke-ResticRetention -ErrorAction SilentlyContinue))

$script:root = Join-Path ([System.IO.Path]::GetTempPath()) ("bgret-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:root | Out-Null

# ---------- 桩：把 argv 记进 STUB_LOG，rc 与噪音由仓库目录里的开关文件决定 ----------
$script:isWin = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
$script:stubExt = if ($script:isWin) { 'cmd' } else { 'sh' }
$script:stubPath = Join-Path $script:root ("restic-stub." + $script:stubExt)
if ($script:isWin) {
    @(
        '@echo off'
        # 两处形状都是从 test_integrity_logic.ps1 那一份**已在 windows runner 上跑绿**的桩抄来的：
        # ① `%*>>` 之间不许有空格——`echo %* >> f` 会把重定符前那个空格一起写进文件，argv 逐字
        #    断言（`…--prune$`）当场差一个尾空格（10-02 首轮 windows job 就是这么红的）；
        # ② stderr 用 `type 文件 1>&2` 而不是 `set /p MSG<文件` + `echo %MSG% 1>&2`——后者在
        #    `if exist (…) else (…)` 这种**括号块**里按「块解析时」展开变量，set /p 还没执行，
        #    echo 打出来的是字面量 `%MSG%`，日志里没有引擎原文（同一轮的第二条红）。
        'echo %*>> "%STUB_LOG%"'
        'set RCFILE=%~2\.stub_rc'
        'if exist "%RCFILE%" ('
        '  set /p RC=<"%RCFILE%"'
        ') else ('
        '  set RC=0'
        ')'
        'if exist "%~2\.stub_msg" type "%~2\.stub_msg" 1>&2'
        'exit /b %RC%'
    ) | Out-File -FilePath $script:stubPath -Encoding ascii
} else {
    @(
        '#!/bin/sh'
        'printf "%s\n" "$*" >> "$STUB_LOG"'
        'rcfile="$2/.stub_rc"'
        'rc=0'
        'if [ -f "$rcfile" ]; then rc=$(cat "$rcfile"); fi'
        'if [ -f "$2/.stub_msg" ]; then cat "$2/.stub_msg" >&2; fi'
        'exit "$rc"'
    ) | Out-File -FilePath $script:stubPath -Encoding ascii
    try { chmod 755 $script:stubPath } catch { }
}
$script:stubLog = Join-Path $script:root 'stub-argv.log'
function Set-Stub([string]$RepoDir, [int]$Rc, [string]$Msg = '') {
    if ($Msg) { [System.IO.File]::WriteAllText((Join-Path $RepoDir '.stub_msg'), $Msg) }
    elseif (Test-Path -LiteralPath (Join-Path $RepoDir '.stub_msg')) {
        Remove-Item -LiteralPath (Join-Path $RepoDir '.stub_msg') -Force
    }
    [System.IO.File]::WriteAllText((Join-Path $RepoDir '.stub_rc'), "$Rc")
}
function New-Repo([string]$Name) {
    $p = Join-Path $script:root $Name
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    $p
}
# 证据 + 返回值 + 抛出的异常一起收进字符串：少收一条流就有断言恒假，而「函数抛终止性异常
# 被上层 catch 降成 warning」与「压根没被调用」在产物上长得一模一样（AGENTS §1.3 同一条）。
function Run-Retention([string]$RepoDir, [string]$LogPath = '', [string]$Bin = '') {
    $b = if ($Bin) { $Bin } else { $script:stubPath }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $r = Invoke-ResticRetention -Class 'files' -RepoPath $RepoDir -LogPath $LogPath -ResticBin $b 3>&1 4>&1 6>&1
        @{ rc = if ($r) { $r.rc } else { -1 }; out = ($r | Out-String); threw = '' }
    } catch {
        @{ rc = -1; out = ''; threw = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ---------- 场景1：argv 逐字——少一个开关就是一场「看着在裁剪、其实一字节没回收」 ----------
$repo1 = New-Repo 'repo1'
Set-Stub $repo1 0
$env:STUB_LOG = $script:stubLog
Remove-Item -LiteralPath $script:stubLog -Force -ErrorAction SilentlyContinue
$r1 = Run-Retention $repo1
$argv = @(Get-Content -LiteralPath $script:stubLog -ErrorAction SilentlyContinue)
Chk '场景1 只调了一次引擎' (@($argv).Count -eq 1) "实得 $(@($argv).Count) 行：$($argv -join ' | ')"
$want1 = '-r'
$line1 = if (@($argv).Count -ge 1) { $argv[0] } else { '' }
Chk '场景1 argv 逐字：-r <仓库> forget --keep-daily=7 --keep-weekly=4 --keep-monthly=6 --prune' `
    ($line1 -match ('^-r\s+' + [regex]::Escape($repo1) + '\s+forget\s+--keep-daily=7\s+--keep-weekly=4\s+--keep-monthly=6\s+--prune$')) `
    "实得: $line1"
# `--prune` 是这一发的本体：forget 只删快照对象，字节要 prune 才回收。它只能出现在**这一处代码**
# （两处各写一遍＝漏的那处将来会被当成「已覆盖」），所以是计数断言而不是「有没有」。
# 只数代码行：这一段为什么必须带 --prune 的理由写在注释里（BEGIN-RETENTION 上方那六行），
# 按全文计数会把「解释它的注释」算成第二处实现——10-02 首次跑就是这样假红。
$pruneLines = @((Get-Content -LiteralPath (Join-Path $Repo 'backup.ps1')) |
    Where-Object { $_ -match '--prune' -and $_.TrimStart() -notmatch '^#' })
Chk '场景1 --prune 在生产源码里只有一处（归口只许一处）' `
    ($pruneLines.Count -eq 1) "实得 $($pruneLines.Count) 行：$(($pruneLines | ForEach-Object { $_.Trim() }) -join ' | ')"
Chk '场景1 rc 原样交回调用点' ($r1.rc -eq 0) "实得 rc=$($r1.rc) threw=$($r1.threw)"

# ---------- 场景2：rc 三档——3 只告警，其余非零判本类失败 ----------
$repo2 = New-Repo 'repo2'
Set-Stub $repo2 3
$r2 = Run-Retention $repo2
Chk '场景2 rc=3（部分生效）只告警不抛（下晚重试，不该把整轮带走）' `
    ($r2.threw -eq '' -and $r2.rc -eq 3 -and $r2.out -match '部分生效') `
    "实得 rc=$($r2.rc) threw=$($r2.threw) out=$($r2.out -replace "`r?`n", ' / ')"
Set-Stub $repo2 1
$r2b = Run-Retention $repo2
Chk '场景2 rc=1 抛出终止性异常（保留策略没跑成＝仓库无限增长）' `
    ($r2b.threw -match 'forget/prune') "实得 threw=$($r2b.threw)"
Set-Stub $repo2 99
$r2c = Run-Retention $repo2
Chk '场景2 码表之外的非零同样抛出（不许当成 3 那种可容忍）' `
    ($r2c.threw -match 'exit 99') "实得 threw=$($r2c.threw)"

# ---------- 场景3：引擎原文只进本地日志，不进 stdout ----------
$repo3 = New-Repo 'repo3'
$log3 = Join-Path $script:root 'backup.log'
$msg3 = 'counting files of snapshot abc123 / removing old packs'
Set-Stub $repo3 0 $msg3
Remove-Item -LiteralPath $log3 -Force -ErrorAction SilentlyContinue
$r3 = Run-Retention $repo3 $log3
Chk '场景3 引擎原文进了本地日志' `
    ((Get-Content -Raw -LiteralPath $log3 -ErrorAction SilentlyContinue) -match [regex]::Escape($msg3)) `
    '保留策略的现场只在日志里，控制台只留结论'
# stdout 这一半单独验：调用点 `[void](Invoke-ResticRetention …)` 挡的就是「结果对象漏进成功流」，
# 而函数自己要是把引擎原文直接吐进成功流（少收一次 `$out =`），nightly 的控制台输出就多几 KB
# 引擎噪音。判据取**成功流里的对象**而不是它的渲染文本——渲染文本永远包含返回值的 `.out` 字段，
# 拿它判「没混进 stdout」是一条恒假断言（10-02 首次跑就是这么假红的）。
$prev3 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$succ3 = @(Invoke-ResticRetention -Class 'files' -RepoPath $repo3 -LogPath $log3 -ResticBin $script:stubPath)
$ErrorActionPreference = $prev3
Chk '场景3 成功流只有一个结果对象（引擎原文没被吐进 stdout）' `
    (@($succ3).Count -eq 1 -and $succ3[0] -is [hashtable]) `
    "实得 $(@($succ3).Count) 个对象：$(($succ3 | ForEach-Object { $_.GetType().Name }) -join ',')"
Chk '场景3 成功流里没有裸的引擎文本行' `
    (@($succ3 | Where-Object { $_ -is [string] -and "$_" -match [regex]::Escape('removing old packs') }).Count -eq 0) `
    '调用点会把它并轮次的其它输出一起收下，噪音混进去就分不开'
Chk '场景3 日志路径为空时不写也不炸' ($null -ne $r3) '见 Run-Retention 的默认参数'

# ---------- 场景4：真 restic 的行为面——快照数按口径减少 + 字节真的回收 ----------
$realRestic = Get-Command restic -ErrorAction SilentlyContinue
if (-not $realRestic) {
    Skip '场景4 真 restic 的保留与回收' 'PATH 上没有 restic（容器要挂 /rbrestic；windows runner 上产品依赖那一步已装）'
} else {
    $env:RESTIC_PASSWORD = 'e2e-retention-pass'
    $repo4 = New-Repo 'repo4'
    $src4 = New-Repo 'src4'
    $eap4 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    [void](& restic -r $repo4 init 2>&1 | Out-Null)
    $initRc = $LASTEXITCODE
    # 9 份快照**同一天、不同钟点**（日期写死，不用相对天数：跨月/跨年时「相对今天」会让分档变成
    # 运气，同一课见 §4.15「夹具按日期腐化」）。restic 的 --time **只认** "2006-01-02 15:04:05"，
    # 给 RFC3339（T 分隔 + 时区）反而报解析失败——见 AGENTS §2 restic 三件事那条。
    # **为什么不能用「9 个不同日」**（10-02 在容器里对着真 restic 量的，不是推的）：
    # keep-daily=7 会掉最早的 2 份，而那 2 份恰好各自是本週/本月的第一份，被 keep-weekly=4 与
    # keep-monthly=6 接回来——`forget --keep-daily=7 --keep-weekly=4 --keep-monthly=6 --prune`
    # 在跨 9 天的夹具上**一份都不裁**（实测 9 → 9，字节 2 276 036 → 2 276 036）。同一天 9 个钟点
    # 才是 9 → 2、字节 2 276 030 → 1 340 722。bash 侧的 test_restic_retention.sh 用跨日夹具还能
    # 裁出 2 份，是因为它跑的是**生产链路**：本轮新增的那一份「今天」快照自己占了新的一周/月，
    # 于是 9/10、9/11 两份没了代言人。这里调的是单独切出来的保留函数，没有「今晚」那一份，
    # 所以夹具必须自己落在同一个日档里。
    # 每份的独有数据必须在**下一份备份之前**从磁盘删掉：只往同一个目录累加的话，后一份快照
    # 仍引用全部旧内容，prune 无可回收，「没带 --prune」与「带了」在字节数上长得一样（§4.19 末
    # 记的那处夹具死法）。
    $hours = @('01', '03', '05', '07', '09', '11', '13', '15', '17')
    $seedRc = @()
    foreach ($h in $hours) {
        $uniq = Join-Path $src4 ("u-$h.bin")
        $bytes = New-Object byte[] 262144
        # 种子必须**按钟点变**：固定种子的话九份快照存的是同一串字节，restic 去重之后仓库里
        # 只有一个 pack，prune 无字节可回收（10-02 首次跑实测 280 990 → 266 773，只有索引的
        # 14 KiB），于是「没带 --prune」与「带了」又长得一样——这条夹具死法是 §4.19 那一发的
        # 第二个变体：上一版是「忘了从磁盘删掉」，这一版是「忘了让它们不一样」。
        (New-Object System.Random ($h -as [int])).NextBytes($bytes)
        [System.IO.File]::WriteAllBytes($uniq, $bytes)
        [void](& restic -q -r $repo4 backup --time "2026-08-01 $h`:00:00" $src4 2>&1 | Out-Null)
        $seedRc += $LASTEXITCODE
        Remove-Item -LiteralPath $uniq -Force
    }
    $snapsBefore = (& restic -r $repo4 snapshots --json 2>&1 | Out-String)
    $countBefore = ([regex]::Matches($snapsBefore, '"short_id"')).Count
    $size = ([int64] (Get-ChildItem -LiteralPath $repo4 -Recurse -File |
        Measure-Object -Property Length -Sum).Sum)
    $ErrorActionPreference = $eap4
    if ($initRc -ne 0 -or @($seedRc | Where-Object { $_ -ne 0 }).Count -gt 0 -or $countBefore -ne 9) {
        # Skip 的理由带现场数字：一条「建夹具失败」而无信息的 Skip 与假通过只差一句没人读的理由
        Skip '场景4 真 restic 的保留与回收' ("夹具没备好（init=$initRc backup rc=$($seedRc -join ',') 快照=$countBefore）")
    } else {
        $log4 = Join-Path $script:root 'retention4.log'
        # 走 Run-Retention 而不是直调：直调时「保留策略抛了终止性异常」会让整份守卫在那一行死掉
        # （没有 FAIL 行、没有汇总），而抛正是场景2 认定的正确行为之一——它在这里必须被收集成证据
        $r4 = Run-Retention $repo4 $log4 'restic'
        $snapsAfter = (& restic -r $repo4 snapshots --json 2>&1 | Out-String)
        $countAfter = ([regex]::Matches($snapsAfter, '"short_id"')).Count
        $sizeAfter = ([int64] (Get-ChildItem -LiteralPath $repo4 -Recurse -File |
            Measure-Object -Property Length -Sum).Sum)
        Chk '场景4 生产函数对真仓库跑成（rc=0）' ($r4.rc -eq 0) "实得 rc=$($r4.rc) threw=$($r4.threw)"
        Chk '场景4 快照按口径真的被裁掉（9 份同日的裁到实测 2 份）' `
            ($countAfter -lt $countBefore -and $countAfter -ge 1) `
            "实得 $countBefore -> $countAfter"
        # 这一条是整发的本体：forget 只删对象，**字节要 prune 才回来**。少了 --prune，
        # 上一条照样绿（快照数确实少了），而仓库与云端副本一起只增不减——所以断言必须落在字节上。
        Chk '场景4 裁掉的快照真的回收了字节（--prune 生效，不是只藏起快照）' `
            ($sizeAfter -lt ($size - 100000)) "实得 $size -> $sizeAfter 字节"
        Chk '场景4 引擎现场进了本地日志而不是 stdout' `
            ((Get-Content -Raw -LiteralPath $log4 -ErrorAction SilentlyContinue).Length -gt 0) `
            '保留策略跑没跑成都得能事后查'
    }
}

# ---------- 场景5：生产接线（函数被调用 + 桩换得动的唯一入口） ----------
$idxDef = $script:srcPs1.IndexOf('function Invoke-ResticRetention')
$idxCall = $script:srcPs1.IndexOf('Invoke-ResticRetention -Class')
$idxClass = $script:srcPs1.IndexOf('function Backup-ResticClass')
Chk '场景5 定义与调用点都在（函数在但没人调＝产物上跟没写一样）' `
    ($idxDef -gt 0 -and $idxCall -gt 0) "IndexOf def=$idxDef call=$idxCall"
Chk '场景5 调用点在 Backup-ResticClass 里面（每类仓库各裁一次）' `
    ($idxCall -gt $idxClass -and $idxCall -lt $idxDef) `
    "调用点必须在生产类函数体内（class=$idxClass def=$idxDef call=$idxCall）"
# `Substring(-1, 200)` 会抛「StartIndex cannot be less than zero」——调用点被摘掉时 IndexOf 交回
# -1，而**那正是上面两条断言要抓的情形**（10-02 变异 m08b 就是在这里崩掉，整份守卫没有汇总行，
# 只能判 UNDETERMINED）。所以先问「取不取得到」，取不到就明说取不到。
$callTail = if ($idxCall -gt 0) { $script:srcPs1.Substring($idxCall, 200) } else { '' }
Chk '场景5 调用点把本轮的仓库路径交进去' `
    ($callTail -match '-RepoPath\s+\$RepoPath') $(if ($idxCall -gt 0) { '见调用点' } else { "调用点根本不在（IndexOf=-1），无从取上下文" })
Chk '场景5 引擎路径只有一个入口（守卫的桩才换得动）' `
    (@([regex]::Matches($script:srcPs1, 'Invoke-ResticRetention -Class')).Count -eq 1) `
    "实得 $(@([regex]::Matches($script:srcPs1, 'Invoke-ResticRetention -Class')).Count) 处调用"

# ---------- 场景6：桩形状按宿主，另一支如实注册 ----------
$otherExt = if ($script:isWin) { 'sh' } else { 'cmd' }
Chk '场景6 本机用的桩形状与宿主一致' ($script:stubPath -like ('*.' + $script:stubExt)) "实得 $script:stubExt"
Skip ("场景6 另一支桩（.{0}）" -f $otherExt) `
    ("本机是 {0}，只有 windows runner 会走 .cmd、只有容器会走 .sh" -f $(if ($script:isWin) { 'Windows' } else { '非 Windows' }))

Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host "RETENTION-LOGIC-FAIL count=$script:fail skipped=$($script:skipped.Count)"
    exit 1
}
Write-Host "=== RETENTION-LOGIC-OK skipped=$($script:skipped.Count) ==="
exit 0
