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

function Invoke-SemanticLayer {
    param(
        [object[]]$Done,          # 每项 @{ cls = "files"; repo = "C:\...\restic-files" }
        [Parameter(Mandatory)] [string]$BackupBase,
        [Parameter(Mandatory)] [string]$DeviceId,
        [Parameter(Mandatory)] [string]$TimeIso
    )

    # 解析 bg 入口：$env:BG > 与本脚本同目录的 bg.pyz / bg_semantic.py。
    # 注意 dot-source 时 $PSScriptRoot 已是 semantic 目录本身（CI 实测教训）。
    $bgScript = @("$PSScriptRoot\bg.pyz", "$PSScriptRoot\bg_semantic.py") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $bgScript) { Write-Warning "[semantic] 缺少 bg.pyz/bg_semantic.py，跳过语义层"; return }
    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $python) { $python = (Get-Command py -ErrorAction SilentlyContinue).Source }
    if (-not $python -and -not $env:BG) {
        Write-Warning "[semantic] 未找到 python（也未设置 BG），跳过语义层"; return
    }

    function Invoke-Bg {
        param([Parameter(ValueFromRemainingArguments)] $Rest)
        if ($env:BG) { & $env:BG @Rest } else { & $python $bgScript @Rest }
    }

    Invoke-Bg --version *> $null
    if ($LASTEXITCODE -ne 0) { Write-Warning "[semantic] bg 不可用，跳过"; return }

    $stage = Join-Path $BackupBase "timeline"
    $runsDir = Join-Path $env:LOCALAPPDATA "PartiverseBackup\runs"
    $tmp = New-Item -ItemType Directory -Force -Path `
        (Join-Path $env:TEMP "bg-sem-$(Get-Random)")

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

    # 全量清单密封（manifest.json.enc）：age -R 非交互；Windows 密钥初始化
    # （init-keys.exp 的对称实现）留待 M1 后续——无 recipients 时静默跳过
    $ageBin = (Get-Command age -ErrorAction SilentlyContinue).Source
    $rec = Join-Path $env:APPDATA "PartiverseBackup\age\recipients.txt"
    if ($ageBin -and (Test-Path $rec)) {
        $manifestJson = Join-Path $tmp "manifest.json"
        Invoke-Bg manifest --run $runJson | Out-File -FilePath $manifestJson -Encoding utf8
        & $ageBin -R $rec -o (Join-Path $snapshotDir "manifest.json.enc") $manifestJson 2>> $env:BACKUP_LOG
        if ($LASTEXITCODE -eq 0) { Write-Host "[ OK ] [semantic] manifest.json.enc 已密封" -ForegroundColor Green }
        else { Write-Warning "[semantic] manifest 密封失败（不影响其余产物）" }
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
