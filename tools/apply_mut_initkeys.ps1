# apply_mut.ps1 —— init-keys 守卫的变异注入器（配合 mutate.sh 逐把刀跑一遍）
#
# 规矩（AGENTS §3）：变异必须**验证真的落上**，没落上就报 NOT-APPLIED 而不是继续跑夹具——
# 10-01 那次「python 抛 AssertionError 而 runner 没 set -e」就是拿未变异的驱动跑出「新断言咬不住」
# 的假结论。这里每条刀都带 Marker，落上判据读的是**替换后的文本**，不是退出码。
# 两种替换模式：
#   Substring  —— 精确子串（可指定第 N 次出现，两处同形的那几发靠这个分开）
#   Line       —— 按「包含某子串的那一整行」替换（行里带全角标点，逐字节匹配太长）
param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Src,
    [Parameter(Mandatory = $true)][string]$Dst
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Knife([string]$id, [string]$file, [string]$mode, [string]$old, [string]$new,
               [string]$marker, [int]$occ = 1) {
    @{ id = $id; file = $file; mode = $mode; old = $old; new = $new; marker = $marker; occ = $occ }
}

$knives = @(
    Knife 'm01' 'init-keys.ps1' 'Line' '$fromEnv = [Environment]::GetEnvironmentVariable' `
        '    $fromEnv = ""' '$fromEnv = ""'
    Knife 'm02' 'init-keys.ps1' 'Substring' '        $rng.GetBytes($buf)' `
        '        $buf = @(1..16 | ForEach-Object { [byte](Get-Random -Maximum 256) })' `
        'Get-Random -Maximum 256'
    Knife 'm03' 'init-keys.ps1' 'Substring' 'Out-File -FilePath $recPath -Encoding ascii' `
        'Out-File -FilePath $recPath -Encoding utf8' '-Encoding utf8'
    Knife 'm04' 'init-keys.ps1' 'Substring' '($p1.key + "`r`n" + $p2.key + "`r`n")' `
        '($p1.key + "`r`n")' '($p1.key + "`r`n") | Out-File'
    Knife 'm05' 'init-keys.ps1' 'Substring' `
        'foreach ($pair in @(@{ kind = "primary"; id = $identity }, @{ kind = "recovery"; id = $rTmp })) {' `
        'foreach ($pair in @()) {' 'foreach ($pair in @()) {'
    Knife 'm06' 'init-keys.ps1' 'Substring' `
        "    `$v = Test-RecoveryPassphraseOpens `$Dir `$AgeBin `$KeygenBin`n    if (-not `$v.ok) {`n        if (`"`$(`$v.reason)`".StartsWith(`"decrypt-rc`"" `
        "    `$v = @{ ok = `$true; reason = `"`" }`n    if (-not `$v.ok) {`n        if (`"`$(`$v.reason)`".StartsWith(`"decrypt-rc`"" `
        '$v = @{ ok = $true; reason = "" }'
    Knife 'm07' 'init-keys.ps1' 'Line' 'Fail "RECOVERY_LOST" "recipients.txt' `
        '        Write-Host "[ OK ] 密钥已存在: $Dir"; Write-Contract "done stage=primary rc=0"; return 0' `
        'done stage=primary rc=0"; return 0'
    Knife 'm07b' 'init-keys.ps1' 'Line' 'Fail "RECOVERY_LOST" "' '        Write-Contract "done stage=rescue rc=0"; return 0' `
        'done stage=rescue rc=0"; return 0' '2'
    Knife 'm08' 'init-keys.ps1' 'Line' 'Fail "HALF_STATE"' `
        '        Remove-Item -LiteralPath (Join-Path $Dir "identity.txt") -Force -ErrorAction SilentlyContinue' `
        'Remove-Item -LiteralPath (Join-Path $Dir "identity.txt")'
    Knife 'm09' 'init-keys.ps1' 'Substring' '    if (-not (Test-InteractiveConsole)) {' `
        '    if ($false -and -not (Test-InteractiveConsole)) {' '$false -and -not (Test-InteractiveConsole)' '2'
    Knife 'm10' 'init-keys.ps1' 'Substring' `
        'if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $enc -PathType Leaf)) {' `
        'if ($LASTEXITCODE -ne 0) {' 'if ($LASTEXITCODE -ne 0) {'
    Knife 'm11' 'init-keys.ps1' 'Substring' "    if (`$st.recipients) {`n        # " `
        "    if (`$false) {`n        # " 'if ($false) {'
    Knife 'm12' 'probe_windows_ps51.ps1' 'Substring' ", 'rescue.ps1', 'init-keys.ps1')" `
        ", 'rescue.ps1')" "'rescue.ps1')"
    # m13：函数内的 EAP=Continue 全部摘掉（摘一处还剩五处，探针照样绿，所以这条规则只能整摘）。
    # 抓它的是**探针**，不是夹具——夹具只静态核对探针的文件清单（场景31）。
    Knife 'm13' 'init-keys.ps1' 'SubstringMulti' '    $ErrorActionPreference = "Continue"' '' ''
    Knife 'm14' 'test_init_keys_e2e.ps1' 'Substring' "        if (`$t.StartsWith('#')) { continue }" `
        "        if (`$false) { continue }" "if (`$false) { continue }"
    # m15/m16 各自只咬一条**新写**的断言（父链与权限分支）：断言必须先证明自己咬得住。
    Knife 'm15' 'init-keys.ps1' 'Substring' '$KeysDir = Join-Path $env:APPDATA "PartiverseBackup\age"' `
        '$KeysDir = Join-Path $env:APPDATA "PartiverseBackupX\age"' 'PartiverseBackupX'
    Knife 'm16' 'init-keys.ps1' 'Substring' '        Write-Contract "perms skipped=no-icacls"' `
        '        Write-Contract "perms applied sid-taken=0"' 'perms applied sid-taken=0'
)

$k = @($knives | Where-Object { $_.id -eq $Id })
if (@($k).Count -ne 1) { Write-Host "mutate: NOT-APPLIED unknown-knife id=$Id"; exit 3 }
$k = $k[0]

$srcFile = Join-Path $Src $k.file
if (-not (Test-Path -LiteralPath $srcFile -PathType Leaf)) {
    Write-Host "mutate: NOT-APPLIED no-such-file $($k.file)"; exit 3
}
$text = [System.IO.File]::ReadAllText($srcFile)
# **保住源文件的 BOM**：init-keys.ps1 / 测试件在仓库里都是 UTF-8 BOM（5.1 读无 BOM 的 UTF-8 脚本
# 会按代码页解码——那正是本夹具要防的一类错）。变异要是把 BOM 弄丢了，跑出来的红与刀无关。
$bytes = [System.IO.File]::ReadAllBytes($srcFile)
$hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

if ($k.mode -eq 'Line') {
    $lines = @($text -split "`r?`n")
    $hits = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Contains($k.old)) { $hits = @($hits) + $i }
    }
    $want = [int]$k.occ
    if ($hits.Count -lt $want) {
        Write-Host "mutate: NOT-APPLIED id=$Id line-hits=$($hits.Count) want=$want anchor='$($k.old)'"
        exit 3
    }
    # occ=1 却命中多行＝锚点不够独特：刀会落在谁身上取决于行序，那不是「这条主张的变异」
    if ($want -eq 1 -and $hits.Count -gt 1) {
        Write-Host "mutate: NOT-APPLIED id=$Id line-hits=$($hits.Count) ambiguous-anchor='$($k.old)'"
        exit 3
    }
    $idx = $hits[$want - 1]
    $lines[$idx] = $k.new
    $out = $lines -join "`n"
} elseif ($k.mode -eq 'SubstringMulti') {
    # 把**所有**出现都摘掉（m13：函数内 EAP=Continue 是一条规则，摘一处还剩五处，探针照样绿）
    $hits = ([regex]::Matches($text, [regex]::Escape($k.old))).Count
    if ($hits -lt 1) { Write-Host "mutate: NOT-APPLIED id=$Id hits=0"; exit 3 }
    $out = $text.Replace($k.old, '')
} else {
    $hits = ([regex]::Matches($text, [regex]::Escape($k.old))).Count
    if ($hits -lt $k.occ) {
        Write-Host "mutate: NOT-APPLIED id=$Id hits=$hits want=$($k.occ)"
        exit 3
    }
    if ($k.occ -eq 1) {
        $out = $text.Replace($k.old, $k.new)
        # Replace 会换掉所有出现，出现次数>1 的刀必须用 occ>1 走下面那条分支
        if ($hits -gt 1 -and $k.id -ne 'm13') {
            Write-Host "mutate: NOT-APPLIED id=$Id substring-appears-$hits-times-use-occ"
            exit 3
        }
    } else {
        $cut = $text.IndexOf($k.old)
        for ($n = 1; $n -lt $k.occ; $n++) { $cut = $text.IndexOf($k.old, $cut + 1) }
        $out = $text.Substring(0, $cut) + $k.new + $text.Substring($cut + $k.old.Length)
    }
}

if ($k.id -eq 'm13') {
    # 删除式变异没有「新文本」可验，验的是**锚点确实一个都不剩**
    if ($out.Contains('    $ErrorActionPreference = "Continue"')) {
        Write-Host "mutate: NOT-APPLIED id=m13 anchor-still-present"; exit 3
    }
} elseif ([string]::IsNullOrEmpty($k.marker)) {
    Write-Host "mutate: BAD id=$Id knife-has-no-marker"; exit 3
} elseif (-not $out.Contains($k.marker)) {
    Write-Host "mutate: NOT-APPLIED id=$Id marker-missing"; exit 3
}

$dstFile = Join-Path $Dst $k.file
[System.IO.File]::WriteAllText($dstFile, $out, (New-Object System.Text.UTF8Encoding($hadBom)))
Write-Host "mutate: APPLIED id=$Id file=$($k.file) bytes=$($out.Length) bom=$hadBom"
exit 0
