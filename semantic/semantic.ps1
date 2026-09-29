# semantic.ps1 — 语义层生成（research/06 章 L0/L1/L2），由 backup.ps1 dot-source 后调用
# 设计红线：语义层任何失败都不得影响备份本身（调用点全部非致命）。
# 引擎：restic（Windows 侧引擎）。RESTIC_PASSWORD 由 backup.ps1 载入 secrets 时已注入进程环境。
# 兼容性：清单落盘走 [IO.File]::WriteAllLines（UTF-8 无 BOM）；bg 侧以 utf-8-sig 读取，
# 兼容 Windows PowerShell 5.1 与 pwsh 7。

function Invoke-SemanticLayer {
    param(
        [object[]]$Done,          # 每项 @{ cls = "files"; repo = "C:\...\restic-files" }
        [Parameter(Mandatory)] [string]$BackupBase,
        [Parameter(Mandatory)] [string]$DeviceId,
        [Parameter(Mandatory)] [string]$TimeIso
    )

    # 解析 bg 入口：$env:BG > 仓库内 bg.pyz / bg_semantic.py（python 由 python/py 提供）
    $semanticDir = Join-Path $PSScriptRoot "semantic"
    $bgScript = @("$semanticDir\bg.pyz", "$semanticDir\bg_semantic.py") |
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
                if ($parentArgs.Count -eq 0 -and $prev.time) {
                    $parentArgs += @("--parent-time", $prev.time)
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

    Invoke-Bg generate --run $runJson --out $stage *>> $env:BACKUP_LOG
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[semantic] generate 失败（见 backup.log），跳过"
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    # run JSON 留档（最近 60 份）
    New-Item -ItemType Directory -Force -Path $runsDir | Out-Null
    Copy-Item $runJson (Join-Path $runsDir "run-$(Get-Date -Format 'yyyyMMdd-HHmmss').json") `
        -ErrorAction SilentlyContinue
    Get-ChildItem $runsDir -Filter "run-*.json" | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 60 | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "[ OK ] [semantic] 时间轴已生成: $stage" -ForegroundColor Green
}
