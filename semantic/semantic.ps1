# semantic.ps1 — 语义层生成（research/06 章 L0/L1/L2），由 backup.ps1 dot-source 后调用
# 设计红线：语义层任何失败都不得影响备份本身（调用点全部非致命）。
# 引擎：restic（Windows 侧引擎）。RESTIC_PASSWORD 由 backup.ps1 载入 secrets 时已注入进程环境。
# 兼容性：清单落盘走 [IO.File]::WriteAllLines（UTF-8 无 BOM）；bg 侧以 utf-8-sig 读取，
# 兼容 Windows PowerShell 5.1 与 pwsh 7。

# 兼容 Windows PowerShell 5.1 与 pwsh 7：只用 Skip/First（不用 6.0+ 的 -SkipLast），
# 删除一律 -LiteralPath（方括号路径不当通配符）。不写 -Culture / 不用 string + char 拼接
# 这类「5.1 下没验证过的绑定」（10-02 首轮 CI 的教训，见 AGENTS §5 ⑥）。

# 本地暂存保留最近 N 份快照（SEM_TIMELINE_KEEP，默认 14；非数字回落默认，<=0 不清理）。
# 与 semantic.sh 的 prune_local_timeline 同形，四条口径一条不落：①只认 stage 根下第 4 层
# （YYYY/MM/DD/HHMM-标签）的目录；②按相对路径排序取「除最后 N 份外」；③删除前逐个过形态
# 白名单，不匹配就告警跳过——stage 根解析错时宁可漏删不可误删；④清走后把空日期壳自深向浅收掉。
# 云端那份不动（AGENTS §1.4 只增不减）：调用点在时间轴推送之前，被裁的本来上一轮就上过云。
#
# 那行 ASCII 的窗口证据不是装饰，是本函数的**唯一现场信号**。10-02 首轮 CI 报「KEEP=1 却一份
# 都没裁」，而产物目录上四种坏法长得一模一样：语义层在 generate 之前就 return 了（根本没调用）、
# SEM_TIMELINE_KEEP 没读到（回落 14 → 5 份 <= 14 早退）、第 4 层一个都没认出来（0 份 <= 14 早退）、
# 函数内抛了终止性异常（backup.ps1 的 catch 降成 warning，结论照打 FULLY COMPLETE）。只有函数
# 自己报得出是哪一种。**写成纯 ASCII 是有意的**：守卫在父进程里匹配子进程的 stdout，而中文要
# 过 `[Console]::OutputEncoding` 这一道解码，编码不匹配时中文行会糊成乱码 → 守卫假红。
function Prune-LocalTimeline {
    param([Parameter(Mandatory)][string]$Stage)

    # 语义层是引擎旁路（AGENTS §1.3）：这里抛异常不得带走整层，所以异常自己吞掉并留下证据。
    try {
        $keep = 14
        if ($env:SEM_TIMELINE_KEEP -match '^\d+$') { $keep = [int]$env:SEM_TIMELINE_KEEP }
        if ($keep -lt 1) {
            Write-Host "[semantic] timeline-retention window: keep=$keep snaps=0 (disabled)"
            return
        }
        if (-not (Test-Path -LiteralPath $Stage)) {
            Write-Host "[semantic] timeline-retention window: keep=$keep snaps=0 (no-stage)"
            return
        }

        $root = $Stage.TrimEnd('\', '/')
        $snaps = @(Get-ChildItem -LiteralPath $root -Recurse -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.FullName.Length -le $root.Length) { return }
                # 分隔符先归一成 '/' 再数段数：Windows 下 '\' 与 '/' 混排时「按相对路径排序」
                # 才有唯一答案（bash 侧同一份树只有 '/'，移植时最容易漏的就是这一步）
                $segs = @($_.FullName.Substring($root.Length + 1) -split '[\\/]')
                # 4 段 = YYYY/MM/DD/HHMM-标签；与 bash 的 -mindepth 4 -maxdepth 4 同口径
                if ($segs.Count -ne 4) { return }
                [pscustomobject]@{ Full = $_.FullName; Rel = ($segs -join '/'); Leaf = $_.Name }
            })
        Write-Host "[semantic] timeline-retention window: keep=$keep snaps=$($snaps.Count)"
        if ($snaps.Count -le $keep) { return }

        # 排序键是归一化后的相对路径（日期树天然字典序）。不写 -Culture：那是 5.1 下没验证过的
        # 参数绑定，而这条路径的字符集只有数字、连字符、斜杠，序数与文化比较在此同解。
        $victims = @($snaps | Sort-Object -Property Rel |
            Select-Object -First ($snaps.Count - $keep))
        foreach ($v in $victims) {
            if ($v.Leaf -notmatch '^[0-9]{4}-[a-z0-9-]+$') {
                Write-Warning "[semantic] 跳过非快照形态路径: $($v.Rel)"
                continue
            }
            Remove-Item -LiteralPath $v.Full -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $v.Full) {
                Write-Warning "[semantic] 本地暂存没删掉（被占用？）: $($v.Rel)"
            } else {
                Write-Host "[ OK ] [semantic] 本地暂存保留最近 $keep 份，清理: $($v.Rel)"
            }
        }

        # 腾空日期壳级联删除：一趟按「深→浅」扫，并且把「是否已空」的判定放在排序**之后**——
        # 管道是流式的，子壳先被删掉，轮到父壳时它才可能已经空了。这等价于 bash 侧
        # `find -mindepth 1 -maxdepth 3 -type d -empty -delete`（-delete 隐含 -depth）。
        # 先筛空、再统一删的写法只会收掉一层：日期壳没了、月份壳还留着（10-02 在 Linux 容器里
        # 跑 pwsh 7 才抓出来的移植偏差——bash 侧同一条守卫也没测到，因为它所有种子都在同一个月）。
        # 路径长度降序 ≈ 自深向浅：子路径一定比父路径长，所以父壳永远排在子壳之后。
        Get-ChildItem -LiteralPath $root -Recurse -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property { $_.FullName.Length } -Descending |
            Where-Object { (Test-Path -LiteralPath $_.FullName) -and $_.GetFileSystemInfos().Count -eq 0 } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "[semantic] timeline-retention aborted by exception: $($_.Exception.Message)"
    }
}

# 把引擎报告里的时间值转成 bg 认得的 ISO 串。为什么需要这一层：ConvertFrom-Json 对「长得像
# 日期」的 JSON 字段返回什么类型**取决于宿主版本**——pwsh 7.2 给 String（原文照抄），而
# Windows PowerShell 5.1 与 pwsh 7.4+ 给 [datetime]，后者一旦进命令行就被 ToString() 转成
# 文化相关的 `10/02/2026 06:31:11`，bg 的 parse_iso 见它必崩。restic 的 `snapshots --json`
# 里 time 正是这种字段，所以这条只在**存在上一份归档**时才露头（首备没有 prev）：CI 每轮新建
# 仓库只跑首备，10-02 第一次让产品跑第二轮（windows job 集成段）才炸出来，而真机 nightly
# 从第二天起就一直踩在同一条上。ToUniversalTime + 固定 Z 尾巴：不碰文化、不留类型歧义。
function Format-IsoTime {
    param($Value)
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'")
    }
    [string]$Value
}

# bg 入口解析：$env:BG > 与本文件同目录的 bg.pyz / bg_semantic.py（再退到 python/py）。
# 为什么提到顶层而不是留在 Invoke-SemanticLayer 里嵌套：密封侧记样本哈希与演练侧取样本
# 都要调 bg，嵌套一份就得再抄第二份——而「记哈希的抽样与 drill 的抽样各算各的」正是 A2b
# 那条教训的形状（bash 侧同一件事也只有 semantic_bg 一个实现）。
# 注意 dot-source 时 $PSScriptRoot 已是 semantic 目录本身（CI 实测教训）。
function Resolve-BgEntry {
    if ($env:BG) { return @{ Bin = $env:BG; Args = @() } }
    $bgScript = @("$PSScriptRoot\bg.pyz", "$PSScriptRoot\bg_semantic.py") |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $bgScript) { return $null }
    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $python) { $python = (Get-Command py -ErrorAction SilentlyContinue).Source }
    if (-not $python) { return $null }
    @{ Bin = $python; Args = @($bgScript) }
}

function Invoke-Bg {
    param([Parameter(ValueFromRemainingArguments)][AllowEmptyCollection()] $Rest)
    # 每个含原生命令的作用域自己声明一档（外层的 Continue 靠动态作用域也管用，但「外层忘了」
    # 是本发 fix 之前那九处的成因；探针事实 5 就是按作用域逐个查的）
    $ErrorActionPreference = "Continue"
    $entry = Resolve-BgEntry
    if (-not $entry) {
        # 调用方都先过 Resolve-BgEntry 才走到这里；真走到这一步时不假装成功——留一行告警，
        # 让上层那句「plan 解析不出样本」的判定接手（宁缺毋滥，绝不用上一条命令的 $LASTEXITCODE 冒充）
        Write-Warning "[semantic] bg 入口不在（BG / python / bg.pyz 三者都没了）"
        return
    }
    & $entry.Bin @($entry.Args) @($Rest)
}

# ---------- 恢复演练（roadmap A2b 的 Windows 那一半，对位 semantic.sh:369 run_drill）----------
# 三个开关与 bash 逐字同名（SEM_DRILL / SEM_DRILL_COUNT / SEM_DRILL_FORCE），默认值也同：
# 两份实现只在引擎上分开（borg extract vs restic restore），口径分了家就会有一天一边跑一边不跑。
function Get-DrillSwitch { if ($env:SEM_DRILL) { $env:SEM_DRILL } else { "1" } }
function Get-DrillCount {
    if ($env:SEM_DRILL_COUNT -match '^\d+$') { $env:SEM_DRILL_COUNT } else { "5" }
}
function Get-DrillHashMaxBytes {
    if ($env:SEM_DRILL_HASH_MAX_BYTES -match '^\d+$') { $env:SEM_DRILL_HASH_MAX_BYTES } else { "8388608" }
}

# 取回单个文件。--include 只把 `\` 归一成 `/`，**不补前导斜杠**：清单里那份路径是 bg 归一化
# 过的（前导 / 与 Windows 盘符段都被剥掉），而 restic 的过滤规则是「不带前导 / 的多段模式在
# 路径任意位置匹配」——10-03 用真 restic 量过九种形态（归档路径 /tmp/bg-include-exp/src/sub/
# note.txt）：`tmp/bg-include-exp/src/sub/note.txt`（＝剥掉首段后的 raw）取回 1 个文件，
# 而补了前导斜杠的 `/tmp/bg-include-exp/src/sub/note.txt` 取回 0 个。Windows 上归档路径是
# `C:/Users/…`，剥掉盘符的 raw 正好是「少一个前导段」那一档，所以补斜杠等于每夜必取不回。
# 代价是模式比精确锚定松（同后缀的别的子树也可能被解出来），所以判据不是 rc 而是「落地文件
# 按后缀挑出来 + 比尺寸 + 比备份期记下的内容哈希」——同后缀同尺寸但不是那个文件，正由哈希拦下。
function Restore-DrillFile {
    param(
        [string]$Bin = "restic",
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Snap,
        [Parameter(Mandatory)][string]$Include,
        [Parameter(Mandatory)][string]$Target
    )
    $ErrorActionPreference = "Continue"   # restic 的进度与警告写在 stderr
    $inc = $Include -replace '\\', '/'
    # 引擎原文只进本地 backup.log，不进 rescue-test.txt：报告里现在虽然分得开「引擎报错」与
    # 「退出 0 但挑不出文件」（10-03 拆的），但**为什么**报错只有 restic 自己知道。
    # 10-03 真 windows runner 就是靠这条才看得见（清单路径 `C/Users/…` vs 源路径 `C:\Users\…`）。
    $o = @(& $Bin -r $Repo restore $Snap --include $inc --target $Target 2>&1 |
        ForEach-Object { "$_" })
    $rc = $LASTEXITCODE
    if ($env:BACKUP_LOG) {
        $tail = @($o | Where-Object { $_ } | Select-Object -Last 3)
        # 落地树单独取证（10-03 第三轮的量法）：真 windows runner 上引擎报 rc=0、
        # `Restored 9 / 1 files/dirs (13 B / 13 B)`（9 正好是归档路径的段数），而按 `-File`
        # 递归枚举到的是 **0 个文件**——「文件根本没落盘」与「落盘了但枚举/判定看不见」在
        # rescue-test.txt 里同形。所以这里连**目录**一起列（只列 target 之下的相对名），
        # 并记最深那条的字符数：Windows 的 MAX_PATH 是 260，而归档内路径本身就有 130 字符，
        # 拼上 target 就压到那条线上——长度是这一发唯一的嫌疑人，不写出来下一轮还是盲的。
        $landed = @(Get-ChildItem -LiteralPath $Target -Recurse -ErrorAction SilentlyContinue)
        # target 底下什么都没有时，光看 landed=0 仍分不开「落到了 target 的兄弟目录」与
        # 「restic 写到别处去了」——所以只在这一档再往上列一层（**纯读**：不碰任何引擎命令，
        # 见 AGENTS §2「探测不许与被测命令同形」）。
        $where = "target"
        if ($landed.Count -eq 0) {
            $par = Split-Path -Parent $Target
            $landed = @(Get-ChildItem -LiteralPath $par -ErrorAction SilentlyContinue)
            $where = "parent"
        }
        $maxLen = 0
        foreach ($it in $landed) { if ($it.FullName.Length -gt $maxLen) { $maxLen = $it.FullName.Length } }
        $names = @($landed | Select-Object -First 12 | ForEach-Object {
            $rel = "$($_.FullName)"
            if ($rel.Length -gt $Target.Length) { $rel = $rel.Substring($Target.Length) }
            ($rel -replace '^[\\/]+', '') + $(if ($_.PSIsContainer) { "/" } else { "" })
        })
        try {
            [void](Add-Content -LiteralPath $env:BACKUP_LOG -Value (
                "[drill-restore] rc=$rc include=$inc target=$Target" + "`n" +
                "[drill-restore] landed=$($landed.Count) entries listed under $where, deepest path $maxLen chars" + "`n" +
                ($names -join "`n") + "`n" + ($tail -join "`n")))
        } catch { }
    }
    $rc
}

# 结论判定，逐字照抄 bash 的两条教训：汇总行写作「N PASS / 0 FAIL」，含字面 FAIL——按整行匹配
# 'FAIL' 会把全通过误判成失败；而结论行缺失或解析不出，一律判失败（宁可误报，不可漏报）。
function Test-DrillHasFailure {
    param([Parameter(Mandatory)][string]$ReportPath)
    $lines = @(try { Get-Content -LiteralPath $ReportPath -ErrorAction Stop } catch { @() })
    if (@($lines | Where-Object { $_ -match '^FAIL ' -or $_ -match '^RESULT: FAIL' }).Count -gt 0) {
        return $true
    }
    $counts = @($lines | ForEach-Object {
        if ($_ -match '^RESULT: [0-9]+ PASS / ([0-9]+) FAIL') { $matches[1] }
    })
    if ($counts.Count -ne 1) { return $true }
    [int]$counts[0] -ne 0
}

function New-DrillResult {
    param(
        [Parameter(Mandatory)][int]$Code,
        [string]$Report = "",
        [int]$Pass = 0, [int]$Fail = 0, [int]$Samples = 0,
        [int]$Hashed = 0, [int]$SizeOnly = 0, [bool]$Failed = $false, [string]$Note = ""
    )
    # 返回**对象**而不是裸数组/裸整数：rescue.ps1 那一课的数组摊平在这里同样会咬人
    [pscustomobject]@{ Code = $Code; Report = $Report; Pass = $Pass; Fail = $Fail
        Samples = $Samples; Hashed = $Hashed; SizeOnly = $SizeOnly; Failed = $Failed; Note = $Note }
}

# 主流程：解封密封清单 → bg sample（与密封侧共用 select_drill_samples）→ 按类别查快照 →
# restic 实取 → 比内容（备份期记下的 sha256；没记的退回比大小并**在结论里写明依据**）。
# 退出码口径同 bash：0 真跑了（结论里可能含失败项）；10 被 30 天节流；20 没执行。
# 调用方必须按码分支，别拿结果文件的 mtime 反推跑没跑。
function Invoke-Drill {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$SnapshotDir,
        [object[]]$Items,
        [string]$AgeBin = "",
        [string]$Identity = "",
        [string]$ResticBin = "restic"
    )
    $ErrorActionPreference = "Continue"
    $rt = Join-Path $Stage "rescue-test.txt"

    # 开关比的是**字符串** "1"（bash 侧 `[[ "${SEM_DRILL:-1}" == "1" ]]` 同一条）。写成 -eq 1
    # 也能过（PowerShell 把右边转成字符串再比），但「谁转谁」是宿主相关的阅读负担，
    # 而这一档判断错了整层演练会静默反向——显式比字符串。
    if ((Get-DrillSwitch) -ne "1") {
        return New-DrillResult -Code 20 -Report $rt -Note "disabled"
    }
    $itemsArr = @($Items)
    if ($itemsArr.Count -eq 0) {
        return New-DrillResult -Code 20 -Report $rt -Note "no-archive"
    }
    # 30 天节流：标记用**产物自身的 mtime**（与 A2a 同一机制，不另养状态文件）
    if ((Test-Path -LiteralPath $rt -PathType Leaf) -and ($env:SEM_DRILL_FORCE -ne "1")) {
        $days = ((Get-Date) - (Get-Item -LiteralPath $rt).LastWriteTime).TotalDays
        if ($days -lt 30) {
            return New-DrillResult -Code 10 -Report $rt -Note ("throttled={0:N1}d" -f $days)
        }
    }
    if (-not $AgeBin) { $AgeBin = (Get-Command age -ErrorAction SilentlyContinue).Source }
    if (-not $Identity) {
        $Identity = Join-Path $env:APPDATA "PartiverseBackup\age\identity.txt"
    }
    $enc = Join-Path $SnapshotDir "manifest.json.enc"
    if (-not $AgeBin -or -not (Test-Path -LiteralPath $Identity -PathType Leaf) -or
        -not (Test-Path -LiteralPath $enc -PathType Leaf)) {
        return New-DrillResult -Code 20 -Report $rt -Note "missing age/identity/manifest.enc"
    }

    $tmp = New-Item -ItemType Directory -Force -Path `
        (Join-Path $env:TEMP ("bg-drill-" + [guid]::NewGuid().ToString("N")))
    $rep = New-Object System.Collections.Generic.List[string]
    $pass = 0; $failn = 0; $hashed = 0; $sizeOnly = 0; $samples = 0
    try {
        $plain = Join-Path $tmp "manifest.json"
        $rep.Add("# 恢复演练 rescue-test — " + (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"))
        $rep.Add("# 方式: 主身份解封 + restic 实取 + 内容比对（备份期记下的源 sha256；" +
            "没记的退回比大小，逐条标注依据）")

        & $AgeBin -d -i $Identity -o $plain $enc 2>&1 | ForEach-Object { "$_" } | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $plain -PathType Leaf)) {
            $rep.Add("RESULT: FAIL（manifest 解封失败）")
        } else {
            # 抽样走 bg 的同一个函数（select_drill_samples），种子默认「当天」与密封侧一致——
            # 两边各算各的就是「记了没人用」，而这层证据整段退化时现场只有一行计数
            $planText = (@(Invoke-Bg sample --manifest $plain --count (Get-DrillCount) 2>$null) -join "`n")
            $plan = $null
            try { $plan = ConvertFrom-Json $planText } catch { $plan = $null }
            $picked = @(if ($plan -and $plan.samples) { $plan.samples })
            $samples = $picked.Count
            if ($samples -eq 0) {
                # 这里比 bash 严：bash 抽到 0 条时写「RESULT: 0 PASS / 0 FAIL」，看着是通过。
                # 「一条都没抽中」只有两种原因（清单空 / bg 不可用），两种都不是取证通过。
                $rep.Add("RESULT: FAIL（sample 没抽到条目：清单为空或 bg 不可用）")
            }
            $n = 0
            foreach ($s in $picked) {
                $n++
                $cls = "$($s.class)"
                $spath = "$($s.path)"
                $ssize = "$($s.size)"
                $item = @($itemsArr | Where-Object { "$($_.cls)" -eq $cls }) | Select-Object -First 1
                if (-not $item) {
                    # 跨类别抽样（config 里一个小文件恰恰最该证明取得回），拿 files 快照去解
                    # config 路径必然取不回——真机 10-01 就是这么报了假失败
                    $rep.Add("FAIL [$cls] ${spath}（本轮没有 ${cls} 类的快照，无从取回）")
                    $failn++
                    continue
                }
                $outDir = Join-Path $tmp ("out-" + $n)
                [void](New-Item -ItemType Directory -Force -Path $outDir)
                $rc = Restore-DrillFile -Bin $ResticBin -Repo "$($item.repo)" -Snap "$($item.snap)" `
                    -Include $spath -Target $outDir
                # restic 解包把**归档内的完整路径**落在 target 之下（实测 out-5/tmp/…/note.txt），
                # 所以挑命中按后缀比，不去猜它前面那几段是什么。后缀就是清单里那份归一化路径。
                $norm = ($spath -replace '\\', '/')
                $cmpType = [System.StringComparison]::OrdinalIgnoreCase
                # 落地清单单独留一份：「restic 解出 0 个文件」与「解出了 N 个但后缀比不中」是
                # 两种完全不同的坏法（前者＝--include 没命中归档内形状，后者＝落地形状变了），
                # 而 10-03 第二轮的合并消息把 rc≠0 与「挑不出文件」压成同一句话，于是真宿主上
                # 那 13 条 FAIL 一个字都没告诉我们其中哪一种。
                $all = @(Get-ChildItem -LiteralPath $outDir -Recurse -File -ErrorAction SilentlyContinue)
                $hit = @($all | Where-Object {
                    ($_.FullName -replace '\\', '/').EndsWith($norm, $cmpType) })
                $wantSha = ""
                if ($s.PSObject.Properties['sha256']) { $wantSha = "$($s.sha256)" }
                if ($rc -ne 0) {
                    # 引擎原文的最后三行已经进了 $env:BACKUP_LOG 的 [drill-restore] 段；
                    # 这份文件按设计只留本地（§1.1），但仍不该往里抄引擎输出——类别与 rc 够了
                    $rep.Add("FAIL [$cls] ${spath}（restic 退出码 ${rc}≠0：取回命令本身失败，" +
                        "原文见 backup.log 的 [drill-restore]）")
                    $failn++
                } elseif ($hit.Count -eq 0) {
                    $rep.Add("FAIL [$cls] ${spath}（restic 退出 0 但没挑中这条：落地 " +
                        "$($all.Count) 个文件）")
                    $failn++
                } elseif ($hit[0].Length -ne [long]$ssize) {
                    $rep.Add("FAIL [$cls] ${spath}（大小不符：清单 ${ssize} B，取回 $($hit[0].Length) B）")
                    $failn++
                } elseif (-not $wantSha) {
                    # 清单没记哈希就如实写明这一条只证到了大小——不标注，读报告的人会把
                    # 「7 PASS」当成「取回内容对」
                    $rep.Add("PASS [$cls] ${spath} (${ssize} B, 仅比大小：清单未记内容哈希)")
                    $sizeOnly++; $pass++
                } else {
                    $gotSha = ""
                    try {
                        $gotSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $hit[0].FullName).Hash.ToLowerInvariant()
                    } catch { $gotSha = "" }
                    if ($gotSha -and $gotSha -eq $wantSha) {
                        $rep.Add("PASS [$cls] ${spath} (${ssize} B, 内容哈希一致)")
                        $hashed++; $pass++
                    } else {
                        # 大小相同而内容不同＝取回的不是那个文件（或归档里那份已不是当时那份）
                        $shown = if ($gotSha) { $gotSha } else { "算不出哈希" }
                        $rep.Add("FAIL [$cls] ${spath}（内容哈希不符：清单 ${wantSha} ≠ 取回 ${shown}；" +
                            "大小倒是一致（${ssize} B）——只比大小看不见这一类）")
                        $failn++
                    }
                }
            }
            if ($samples -gt 0) {
                $rep.Add("RESULT: $pass PASS / $failn FAIL（抽样 ${samples}；内容哈希 ${hashed}，仅比大小 ${sizeOnly}）")
            }
        }
        # UTF-8 无 BOM（与本文件头「清单落盘」同一口径）；这份文件只留本地，推送那一路 --exclude 挡住
        [System.IO.File]::WriteAllLines($rt, $rep)
    } finally {
        # 明文 manifest.json 里有全量文件名，取回暂存也一样——用完即删（凭据纪律同族的隐私面）
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-DrillResult -Code 0 -Report $rt -Pass $pass -Fail $failn -Samples $samples `
        -Hashed $hashed -SizeOnly $sizeOnly -Failed $(Test-DrillHasFailure -ReportPath $rt)
}

function Invoke-SemanticLayer {
    param(
        [object[]]$Done,          # 每项 @{ cls = "files"; repo = "C:\...\restic-files" }
        [Parameter(Mandatory)] [string]$BackupBase,
        [Parameter(Mandatory)] [string]$DeviceId,
        [Parameter(Mandatory)] [string]$TimeIso
    )
    # 见 backup.ps1 文件头「5.1 宿主口径」：调用方 Start-PartiverseBackup 顶部是 Stop，而偏好变量
    # 按**动态作用域**解析，所以本函数里每一次 `& restic` / `& bg` / `& age` 写 stderr 在 Windows
    # PowerShell 5.1 上都抛终止性异常（run 37003329872 事实 3 实测三形全 THREW）。这里的形状比
    # 备份本体更坏：调用点那句 `catch { Write-Warning "[semantic] 生成失败（不影响备份）" }` 会把它
    # 吞成一句 warning，于是 Windows 设备整条明文层从未产出而 nightly 仍报 FULLY COMPLETE。
    $ErrorActionPreference = "Continue"

    # 解析 bg 入口：$env:BG > 与本脚本同目录的 bg.pyz / bg_semantic.py。
    # 实现在顶层（Resolve-BgEntry / Invoke-Bg），这里只做「没有就整层跳过」的守卫。
    if (-not (Resolve-BgEntry)) {
        Write-Warning "[semantic] 未找到 bg 入口（bg.pyz/bg_semantic.py 与 python 都不在，也没设 BG），跳过语义层"
        return
    }

    Invoke-Bg --version *> $null
    if ($LASTEXITCODE -ne 0) { Write-Warning "[semantic] bg 不可用，跳过"; return }

    $stage = Join-Path $BackupBase "timeline"
    $runsDir = Join-Path $env:LOCALAPPDATA "PartiverseBackup\runs"
    $tmp = New-Item -ItemType Directory -Force -Path `
        (Join-Path $env:TEMP "bg-sem-$(Get-Random)")

    # 演练要用的「类别 → 本轮最新快照」登记表。用对象数组而不是 bash 那种 `cls:repo:arc` 串：
    # Windows 的仓库路径带盘符（`C:\…` 里就有冒号），bash 侧 `${x%%:*}` 那套切法在这儿会切错。
    $drillItems = @()
    $classArgs = @(); $prevArgs = @(); $parentArgs = @()
    foreach ($d in $Done) {
        $repo = $d.repo
        $raw = $null
        try {
            $raw = (& restic -r $repo snapshots --json 2>$null) -join "`n"
        } catch { Write-Warning "[semantic] [$($d.cls)] snapshots 导出失败"; continue }
        if (-not $raw) { continue }
        $snaps = @($raw | ConvertFrom-Json)
        if ($snaps.Count -eq 0) { continue }
        $sorted = $snaps | Sort-Object time
        $cur = $sorted[-1]
        $drillItems += @{ cls = $d.cls; repo = $repo; snap = "$($cur.id)" }

        $curJson = Join-Path $tmp "$($d.cls).jsonl"
        $lines = [string[]]@(& restic -r $repo ls --json $cur.id 2>$null)
        [System.IO.File]::WriteAllLines($curJson, $lines)
        if (-not (Test-Path $curJson)) { continue }
        $classArgs += @("--class", "$($d.cls)=$curJson")

        if ($sorted.Count -ge 2) {
            $prev = $sorted[-2]
            $prevJson = Join-Path $tmp "$($d.cls)-prev.jsonl"
            $plines = [string[]]@(& restic -r $repo ls --json $prev.id 2>$null)
            [System.IO.File]::WriteAllLines($prevJson, $plines)
            if (Test-Path $prevJson) {
                $prevArgs += @("--prev", "$($d.cls)=$prevJson")
                # 过 Format-IsoTime：宿主可能把 time 交回来的是 [datetime]，直接拼进命令行
                # 会变成文化格式串，bg 在 generate 阶段读它才崩（convert 只存不解析）
                $pt = Format-IsoTime $prev.time
                if ($parentArgs.Count -eq 0 -and $pt) {
                    $parentArgs += @("--parent-time", $pt)
                }
            }
        }
    }

    if ($classArgs.Count -eq 0) {
        Write-Warning "[semantic] 无可导出清单，跳过"
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    # 语义标签：按时段自动生成（与 semantic.sh 一致）
    $h = (Get-Date).Hour
    $label = if ($h -ge 23 -or $h -lt 6) { "night" }
             elseif ($h -lt 11) { "morning" }
             elseif ($h -lt 14) { "noon" }
             elseif ($h -lt 18) { "afternoon" }
             else { "evening" }
    if ($env:SEM_LABEL) { $label = $env:SEM_LABEL }

    $runJson = Join-Path $tmp "run.json"
    Invoke-Bg convert --engine restic @classArgs @prevArgs @parentArgs `
        --device $DeviceId --time $TimeIso --label $label --auto-strip --out $runJson *>> $env:BACKUP_LOG
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[semantic] convert 失败（见 backup.log），跳过"
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    $genOut = Invoke-Bg generate --run $runJson --out $stage 2>> $env:BACKUP_LOG
    if ($LASTEXITCODE -ne 0 -or -not $genOut) {
        Write-Warning "[semantic] generate 失败（见 backup.log），跳过"
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    $snapshotDir = ($genOut | Where-Object { $_ -match '^已生成快照目录: ' }) -replace '^已生成快照目录: ', ''

    # 全量清单密封（manifest.json.enc）：age -R 非交互；密钥由 init-keys.ps1 生成
    # （无 recipients 时静默跳过——那一档在 Windows 上与 bash 同义：还没初始化过）
    $ageBin = (Get-Command age -ErrorAction SilentlyContinue).Source
    $rec = Join-Path $env:APPDATA "PartiverseBackup\age\recipients.txt"
    if ($ageBin -and (Test-Path $rec)) {
        # A2b：把「今晚 drill 会抽中的那几个文件」的源内容哈希记进密封清单。
        # 抽样口径两侧必须逐字一致（同一个 count、种子都默认「当天」）——记了没人用、
        # 用的没记，就等于这层证据从来没存在过，而报告上看着是「有 sha256 字段」的。
        # 那一行 `[manifest] 演练样本内容哈希：n/N` 是唯一的现场信号，所以 stderr 必须进日志。
        $hashArgs = @()
        if ((Get-DrillSwitch) -eq "1") {
            $hashArgs = @('--hash-drill-samples', '--sample-count', (Get-DrillCount),
                          '--hash-max-bytes', (Get-DrillHashMaxBytes))
        }
        $manifestJson = Join-Path $tmp "manifest.json"
        # 裸 `@hashArgs` 才是 splat。带括号的 `@($hashArgs)` 是**一个参数**：整份数组被当成
        # 单个 argv 元素按空格拼起来交给 bg，argparse 于是报 `unrecognized arguments:
        # --hash-drill-samples --sample-count 99 …`——那行报错与「三个独立参数没被认出来」
        # 逐字同形，光看日志看不出来（10-03 容器首轮实测）。上面 convert 那处用的就是裸形。
        Invoke-Bg manifest --run $runJson @hashArgs 2>> $env:BACKUP_LOG |
            Out-File -FilePath $manifestJson -Encoding utf8
        & $ageBin -R $rec -o (Join-Path $snapshotDir "manifest.json.enc") $manifestJson 2>> $env:BACKUP_LOG
        if ($LASTEXITCODE -eq 0) { Write-Host "[ OK ] [semantic] manifest.json.enc 已密封" -ForegroundColor Green }
        else { Write-Warning "[semantic] manifest 密封失败（不影响其余产物）" }
    }

    # 恢复演练（roadmap A2b 的 Windows 那一半，对位 semantic.sh:369 的 run_drill）：
    # 主身份解封 → restic 实取 → 按备份期记下的源哈希比内容，结论落 timeline\rescue-test.txt。
    # 非致命（§1.3）：这一层炸了只是少一份取证，不改备份结论，所以整个调用裹在 try 里。
    try {
        $d = Invoke-Drill -Stage $stage -SnapshotDir $snapshotDir -Items $drillItems -AgeBin $ageBin
        switch ($d.Code) {
            0 {
                # 判据用 Failed（= Test-DrillHasFailure 的结论），不用 Fail 计数：后者是这一轮
                # 自己累出来的，结论行没写成 / 解析不出时它是 0，于是「演练整段崩了」会被读成通过。
                # bash 侧同一处踩过的坑（drill_has_failure 只认逐条 FAIL 行 + 计数）。
                if ($d.Failed) {
                    Write-Warning "[drill] 恢复演练有失败项（PASS $($d.Pass) / FAIL $($d.Fail)）：$($d.Report)"
                } else {
                    Write-Host "[ OK ] [drill] 恢复演练通过（$($d.Pass) 条，其中内容哈希 $($d.Hashed) 条、仅比大小 $($d.SizeOnly) 条）" -ForegroundColor Green
                }
            }
            10 { Write-Host '[drill] 上次演练不足 30 天，跳过（人工演练：设 $env:SEM_DRILL_FORCE = "1" 绕开）' }
            default { Write-Host "[drill] 本轮未演练（缺 age/主身份/密封清单或没有可演练的快照）" }
        }
    } catch {
        Write-Warning "[drill] 演练流程异常退出（少一份取证，不改备份结论）: $($_.Exception.Message)"
    }

    # STORY 手机推送（research/08 T1.4）：ntfy 可选 sidecar，SEM_NTFY_URL 未配置即静默跳过。
    # STORY 已受明文层红线约束（目录名+统计），推送摘要安全；公共服务 topic 请用高熵随机串。
    if ($env:SEM_NTFY_URL -and $env:SEM_NTFY_URL -match '^https?://') {
        try {
            $storyPath = Join-Path $snapshotDir "STORY.md"
            $summary = ((Get-Content $storyPath -TotalCount 8 | Where-Object { $_ -match '^(#|中|- )' } |
                Select-Object -First 3) -join ' ')
            if ($summary.Length -gt 400) { $summary = $summary.Substring(0, 400) }
            Invoke-RestMethod -Method Post -Uri $env:SEM_NTFY_URL -Body $summary -TimeoutSec 10 `
                -Headers @{ Title = "backguard 备份完成"; Tags = "floppy_disk" } | Out-Null
            Write-Host "[ OK ] [semantic] STORY 摘要已推送" -ForegroundColor Green
        } catch {
            Write-Warning "[semantic] ntfy 推送失败（不影响备份）: $($_.Exception.Message)"
        }
    }

    # run JSON 留档（最近 60 份）
    New-Item -ItemType Directory -Force -Path $runsDir | Out-Null
    Copy-Item $runJson (Join-Path $runsDir "run-$(Get-Date -Format 'yyyyMMdd-HHmmss').json") `
        -ErrorAction SilentlyContinue
    Get-ChildItem $runsDir -Filter "run-*.json" | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 60 | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    # 本地暂存保留策略（与 semantic.sh:354 同一处落点：生成之后、推送之前）
    Prune-LocalTimeline -Stage $stage

    Write-Host "[ OK ] [semantic] 时间轴已生成: $stage" -ForegroundColor Green
}
