# rescue.ps1 — 逃生恢复单文件脚本（Windows 版，与 rescue.sh 同一件事的 PowerShell 移植）
#
# 约束（照抄 rescue.sh 的三条，一条没松）：
#   ①不依赖本仓库其它文件，也不依赖 Python——新机器只要能跑 PowerShell + restic + age，
#     就能只凭「备份目录副本 + 恢复材料」取回文件。
#   ②口令一律交给引擎自己提示（RESTIC_PASSWORD 未设置时 restic 从终端索取）：本脚本不经手、
#     不落盘、不写日志，argv 里也不许出现口令（守卫见 test_rescue_e2e.ps1 场景 8）。
#   ③明文全量清单只落在本脚本自建的临时目录里，用完即删（隐私红线 §1.1）。
#
# **引擎只有 restic**：Windows 上没有 borg 引擎（borgbackup 不支持 Windows，backup.ps1 的
# 三类仓库全是 restic）。所以这里不写 borg 分支——写了就是「永远没人跑过的死代码」。发现
# `<base>\borg-<cls>` 时明确报一个错误码并把人指向 rescue.sh：那一类仓库得有 borg 才读得懂，
# 只报「找不到仓库」会让人以为备份丢了。
#
# 输出面分成两类，这是有意的：
#   - **机器契约行**：`rescue: <事实>`，纯 ASCII，路径类字段用 `|` 分隔（`|` 在 Windows 文件名
#     里非法，所以拿它当分隔符不会被值顶掉）。守卫逐条断言它，不比中文——英文 Windows 的
#     cp1252 控制台会把中文打成 `?`，而 5.1 读子进程 stdout 用的就是这一档编码；拿中文当判据
#     等于造一条「只在某一种控制台代码页下为真」的死断言（AGENTS §2 那条同一形）。
#   - **人读行**：中文说明 + **可复制的路径原样**。逃生现场要复制的就是那串路径，它不能被
#     标签的编码问题挡住，所以路径本身不裹在中文里。
#
# 两种仓库布局、两种时间轴布局都认（与 rescue.sh 同一条判据；逃生工具面向的是历史副本）：
#   本机      <base>\restic-<cls>\   + <base>\timeline\YYYY\MM\DD\HHMM-标签\
#   云端副本  <base>\<cls>\          + <base>\timeline\…（<base> = 挂载点/<系统标识>/）
#   迁移前的旧时间轴多一层设备目录：<base>\timeline\<设备>\YYYY\…

param(
    [switch]$Guide,
    [switch]$List,
    [switch]$Ledger,
    [string]$Find = "",
    [string]$Get = "",
    [string]$Base = "",
    [string]$Class = "",
    [string]$Archive = "",
    [string]$To = "",
    [string]$Snapshot = "",
    [string]$Identity = "",
    [string]$Recovery = "",
    [string]$Restic = "",
    [string]$Age = ""
)

$ErrorActionPreference = "Stop"
$CLASSES = @("config", "files", "system")
$MANIFEST_FORMAT = "backguard/manifest/1"

# 子进程 stdout 的解码编码：restic 打的是 UTF-8，而 5.1 默认按控制台代码页解码——含非 ASCII
# 的路径会在**进脚本之前**就变形，之后无论怎么比、怎么复制都是错的。能改就改，退出时改回去
# （代码页是控制台窗口的属性不是进程的，不改回去等于把用户的 shell 也换了）。
$script:PrevOutputEncoding = $null
$script:EncodingAdjusted = $false
try {
    if ([System.Text.Encoding]::UTF8.WebName -ne [Console]::OutputEncoding.WebName) {
        $script:PrevOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $script:EncodingAdjusted = $true
    }
} catch {
    # 无控制台（输出接管道、Task Scheduler 的隐藏窗口）时 setter 会抛——不是错误，认了
}

function Write-Contract([string]$Text) {
    # 机器契约行：只允许 ASCII。在这里当场拦住，免得将来有人往判据里塞中文。
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -gt 127) {
            Write-Host "rescue: WARN contract-line-has-non-ascii"
            break
        }
    }
    Write-Host "rescue: $Text"
}

function Fail([string]$Code, [string]$Human) {
    Write-Host "[ERR] $Human"
    Write-Contract "ERROR $Code"
    # 不在函数里 exit：pwsh 7 上函数内的 exit 不跑外层 finally，而临时目录里的明文清单
    # 必须保证被删（同一口径见 backup.ps1 的 Get-VerifyCloudHash 注释）
    throw "rescue-abort"
}

# 路径拼接走 Path.Combine，不写 `"$Base\restic-$cls"` 那种字符串：反斜杠在 Linux 上是**合法的
# 文件名字符**，Test-Path 会去找一个叫 `repo\restic-files` 的东西而永远找不到——于是守卫在
# 容器里跑的是一棵树都不存在的假象（本地收敛这一环就废了）。Windows 上 Combine 出来的正是
# 反斜杠形，两边都由宿主决定。
function Join-P {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Parts)
    $p = ""
    # 多展平一层：调用点既可能 `Join-P $a $b`，也可能把一段 split 出来的数组整体递进来
    foreach ($x in @($Parts)) {
        foreach ($seg in @($x)) {
            $s = "$seg"
            if ($s -eq "") { continue }
            $p = if ($p) { [System.IO.Path]::Combine($p, $s) } else { $s }
        }
    }
    $p
}

# ---------- 依赖定位：显式参数 > 同名环境变量 > PATH ----------
# 找不到返回空串，由各模式决定是「整条走不动」（find/get/ledger）还是「那一段没证据、别的
# 照样给」（list 没有 restic 时时间轴那一半仍然读得出来）。不在这脚本里装东西：装依赖是
# backup.ps1 的 Install-Deps-Windows 的事，逃生工具只管读仓库。
function Find-Binary([string]$Explicit, [string]$EnvName, [string]$OnPath) {
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return $Explicit }
        return ""
    }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv -and (Test-Path -LiteralPath $fromEnv -PathType Leaf)) { return $fromEnv }
    $cmd = Get-Command $OnPath -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    ""
}

# ---------- 布局解析 ----------
# 本地 restic-<cls>（backup.ps1 写的）与云端副本 <cls>（rclone 推的）两种都认。
function Resolve-Repo([string]$Cls) {
    $local = Join-P $Base "restic-$Cls"
    if (Test-Path -LiteralPath $local -PathType Container) {
        return @{ path = $local; layout = "local" }
    }
    $cloud = Join-P $Base $Cls
    if (Test-Path -LiteralPath $cloud -PathType Container) {
        return @{ path = $cloud; layout = "cloud" }
    }
    $borg = Join-P $Base "borg-$Cls"
    if (Test-Path -LiteralPath $borg -PathType Container) {
        return @{ path = $borg; layout = "borg" }
    }
    return @{ path = ""; layout = "" }
}

# 时间轴根：第一层是四位数年份 → 新形；否则「唯一子目录」退回迁移前的设备层旧形。
# 认不出（0 个或多个非年份子目录）返回空串，由调用点分档说话——-List 只告警，-Ledger 必须失败。
function Resolve-TimelineBase {
    $tl = Join-P $Base "timeline"
    if (-not (Test-Path -LiteralPath $tl -PathType Container)) { return "" }
    $kids = @(Get-ChildItem -LiteralPath $tl -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($k in $kids) {
        if ($k.Name -match '^[0-9]{4}$') { return $tl }
    }
    if ($kids.Count -ne 1) { return "" }
    return (Join-P $tl $kids[0].Name)
}

# 设备名只进 profile.json（时间轴去设备层后它就在根上）。用正则不用 ConvertFrom-Json：
# 5.1 会把里面的日期字符串烤成 DateTime（§4.17 那一课），而这里要的只是一个标量。
# 读不到返回空串——它不是任何一条链路的前提。
function Read-DeviceId([string]$TlBase) {
    if (-not $TlBase) { return "" }
    $prof = Join-Path $TlBase "profile.json"
    if (-not (Test-Path -LiteralPath $prof -PathType Leaf)) { return "" }
    $text = Get-Content -LiteralPath $prof -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return "" }
    if ($text -match '"device_id"\s*:\s*"([^"]+)"') { return $matches[1] }
    ""
}

# 快照目录：相对时间轴根固定 4 层（YYYY/MM/DD/HHMM-标签），与 backup.sh 的
# `find -mindepth 4 -maxdepth 4` 同一口径——深度是本地暂存根与云端两侧一起的，谁单独改一层谁炸。
# 返回相对时间轴根的正斜杠路径（跨宿主的比对口径，也是打给用户的那串）。
function Get-SnapshotDirs([string]$TlBase) {
    $out = @()
    if (-not $TlBase) { return $out }
    foreach ($y in @(Get-ChildItem -LiteralPath $TlBase -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^[0-9]{4}$' })) {
        foreach ($m in @(Get-ChildItem -LiteralPath $y.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
            foreach ($d in @(Get-ChildItem -LiteralPath $m.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                foreach ($s in @(Get-ChildItem -LiteralPath $d.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    $out += ($y.Name + "/" + $m.Name + "/" + $d.Name + "/" + $s.Name)
                }
            }
        }
    }
    @($out | Sort-Object)     # 字典序即时间序（与 rescue.sh 的 sort 同一口径）
}

# ---------- 引擎调用 ----------
# 每个含原生命令的函数首句把 EAP 压回 Continue：5.1 宿主上 Stop 作用域里的原生命令只要往
# stderr 写一行就抛终止性异常，而 restic 的正常输出偏偏写在 stderr（AGENTS §5；
# probe_windows_ps51.ps1 事实 3 实测三形全 THREW）。静态守卫：该探针事实 5 扫本文件每个调用点。
# 引擎的 stderr **不重定向进变量**：让它直接落终端。否则「口令错/仓库损坏」会被下面的
# 「没有可取的快照」说成成功——rescue.sh 里同一条口径。
#
# 这两个函数返回**一个对象**（`@{ ok; ids }` / `@{ ok; lines }`）而不是裸数组，不是风格问题：
# PowerShell 把函数输出摊平进管道，长度为 1 的数组出来时**就是个字符串**，`$ids[-1]` 于是取到
# 「快照 ID 的最后一个字符」（10-02 E2E 在只有一个快照的 config 仓库上抓到这一发：
# `archive=b` → restic 报 `no matching ID found for prefix "b"`——单快照恰是逃生现场最常见的那
# 一档）；空数组反过来摊平成「什么都没输出」，与引擎失败的 $null 分不开，「仓库是空的」会被
# 报成 ENGINE_UNREADABLE。hashtable 在管道里恒为一个对象，两种退化都进不来。
function Get-ResticSnapshots([string]$Repo) {
    $ErrorActionPreference = "Continue"
    $raw = @(& $script:ResticBin -r $Repo snapshots)
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-Contract "engine-fail cmd=snapshots rc=$rc"
        return @{ ok = $false; ids = @() }
    }
    # 表头是 `ID  Time  Host  Tags  Paths`，另有 `[0:00] 2 snapshots` 的进度行与 `---` 分隔行、
    # 结尾计数行——只认「行首是 8 位以上十六进制再跟空白或到行尾」的（与 rescue.sh 的
    # grep -E '^[0-9a-f]{8,}[[:space:]]' 同形，但把行尾也算进来）
    $ids = @($raw | ForEach-Object { "$_" } |
        Where-Object { $_ -match '^[0-9a-f]{8,}(\s|$)' } |
        ForEach-Object { ($_ -split '\s+')[0] })
    @{ ok = $true; ids = $ids }
}

function Get-ResticPaths([string]$Repo, [string]$Snap) {
    $ErrorActionPreference = "Continue"
    $raw = @(& $script:ResticBin -r $Repo ls $Snap)
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-Contract "engine-fail cmd=ls rc=$rc"
        return @{ ok = $false; lines = @() }
    }
    $lines = @($raw | ForEach-Object { "$_" })
    if ($lines.Count -eq 0) { return @{ ok = $true; lines = @() } }
    # 首行是 `snapshot <id> of [...] filtered by ...:`，其余每行一个仓库内路径。
    # 这里**只丢首行**，不按 `^snapshot` 内容过滤整表：仓库里叫 snapshots/ 的路径很常见，
    # rescue.sh 的 `grep -v '^snapshot '` 会把那些行一起吃掉——移植时改成按位置丢。
    if ($lines[0] -match '^snapshot\s') { $lines = @($lines[1..($lines.Count - 1)]) }
    @{ ok = $true; lines = $lines }
}

function Invoke-ResticRestore([string]$Repo, [string]$Snap, [string]$Include, [string]$Target) {
    $ErrorActionPreference = "Continue"
    # --include 归一成正斜杠：restic 仓库内路径的规范形是 / 分隔，而 Windows 上 ls 打出来的
    # 那一份可能带 \。两种都收。判据不是「传进去的形状看起来对」，是取回之后暂存目录里真有文件。
    $inc = $Include -replace '\\', '/'
    & $script:ResticBin -r $Repo restore $Snap --include $inc --target $Target 2>&1 |
        ForEach-Object { Write-Host "$_" }
    $LASTEXITCODE
}

# ---------- age 解封（两条恢复路径）----------
# 路径 A：-Identity <identity.txt>，非交互，CI 能真跑（真 age + 真密封件）。
# 路径 B：-Recovery <recovery-identity.enc>，age 对 passphrase 只读终端（同 init-keys.exp
# 那一课），CI 里没法打字，所以这一支由桩钉「调用序列 + argv 里没口令 + 明文私钥用完即删」。
function Open-Ledger([string]$Enc, [string]$WorkDir) {
    $ErrorActionPreference = "Continue"
    $plain = Join-Path $WorkDir "manifest.json"
    if ($Identity) {
        if (-not (Test-Path -LiteralPath $Identity -PathType Leaf)) {
            Fail "IDENTITY_MISSING" "主身份文件不存在: $Identity"
        }
        & $script:AgeBin -d -i $Identity -o $plain $Enc 2>&1 | ForEach-Object { Write-Host "$_" }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $plain -PathType Leaf)) {
            Fail "LEDGER_OPEN_FAILED" "主身份解封失败（身份文件与密文不配对？）: $Enc"
        }
        return $plain
    }
    if ($Recovery) {
        if (-not (Test-Path -LiteralPath $Recovery -PathType Leaf)) {
            Fail "RECOVERY_MISSING" "recovery-identity.enc 不存在: $Recovery"
        }
        Write-Host "[INFO] 路径 B：接下来 age 提示输入 passphrase —— 填你抄写的恢复码"
        $recTxt = Join-Path $WorkDir "recovery-identity.txt"
        try {
            & $script:AgeBin -d -o $recTxt $Recovery 2>&1 | ForEach-Object { Write-Host "$_" }
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $recTxt -PathType Leaf)) {
                Fail "RECOVERY_UNWRAP_FAILED" "恢复码未能解开救援身份: $Recovery"
            }
            & $script:AgeBin -d -i $recTxt -o $plain $Enc 2>&1 | ForEach-Object { Write-Host "$_" }
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $plain -PathType Leaf)) {
                Fail "LEDGER_OPEN_FAILED" "账本解封失败（身份与密文不配对？）"
            }
        } finally {
            # 私钥明文只活在这一会儿；Fail 走 throw 也必须经过这里
            if (Test-Path -LiteralPath $recTxt) {
                Remove-Item -LiteralPath $recTxt -Force -ErrorAction SilentlyContinue
            }
        }
        return $plain
    }
    Fail "NO_MATERIAL" "解封账本需要恢复材料：-Identity <age\identity.txt> 或 -Recovery <age\recovery-identity.enc>"
}

# 账本 → 行。清单是 bg manifest 的文档形状：classes.<cls>.entries[] = {path,size,mtime,raw?,sha256?}
# raw 是归档内的原始路径（有 auto_strip 时才有），取回入参要用它，没有就退回 path。
function Read-LedgerRows([string]$PlainPath) {
    $doc = $null
    try { $doc = ConvertFrom-Json (Get-Content -LiteralPath $PlainPath -Raw) }
    catch { Fail "LEDGER_PARSE" "解封出来的账本不是合法 JSON" }
    if ($null -eq $doc) { Fail "LEDGER_PARSE" "解封出来的账本是空的" }
    $fmt = "$($doc.format)"
    if ($fmt -ne $MANIFEST_FORMAT) {
        Write-Host "[WARN] 账本格式非预期（$fmt）——下面的结果可能不全"
        Write-Contract "warn manifest-format=$fmt"
    }
    $rows = @()
    if ($null -eq $doc.classes) { return @{ rows = $rows; fmt = $fmt } }
    foreach ($clsProp in @($doc.classes.PSObject.Properties)) {
        if ($null -eq $clsProp.Value.entries) { continue }
        foreach ($e in @($clsProp.Value.entries)) {
            $restore = "$($e.path)"
            if ($e.PSObject.Properties['raw'] -and "$($e.raw)") { $restore = "$($e.raw)" }
            $rows += @{ cls = $clsProp.Name; path = "$($e.path)"; size = "$($e.size)"; restore = $restore }
        }
    }
    @{ rows = $rows; fmt = $fmt }
}

# ---------- 定位「某个档案的最新/指定快照」，结果回填 script 作用域供 find/get 共用 ----------
function Resolve-Target {
    # 类别名先归一小写：Windows 文件系统大小写不敏感，而仓库目录名（restic-<cls>）和
    # backup.ps1 用的字面量全是小写。不归一的话 `-Class FILES` 在 Linux 宿主上会去找
    # `restic-FILES`——同一份脚本两种宿主给出两种答案，守卫就永远说不清哪边对。
    $Class = "$Class".ToLowerInvariant()
    if (-not ($CLASSES -contains $Class)) {
        Fail "CLASS_REQUIRED" "需要 -Class（config | files | system），收到: '$Class'"
    }
    $r = Resolve-Repo $Class
    # 布局判定排在引擎存在性之前：那一台机器上装着别的引擎时，「这是 borg 仓库，去用
    # rescue.sh」是有效信息，而「未找到 restic」会把人往装引擎的方向支走——白装一遍。
    if ($r.layout -eq 'borg') {
        Fail "BORG_REPO_ON_WINDOWS" "找到的是 borg 仓库 $($r.path)：这里没有 borg 引擎，请在 Linux/macOS 上用 rescue.sh 读它"
    }
    if (-not $r.path) {
        Fail "REPO_NOT_FOUND" "找不到 $Class 档案仓库（$(Join-P $Base "restic-$Class") 或 $(Join-P $Base $Class)）"
    }
    if (-not $script:ResticBin) {
        Fail "BINARY_MISSING" "未找到 restic（-Restic <路径>，或先跑 backup.ps1 的依赖安装步）"
    }
    $script:TargetRepo = $r.path
    $snap = Get-ResticSnapshots $r.path
    if (-not $snap.ok) {
        Fail "ENGINE_UNREADABLE" "restic 读不了 $Class 的快照列表（口令错？仓库损坏？引擎原文见上面）"
    }
    $ids = @($snap.ids)
    if ($ids.Count -eq 0) { Fail "NO_ARCHIVE" "$Class 档案没有可取的快照（仓库是空的？）" }
    if ($Archive) {
        if ($ids -notcontains $Archive) {
            Fail "ARCHIVE_NOT_FOUND" "快照 $Archive 不在 $Class 的 $($ids.Count) 个快照里（-List 可查全部 ID）"
        }
    } else {
        $Archive = $ids[-1]
        Write-Host "[INFO] 使用最新快照: $Archive（共 $($ids.Count) 个）"
    }
    $script:TargetArchive = $Archive
    Write-Contract "target class=$Class repo=$($r.path) layout=$($r.layout) archive=$Archive"
}

# ---------- 各模式 ----------
function Show-Guide {
    $g = @(
        '=================================================================',
        ' backguard 逃生恢复（Windows）— 目录里有什么、怎么取回一个文件',
        '=================================================================',
        '',
        '1) 目录含义（引擎仓库是完整备份的事实源，timeline 只是可读账本）',
        '   restic-config\ 或 config\    配置文件档案（restic 仓库）',
        '   restic-files\  或 files\     个人文件档案',
        '   restic-system\ 或 system\    系统状态档案',
        '   timeline\YYYY\MM\DD\HHMM-标签\',
        '        MANIFEST.txt       明文摘要（只有目录级证据，永不含完整文件名）',
        '        STORY.md           这次备份变了什么（自然语言）',
        '        restore.md         恢复步骤',
        '        manifest.json.enc  完整文件清单（age 密封，含路径与大小）',
        '   timeline\profile.json         设备档案（品牌原名与 device_id）',
        '   timeline\rescue-test.txt      最近一次恢复演练的结果与日期',
        '   （2026-10-01 前的旧副本在 timeline 下多一层设备目录，本脚本两种形状都认）',
        '',
        '2) 定位文件（两条路，任选）',
        '   A. 直接问引擎——不需要 age：',
        '        rescue.ps1 -Base <目录> -Class files -Find 关键词',
        '   B. 问密封账本——需要恢复材料之一：',
        '        路径 A（日常，本机主身份） -Identity <age\identity.txt>',
        '        路径 B（救援，只有恢复码） -Recovery <age\recovery-identity.enc>',
        '                                   → age 提示输入 passphrase 时填恢复码',
        '',
        '3) 取回',
        '        rescue.ps1 -Base <目录> -Class files -Get <路径> -To D:\恢复目录',
        '   -Find 或 -Ledger 输出的那串路径**原样**复制给 -Get；文件落在 -To 下面并保留',
        '   仓库内的目录结构，确认无误再放回原位。取历史快照加 -Archive <快照 ID>（-List 可查）。',
        '',
        '4) 恢复材料从哪来（设计决定：凭据永不上云，2026-10-01 拍板）',
        '   age 身份目录（%APPDATA%\PartiverseBackup\age）与 secrets.env 一样**不随备份上云**。',
        '   所以必须另存一份在机器之外：抄恢复码（纸质）+ 拷贝整个密钥目录到密码管理器或 U 盘。',
        '   只有纸质恢复码还不够：路径 B 需要 recovery-identity.enc 这个文件本身。',
        '',
        '5) 这台机器若没有 restic / age',
        '   本脚本只读仓库、不装引擎。backup.ps1 的依赖安装步把两者落在',
        '   %USERPROFILE%\PartiverseBackup\bin；也可以 -Restic / -Age 显式指路径。',
        '',
        '6) 平时就该验一次：夜间备份每 30 天自动做一次同一条链路的恢复演练。',
        '================================================================='
    )
    foreach ($line in $g) { Write-Host $line }
}

function Invoke-ListMode {
    Write-Contract "base=$Base"
    foreach ($cls in $CLASSES) {
        $r = Resolve-Repo $cls
        if ($r.layout -eq 'borg') {
            Write-Host "[INFO] [$cls] 是 borg 仓库（$($r.path)）——这里没有 borg 引擎，请用 rescue.sh"
            Write-Contract "class=$cls engine=borg-unsupported"
            continue
        }
        if (-not $r.path) {
            Write-Host "[INFO] [$cls] 无仓库"
            Write-Contract "class=$cls missing"
            continue
        }
        if (-not $script:ResticBin) {
            Write-Host "[WARN] [$cls] 找到仓库 $($r.path) 但没有 restic 可读——先装引擎或 -Restic <路径>"
            Write-Contract "class=$cls layout=$($r.layout) unreadable=no-restic"
            continue
        }
        $snap = Get-ResticSnapshots $r.path
        if (-not $snap.ok) {
            Write-Host "[WARN] [$cls] restic 读不了快照列表（$($r.path)）——口令、权限或仓库损坏，引擎原文见上面"
            Write-Contract "class=$cls layout=$($r.layout) unreadable=engine"
            continue
        }
        $ids = @($snap.ids)
        Write-Host "[INFO] [$cls] $($r.path)（layout=$($r.layout)）: $($ids.Count) 个快照"
        Write-Contract "class=$cls layout=$($r.layout) snapshots=$($ids.Count)"
        foreach ($i in $ids) { Write-Contract "snapshot $cls|$i" }
    }
    if (-not (Test-Path -LiteralPath (Join-P $Base "timeline") -PathType Container)) {
        Write-Host "[INFO] 无时间轴目录（$(Join-P $Base 'timeline')）"
        Write-Contract "timeline missing"
        return
    }
    $tl = Resolve-TimelineBase
    if (-not $tl) {
        Write-Host "[WARN] 时间轴结构认不出（$Base\timeline 第一层既不是年份，也不是唯一设备目录）"
        Write-Contract "timeline unrecognized"
        return
    }
    # 同样的摊平退化：时间轴只有 1 个快照时函数出来的是字符串，而 5.1 上字符串没有 .Count
    # （打出来是空），契约行就成了 `snapshots= `。@() 让「0 个」与「1 个」都恒为一个数组。
    $snaps = @(Get-SnapshotDirs $tl)
    $dev = Read-DeviceId $tl
    Write-Host "[INFO] 时间轴根: $tl（最近 5 个快照，共 $($snaps.Count) 个）"
    Write-Contract "timeline=$tl snapshots=$($snaps.Count) device=$(if ($dev) { $dev } else { '-' })"
    foreach ($s in @($snaps | Select-Object -Last 5)) { Write-Contract "timeline-snapshot $s" }
}

function Invoke-FindMode {
    Resolve-Target
    $listed = Get-ResticPaths $script:TargetRepo $script:TargetArchive
    if (-not $listed.ok) { Fail "ENGINE_UNREADABLE" "restic 列快照失败: $($script:TargetArchive)（引擎原文见上面）" }
    $paths = @($listed.lines)
    # 字面量匹配（Ordinal）：路径里的 [ ] . 不是正则元字符——rescue.sh 用 grep -F 同一条口径
    $hits = @($paths | Where-Object { $_.IndexOf($Find, [System.StringComparison]::Ordinal) -ge 0 })
    Write-Contract "hits=$($hits.Count) archive=$($script:TargetArchive)"
    foreach ($h in $hits) { Write-Contract "hit|$h" }
    if ($hits.Count -gt 0) {
        Write-Host "[INFO] $($hits.Count) 条匹配 —— 取回：把上面任意一行 hit| 后面的路径原样复制给 -Get"
    } else {
        Write-Host "[INFO] 无匹配「$Find」（换关键词，或用 -Ledger 查跨档案账本）"
    }
}

function Invoke-GetMode {
    Resolve-Target
    if (-not $To) { Fail "TO_REQUIRED" "-Get 需要 -To <目标目录>" }
    if (-not (Test-Path -LiteralPath $To -PathType Container)) {
        New-Item -ItemType Directory -Path $To -Force | Out-Null
    }
    $abs = (Resolve-Path -LiteralPath $To).Path
    Write-Host "[INFO] 取回 [$Class] $($script:TargetArchive) :: $Get → $abs"
    # 先落到 -To 里一个**本脚本刚创建的**空暂存目录，再数它里面的文件：
    # ①「-To 原本就有文件」冒充成「取回了」这条路直接堵死（rescue.sh 那一处是靠拼出
    #    $TO/<GET 去掉前导 /> 再 Test-Path——跨宿主两种分隔符下我不想依赖那件事）；
    # ②暂存目录与 -To 同卷，把内容 Move 过去是改名而不是复制，几十 GB 也不会翻倍写。
    $stage = Join-Path $abs ".bg-rescue-$([guid]::NewGuid().ToString('N'))"
    $rc = Invoke-ResticRestore -Repo $script:TargetRepo -Snap $script:TargetArchive -Include $Get -Target $stage
    if ($rc -ne 0) {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
        Fail "RESTORE_FAILED" "restic restore 失败 (rc=$rc): $Get"
    }
    $got = 0
    if (Test-Path -LiteralPath $stage -PathType Container) {
        $got = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    }
    if ($got -eq 0) {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
        Fail "NOTHING_RESTORED" "没有取回任何文件——路径请从 -Find 的输出原样复制: $Get"
    }
    # 摊平（任务 #52）：`restore --target` 会把仓库内路径的**绝对形状**整个重建进暂存目录——
    # POSIX 是 `/home/...` 去掉前导斜杠，Windows 是盘符目录树（restic 写盘时自己剥掉了文件名里
    # 非法的冒号，`C:/Users/...` 落成 `C/Users/...`）。不摊平的话用户拿到的是 `-To\C\Users\...`
    # 一棵带盘符前缀的树（10-03 真 runner 取证 `entries=11 files=3 deepest=192`，容器同形，
    # 两边都不合预期）。口径：以**归一化后的 -Get**为界剥前缀，界下的相对结构原样保留
    # （-Get 指目录时，目录内的子结构不动，只剥目录本身那截）；对不上界的一律整结构照搬——
    # 宁可多留层级，不许挪丢文件。
    $incKey = ((($Get -replace '\\', '/') -replace '^/', '') -replace ':', '').TrimEnd('/')
    foreach ($f in @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force)) {
        $rel = ("$($f.FullName)".Substring("$stage".Length) -replace '\\', '/').Trim('/')
        $sub = $rel
        if ($incKey -and $rel -eq $incKey) {
            $sub = ($rel -split '/')[-1]
        } elseif ($incKey -and $rel.StartsWith("$incKey/", [System.StringComparison]::Ordinal)) {
            $sub = $rel.Substring($incKey.Length + 1)
        }
        $parts = @($sub -split '/')
        $destDir = $abs
        if ($parts.Count -gt 1) {
            $destDir = Join-P (@($abs) + @($parts[0..($parts.Count - 2)]))
            if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
        }
        Move-Item -LiteralPath $f.FullName -Destination (Join-P $destDir $parts[-1]) -Force
    }
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Contract "got files=$got to=$abs"
    Write-Host "[ OK ] 已取回 $got 个文件到 $abs（-Get 前缀已剥，以下结构保留）"
}

function Invoke-LedgerMode {
    if (-not $script:AgeBin) {
        Fail "BINARY_MISSING" "未找到 age（-Age <路径>）；账本是 age 密封的，没有它读不了"
    }
    $tl = Resolve-TimelineBase
    if (-not $tl) { Fail "TIMELINE_UNRECOGNIZED" "认不出时间轴结构: $Base\timeline（既没有年份目录，也没有唯一设备目录）" }
    $snap = $Snapshot
    if ($snap) {
        # -Snapshot 给绝对路径就照用，给相对形（2026/10/02/1200-标签，即 -List 打出的那串）
        # 就按宿主分隔符拼到时间轴根上
        if (-not [System.IO.Path]::IsPathRooted($snap)) {
            $snap = Join-P (@($tl) + @($snap -split '[\\/]'))
        }
    } else {
        $all = @(Get-SnapshotDirs $tl)
        if ($all.Count -eq 0) { Fail "NO_SNAPSHOT" "无时间轴快照: $tl" }
        $snap = Join-P (@($tl) + @($all[-1] -split '/'))
    }
    if (-not (Test-Path -LiteralPath $snap -PathType Container)) {
        Fail "SNAPSHOT_NOT_FOUND" "快照目录不存在: $snap"
    }
    $enc = Join-Path $snap "manifest.json.enc"
    if (-not (Test-Path -LiteralPath $enc -PathType Leaf)) {
        Fail "LEDGER_NOT_SEALED" "快照内没有密封账本: $enc（该次备份未密封，或 -Snapshot 指错）"
    }
    $plain = Open-Ledger $enc $script:Work
    $parsed = Read-LedgerRows $plain
    $rows = @($parsed.rows)
    # 明文清单用完即删（隐私红线：完整文件名只存在于密文账本里，且快照目录内不得留明文副本）
    Remove-Item -LiteralPath $plain -Force -ErrorAction SilentlyContinue
    $matched = $rows
    if ($Find) {
        $matched = @($rows | Where-Object { $_.path.IndexOf($Find, [System.StringComparison]::Ordinal) -ge 0 })
    }
    Write-Host "[INFO] 快照: $(Split-Path -Leaf $snap) · 格式 $($parsed.fmt) · 账本 $($rows.Count) 条"
    foreach ($r in $matched) {
        Write-Contract ("row|{0}|{1}|{2}|{3}" -f $r.cls, $r.path, $r.size, $r.restore)
    }
    Write-Contract "ledger entries=$($rows.Count) matched=$($matched.Count) format=$($parsed.fmt)"
    if ($matched.Count -eq 0) {
        Write-Host "[INFO] 账本内无匹配「$Find」"
    } else {
        Write-Host "[INFO] $($matched.Count) 条匹配 —— row| 的第 5 段就是 -Get 的入参"
    }
    Write-Host "[ OK ] 账本查询完成（明文清单已删除，未写入任何日志）"
}

# ---------- 入口 ----------
# 动作由开关决定，优先级 guide > ledger > get > list > find：bash 版靠参数顺序定动作
# （--find 只在还没定动作时才定动作），PowerShell 的开关绑定拿不到顺序，改成显式优先级。
# 实际用法不受影响——`-Ledger -Find x` 仍是「查账本并按关键词过滤」，`-Class x -Find y` 仍是问引擎。
$Mode = ""
if ($Guide) { $Mode = "guide" }
elseif ($Ledger) { $Mode = "ledger" }
elseif ($Get) { $Mode = "get" }
elseif ($List) { $Mode = "list" }
elseif ($Find) { $Mode = "find" }
if (-not $Mode) {
    Write-Host "[ERR] 缺动作：-Guide / -List / -Find / -Get / -Ledger"
    Write-Contract "ERROR NO_MODE"
    exit 2
}

$script:Work = ""
$script:ResticBin = ""
$script:AgeBin = ""
$script:TargetRepo = ""
$script:TargetArchive = ""
$Rc = 0
try {
    if ($Mode -ne 'guide') {
        if (-not $Base) { $Base = Join-Path $env:USERPROFILE "PartiverseBackup\repo" }
        if (-not (Test-Path -LiteralPath $Base -PathType Container)) {
            Fail "BASE_NOT_FOUND" "备份根不存在: $Base（云端副本请指向 <挂载点>/<系统标识>，或用 -Base 指定）"
        }
        $Base = (Resolve-Path -LiteralPath $Base).Path
        $script:ResticBin = Find-Binary $Restic "RESTIC" "restic"
        $script:AgeBin = Find-Binary $Age "AGE" "age"
        # 临时目录：解封出的明文账本只活在这里，退出时删。叶子名有白名单守卫
        # （AGENTS §3.3「递归删除前必须按形态白名单并逐条判定」的口径）——名字不对就宁可漏删。
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("bg-rescue-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        Write-Contract "work=$($script:Work)"
    }
    switch ($Mode) {
        'guide'  { Show-Guide }
        'list'   { Invoke-ListMode }
        'find'   { Invoke-FindMode }
        'get'    { Invoke-GetMode }
        'ledger' { Invoke-LedgerMode }
    }
    Write-Contract "done mode=$Mode rc=0"
} catch {
    if ("$($_.Exception.Message)" -eq 'rescue-abort') {
        $Rc = 1     # Fail 已经打过 [ERR] 与 ERROR <code>，这里不再重复一遍
    } else {
        Write-Host "[ERR] 未预期异常: $($_.Exception.Message)"
        Write-Contract "ERROR UNEXPECTED"
        $Rc = 1
    }
} finally {
    if ($script:Work -and $script:Work -match 'bg-rescue-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:EncodingAdjusted -and $script:PrevOutputEncoding) {
        try { [Console]::OutputEncoding = $script:PrevOutputEncoding } catch { }
    }
}
exit $Rc
