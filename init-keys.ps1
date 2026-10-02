# init-keys.ps1 — Windows 密钥初始化（semantic/init-keys.exp 的 PowerShell 对应物）
#
# 为什么必须有：`semantic.ps1` 的密封那一步只在 `%APPDATA%\PartiverseBackup\age\recipients.txt`
# 存在时才跑（semantic.ps1:212），而 Windows 侧今天没有任何东西生成它——也就是说 Windows 的
# 时间轴**从来没密封出过一个 manifest.json.enc**，`rescue.ps1 -Ledger` 到了现场才发现无账本可解。
# 全量文件名清单不能明文上云（隐私红线 §1.1），所以「没有密封件」不等于「清单少一层保护」，
# 而是等于「逃生时只剩引擎一条路」。
#
# 为什么分两档（不是为了方便测试，是 age 的硬约束）：
#   - `age-keygen -o`、`age-keygen -y`、`age -R`、`age -d -i` 全非交互，CI 与脚本能自己跑完；
#   - **`age -p` / `age -d`（passphrase 形）只认终端**。实测（v1.2.1，无 tty 的容器里）：
#     `age: error: could not read passphrase: standard input is not a terminal, and /dev/tty is
#     not available` —— 而且**不回退到 stdin**，加密件压根没生成。所以 bash 侧要 expect 驱动
#     （AGENTS §2「age 只读 /dev/tty 不吃管道」）。Windows 上对应的那一档只能在人坐在键盘前时做。
#   于是 Primary（本机主身份 + 双 recipient + 恢复码，落盘即可开始密封）与 Rescue
#   （把救援身份用恢复码封起来，需要终端）分开。**关键次序**：恢复身份的**公钥**由
#   `age-keygen -y` 从明文身份直接取得，不需要 passphrase，所以 recipients.txt 在 Primary
#   这一档就能凑满两条——密封当场生效，不必等人在场。
#
# 一条不能塌的不变量：`recipients.txt` 一旦存在就必须**恰好两行**。它是「密钥已初始化」的
# 唯一标记（`init_sem_keys` 也是拿它当标记），单行意味着只有一条恢复路径而没人知道。所以
# recipients.txt 是 Primary 的**最后一步**（两行同时写），而不是边生成边 `>>` 追加。
# 另一半：`recovery-identity.enc` 缺席而明文临时身份也已不在＝恢复码对应的私钥**已经丢了**
# （RECOVERY_LOST），这一档必须判失败——报成「已初始化」等于把人骗到干净机器上才发现读不了。
#
# **闭环验证不是装饰，它抓的是一个引擎级的静默陷阱**（10-03 容器实测，expect 驱动伪终端跑通全档）：
# age 的第一句提示原文是 `Enter passphrase (leave empty to autogenerate a secure one)`——回车按空
# 等于**封进一个谁都没见过的随机口令**，`age -p` 照样退出 0、`.enc` 照样落盘，而那张抄在纸上的
# 恢复码从此解不开它。所以 Rescue 档在封存之后必须拿「已知的那串恢复码」把 `.enc` 真解一遍
# （`verify-rescue pubkey=match`），并核对解出来的公钥确实在 recipients.txt 里；验不过就**保留明文
# 临时身份**（不删 tmp）让人重试——封错了与没封上的区别，只有重新解一遍才知道。
#
# 恢复码：128-bit，8 组 4 位十六进制（与 init-keys.exp 同形，抄写口径一致）。熵源用
# `RandomNumberGenerator`，**不是** `Get-Random`（后者是弱随机，且 5.1/7 的实现不同）；实例方法
# `GetBytes()` 两边都有，静态 `Fill()` 只在 .NET Core 上有——这是 5.1 移植的常规坑。
#
# 机器契约行 `initkeys: <事实>`：纯 ASCII，理由同 rescue.ps1（5.1 按控制台代码页解码子进程
# stdout，中文人读行会变 `?`，拿它当判据就是造一条「只在某一种代码页下为真」的死断言）。
# 恢复码**永不进契约行**，也不进日志：它只落 `recovery-code.txt`（600/private）并显示一次。

param(
    [string]$Stage = "Primary",
    [string]$KeysDir = "",
    [string]$Age = "",
    [string]$AgeKeygen = "",
    [switch]$Status
)

$ErrorActionPreference = "Stop"

# 编码面同 rescue.ps1：能改控制台输出编码就改，退出时改回去（代码页是控制台窗口的属性，
# 不改回去等于把用户的 shell 也换了）。无控制台时 setter 抛，认了。
$script:PrevOutputEncoding = $null
$script:EncodingAdjusted = $false
try {
    if ([System.Text.Encoding]::UTF8.WebName -ne [Console]::OutputEncoding.WebName) {
        $script:PrevOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $script:EncodingAdjusted = $true
    }
} catch { }
function Restore-ConsoleEncoding {
    if ($script:EncodingAdjusted -and $script:PrevOutputEncoding) {
        try { [Console]::OutputEncoding = $script:PrevOutputEncoding } catch { }
    }
}

function Write-Contract([string]$Text) {
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -gt 127) {
            Write-Host "initkeys: WARN contract-line-has-non-ascii"
            break
        }
    }
    Write-Host "initkeys: $Text"
}

function Fail([string]$Code, [string]$Human) {
    Write-Host "[ERR] $Human"
    Write-Contract "ERROR $Code"
    # 不在函数里 exit：pwsh 7 上函数内的 exit 不跑外层 finally，而明文临时身份必须保证被清
    throw "initkeys-abort"
}

# ---------- 依赖定位：显式参数 > 同名环境变量 > PATH（与 rescue.ps1 同一口径）----------
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

# ---------- 交互终端判定（Rescue 档的前提）----------
# 三层，从严到宽：UserInteractive → Console.IsInputRedirected → 交给 age 自己报错。
# `IsInputRedirected` 是 .NET Framework 4.6+ 才有的静态属性，5.1 装得很老的主机上可能没有——
# 取不到属性时**不判失败**（否则一台本来能用的机器被守卫挡住），让 age 自己报那句决定性原文。
function Test-InteractiveConsole {
    if (-not [Environment]::UserInteractive) { return $false }
    $pi = $null
    try { $pi = [Console].GetProperty("IsInputRedirected") } catch { $pi = $null }
    if ($pi) {
        if ([bool]$pi.GetValue($null)) { return $false }
    }
    return $true
}

# ---------- 恢复码 ----------
# 返回字符串而不是集合：这里没有「摊平」面，但要的也只是单个标量。
function New-RecoveryCode {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buf = New-Object byte[] 16           # 128-bit，与 init-keys.exp 的 openssl rand -hex 16 同量
        $rng.GetBytes($buf)
    } finally {
        # .NET Core 3.0+ 才有 IDisposable.Dispose() 静态习惯写法；实例 Dispose 两边都在
        try { $rng.Dispose() } catch { }
    }
    $hex = -join ($buf | ForEach-Object { $_.ToString("x2") })
    $groups = @()
    for ($i = 0; $i -lt 32; $i += 4) { $groups += $hex.Substring($i, 4) }
    # 组数单独断言：拼接写错（少一组）会让抄写口径与 bash 侧不一致，而长度仍是 35
    if ($groups.Count -ne 8) { Fail "CODE_SHAPE" "恢复码分组异常（应为 8 组），已中止——不落盘、不显示" }
    ($groups -join "-")
}

# ---------- 身份/公钥：全部走 age-keygen，非交互 ----------
# **返回对象**（@{ok;...}），不返回裸数组/裸字符串：函数输出会被管道摊平，长度 1 的数组出来是
# 标量、空数组出来是 $null，调用点分不清「没有」与「失败」（同 rescue.ps1 那一课的实测结论）。
function Invoke-KeygenNew([string]$KeygenBin, [string]$OutFile) {
    $ErrorActionPreference = "Continue"       # 5.1：原生命令写 stderr 在 Stop 作用域里＝终止性异常
    if (Test-Path -LiteralPath $OutFile) {
        return @{ ok = $false; reason = "exists" }
    }
    # age-keygen 把公钥打在 **stderr**（不是 stdout），所以这行输出必须收进来而不是丢掉；
    # 判据用 $LASTEXITCODE，不解析它的措辞。
    $noise = @(& $KeygenBin -o $OutFile 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        Write-Contract "keygen-new-fail rc=$LASTEXITCODE"
        return @{ ok = $false; reason = "rc=$LASTEXITCODE" }
    }
    @{ ok = $true; reason = "" }
}

function Get-PublicKey([string]$KeygenBin, [string]$IdentityFile) {
    $ErrorActionPreference = "Continue"
    $out = @(& $KeygenBin -y $IdentityFile 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        Write-Contract "keygen-y-fail rc=$LASTEXITCODE"
        return @{ ok = $false; key = "" }
    }
    # -y 只打一行公钥，但桩/真引擎都可能顺带吐别的，所以取「形如 age1…」的那一行；
    # 取不到算失败——宁缺毋滥，绝不能把一行垃圾写进 recipients.txt。
    $key = ""
    foreach ($line in $out) {
        if ($line -match '^(age1[02-9ac-hj-np-z]{20,})$') { $key = $matches[1]; break }
    }
    if (-not $key) { return @{ ok = $false; key = "" } }
    @{ ok = $true; key = $key }
}

# ---------- 权限面（icacls 在 Linux 容器里不存在：那一段打 skipped，不判失败）----------
# 与 backup.ps1 的 Set-PrivateAcl 同一形状：关继承 + 只授当前用户完全控制，子项靠动态继承跟上。
# 这里是**单独一份**而不是 dot-source backup.ps1：init-keys.ps1 是可以被拷到任意机器上单文件跑的
# 入口脚本（同 rescue 的契约），依赖 backup.ps1 就等于依赖整个仓库。
# **在 Windows 上先收紧树再落盘**，所以 identity.txt / recovery-code.txt 这些文件天生继承私有 DACL，
# 不必逐个点名（AGENTS §2 权限面那一课：点名式清单注定还要漏）。守卫在 windows runner 上验的正是
# 「根与子项都只剩许可名单」这一条（同 test_perms_logic.ps1 的形状）；容器里 icacls 不存在，
# 文件模式跟着 umask 走，那一档**不断言**（容器只用来收敛逻辑，见 test_init_keys_e2e.ps1 文件头）。
function Set-PrivateAclTree([string]$Tree) {
    $ErrorActionPreference = "Continue"
    $icacls = Get-Command icacls -ErrorAction SilentlyContinue
    if (-not $icacls) {
        Write-Contract "perms skipped=no-icacls"
        return "skipped"
    }
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rc = (& $icacls.Source $Tree "/inheritance:r" "/grant:r" "*${sid}:(OI)(CI)F" | Out-String)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] icacls 对密钥目录返回 $LASTEXITCODE——同机其它账号可能读得到私钥，请手工收紧"
        Write-Contract "perms failed rc=$LASTEXITCODE"
        return "failed"
    }
    Write-Contract "perms applied sid-taken=1"
    return "applied"
}

# ---------- 状态读取 ----------
# **不用 `& $scriptBlockVar`**（原先这里是 `$f = { param($n) … }` 再 `& $f "identity.txt"`）：
# probe_windows_ps51.ps1 事实 5 拿 AST 判「每个原生命令调用点都在 EAP=Continue 的作用域里」，
# 而它区分不了 `& $ResticBin`（真引擎，写 stderr 就抛）与 `& $sb`（本地脚本块，根本不碰子进程）——
# 两者在 AST 里长得一模一样，实测四个调用点全被判成违规。分类器不该为了一个可以避开的写法去猜
# 变量的运行时类型，所以这里用文件级函数：`Test-KeyFile` 是本文件定义的符号，裸调用也不带 `&`。
function Test-KeyFile([string]$Dir, [string]$Name) {
    Test-Path -LiteralPath (Join-Path $Dir $Name) -PathType Leaf
}

# 返回一个对象：{ recipients, enc, tmp, identity, code, lines }——一切判定都从这一份走，
# 免得「文件存在性」在两个地方各查一次而答案不一致（bash 侧 init_sem_keys 只看 recipients.txt，
# 于是「recipients 在但 enc 丢」这一档它报不出，这里补上）。
function Get-KeySetState([string]$Dir) {
    $recPath = Join-Path $Dir "recipients.txt"
    $lines = 0
    if (Test-Path -LiteralPath $recPath -PathType Leaf) {
        # 逐行计数不用 .Count：单行文件摊平成标量，`@(...)` 才是「几条」的口径（同 rescue 那一课）
        $lines = @((Get-Content -LiteralPath $recPath -ErrorAction SilentlyContinue |
                Where-Object { "$_".Trim() -ne "" })).Count
    }
    @{
        dir         = $Dir
        exists      = (Test-Path -LiteralPath $Dir -PathType Container)
        identity    = (Test-KeyFile $Dir "identity.txt")
        recipients  = (Test-Path -LiteralPath $recPath -PathType Leaf)
        recLines    = $lines
        enc         = (Test-KeyFile $Dir "recovery-identity.enc")
        tmp         = (Test-KeyFile $Dir ".recovery-identity.tmp")
        code        = (Test-KeyFile $Dir "recovery-code.txt")
    }
}

function Write-StateContract($s) {
    Write-Contract ("state recipients={0} lines={1} enc={2} tmp={3} code={4}" -f `
        $(if ($s.recipients) { "present" } else { "absent" }), $s.recLines,
        $(if ($s.enc) { "present" } else { "absent" }),
        $(if ($s.tmp) { "present" } else { "absent" }),
        $(if ($s.code) { "present" } else { "absent" }))
}

# ---------- 救援身份重验 ----------
# 「enc 存在」与「enc 能用」是两件事，而在这台机器上只有真解一遍才知道（见文件头那条
# `leave empty to autogenerate` 陷阱：空回车封进去的口令没人知道，文件照样落盘、退出码照样 0）。
# 所以 -Stage Rescue 撞到「enc 已在」时**不许**直接报「已封存就完事了」：有终端就重验一遍，
# 没终端就如实打 verify=deferred（既不算证成也不算证败，同 A6 的 UNKNOWN 口径）。
# 返回 @{ ok; reason }——返回对象不返回标量，理由同 rescue.ps1 那一课（摊平）。
function Test-RecoveryPassphraseOpens([string]$Dir, [string]$AgeBin, [string]$KeygenBin) {
    $ErrorActionPreference = "Continue"
    $enc = Join-Path $Dir "recovery-identity.enc"
    $verifyId = Join-Path $Dir ".verify-rec-id"
    try {
        & $AgeBin -d -o $verifyId $enc
        if ($LASTEXITCODE -ne 0) { return @{ ok = $false; reason = "decrypt-rc=$LASTEXITCODE" } }
        $pub = Get-PublicKey $KeygenBin $verifyId
        if (-not $pub.ok) { return @{ ok = $false; reason = "pubkey-unreadable" } }
        $inRec = @((Get-Content -LiteralPath (Join-Path $Dir "recipients.txt") |
                ForEach-Object { "$_".Trim() }) | Where-Object { $_ -eq $pub.key }).Count
        if ($inRec -ne 1) { return @{ ok = $false; reason = "not-in-recipients hits=$inRec" } }
        return @{ ok = $true; reason = "" }
    } finally {
        Remove-Item -LiteralPath $verifyId -Force -ErrorAction SilentlyContinue
    }
}

function Report-RecoveryAlreadySealed([string]$Dir, [string]$AgeBin, [string]$KeygenBin, [string]$StageLabel) {
    if (-not (Test-InteractiveConsole)) {
        Write-Host "[WARN] recovery-identity.enc 已存在，但这一档没有终端可以重验它（封进去的口令对不对，只有解开一次才知道）。"
        Write-Contract "exists action=none enc=present verify=deferred stage=$StageLabel"
        return 0
    }
    Write-Host "[INFO] recovery-identity.enc 已存在：重验一遍它能不能用你抄写的那串恢复码解开"
    $v = Test-RecoveryPassphraseOpens $Dir $AgeBin $KeygenBin
    if (-not $v.ok) {
        Fail "RECOVERY_UNUSABLE" "recovery-identity.enc 解不开或公钥不在册（$($v.reason)）——那份封存件是废的：删掉它重跑 -Stage Rescue（明文临时身份若还在就无需重做整套密钥）"
    }
    Write-Contract "verify-rescue pubkey=match stage=$StageLabel"
    Write-Host "[ OK ] 救援身份可用: $Dir\recovery-identity.enc"
    return 0
}

# ---------- Primary ----------
function Invoke-Primary([string]$Dir, [string]$AgeBin, [string]$KeygenBin) {
    $st = Get-KeySetState $Dir
    Write-StateContract $st
    if ($st.recipients) {
        # 已初始化：不重建（`init_sem_keys` 同一条口径——重建会让已上云的历史清单再也解不开）
        if ($st.recLines -ne 2) {
            Fail "RECIPIENTS_SHAPE" "recipients.txt 有 $($st.recLines) 行（应为 2 行：主身份 + 救援身份）。恢复路径可能只剩一条，先人工核对再动"
        }
        if ($st.enc) {
            Write-Host "[ OK ] 密钥已存在: $Dir（重建需手动删除并确认仍有恢复路径）"
            return (Report-RecoveryAlreadySealed $Dir $AgeBin $KeygenBin "primary")
        }
        if ($st.tmp) {
            Write-Host "[WARN] recipients.txt 已就位，但救援身份还没封（恢复码尚不能独立解密）。补跑: .\init-keys.ps1 -Stage Rescue"
            Write-Contract "pending stage=rescue enc=absent tmp=present"
            return 0
        }
        Fail "RECOVERY_LOST" "recipients.txt 在、recovery-identity.enc 与明文临时身份都不在：恢复码对应的那把私钥已经丢了。请删除 $Dir 里的 recovery-code.txt 并确认另一处离线副本（密钥目录的第二份）之后重做本初始化"
    }
    if ($st.identity) {
        # 上一次中断留下的半成品。age-keygen **拒绝覆盖**（实测 rc=1 `file exists`，原文件不动），
        # 所以这里不猜「该接着用还是该重来」，直接报状态让人决定——静默删除等于毁掉已有的身份。
        Fail "HALF_STATE" "identity.txt 已存在但 recipients.txt 不存在（上一次中断的半成品）。确认它没被用于密封后，删除 $st.dir 下这些文件再重跑: identity.txt, .recovery-identity.tmp"
    }

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    }
    # 目录先收紧再落盘：私钥写进去之后再改 ACL 中间有个窗口（bash 侧靠 umask 077 关这个窗口，
    # Windows 没有 umask，只有「先收紧树、后写文件」这一手）。
    [void](Set-PrivateAclTree $Dir)

    $identity = Join-Path $Dir "identity.txt"
    $rTmp = Join-Path $Dir ".recovery-identity.tmp"
    $recPath = Join-Path $Dir "recipients.txt"
    $codePath = Join-Path $Dir "recovery-code.txt"

    $n1 = Invoke-KeygenNew $KeygenBin $identity
    if (-not $n1.ok) { Fail "KEYGEN_FAILED" "生成主身份失败（$($n1.reason)）" }
    Write-Contract "identity created=primary"
    $p1 = Get-PublicKey $KeygenBin $identity
    if (-not $p1.ok) { Fail "PUBKEY_UNREADABLE" "读不出主身份的公钥（identity.txt 形如无效）" }

    $n2 = Invoke-KeygenNew $KeygenBin $rTmp
    if (-not $n2.ok) { Fail "KEYGEN_FAILED" "生成救援身份失败（$($n2.reason)）" }
    Write-Contract "identity created=recovery"
    $p2 = Get-PublicKey $KeygenBin $rTmp
    if (-not $p2.ok) { Fail "PUBKEY_UNREADABLE" "读不出救援身份的公钥" }
    if ($p1.key -eq $p2.key) { Fail "DUPLICATE_IDENTITY" "两把身份的公钥相同（不可能，除非引擎行为变了）；不落 recipients.txt" }

    # 恢复码先显示再落盘？反过来：先落盘再显示，但**显示与落盘同源**（同 init-keys.exp 的
    # 「expect 侧生成 = 包裹/显示/验证同源」——两处各生成一次，抄下来那张就是废的）。
    $code = New-RecoveryCode
    # ASCII 而不是 utf8：5.1 的 `-Encoding utf8` 会写 BOM，而 age 按字节读 recipients.txt——
    # 首行前多三个字节就解析失败。（身份文件由 age-keygen 自己写，不经这里。）
    ($p1.key + "`r`n" + $p2.key + "`r`n") | Out-File -FilePath $recPath -Encoding ascii
    Write-Contract "recipients lines=2"
    $code | Out-File -FilePath $codePath -Encoding ascii
    Write-Contract "code written=recovery-code.txt groups=8"

    # 闭环验证（非交互那一半）：拿 recipients.txt 封一件一次性探针，再用**两把身份分别**解开。
    # 这一手测的是「两条恢复路径都能落到同一份明文」，也就是 Primary 的全部承诺；
    # passphrase 那一层不在这里（下面 Rescue 档验）。
    $probe = $null
    try {
        $probe = New-TemporaryFile
        $plain = "backguard/init-keys/probe"
        Set-Content -LiteralPath $probe.FullName -Value $plain -Encoding ascii -NoNewline
        $enc1 = Join-Path (Split-Path -Parent $probe.FullName) ("probe-" + [guid]::NewGuid().ToString("N") + ".enc")
        $ErrorActionPreference = "Continue"
        & $AgeBin -R $recPath -o $enc1 $probe.FullName 2>&1 | ForEach-Object { Write-Host "$_" }
        if ($LASTEXITCODE -ne 0) { Fail "VERIFY_SEAL_FAILED" "用刚生成的 recipients.txt 密封探针失败——密钥不可用，不报 KEYS-READY" }
        foreach ($pair in @(@{ kind = "primary"; id = $identity }, @{ kind = "recovery"; id = $rTmp })) {
            $back = Join-Path (Split-Path -Parent $probe.FullName) ("back-" + $pair.kind + ".txt")
            & $AgeBin -d -i $pair.id -o $back $enc1 2>&1 | ForEach-Object { Write-Host "$_" }
            if ($LASTEXITCODE -ne 0) { Fail "VERIFY_DECRYPT_FAILED" "解密探针失败 kind=$($pair.kind)——那一把身份不在这个 recipients 里" }
            $got = (Get-Content -LiteralPath $back -Raw -ErrorAction SilentlyContinue)
            if ("$got" -ne $plain) { Fail "VERIFY_CONTENT_MISMATCH" "解密内容与探针不符 kind=$($pair.kind)" }
            Remove-Item -LiteralPath $back -Force -ErrorAction SilentlyContinue
            Write-Contract "verify kind=$($pair.kind) result=ok"
        }
        Remove-Item -LiteralPath $enc1 -Force -ErrorAction SilentlyContinue
    } finally {
        if ($probe) { Remove-Item -LiteralPath $probe.FullName -Force -ErrorAction SilentlyContinue }
    }

    Write-Host ""
    Write-Host "  ★ 恢复码（唯一显示一次，请立即抄到纸上并妥善保存）:"
    Write-Host "      $code"
    Write-Host "  核对抄写无误后删除副本: Remove-Item `"$codePath`""
    Write-Host "  救援路径: age -d -o recovery-identity.txt `"$Dir\recovery-identity.enc`"（age 会索取 passphrase）"
    Write-Host ""
    Write-Host "  下一步（需要人坐在键盘前，age 只认终端）: .\init-keys.ps1 -Stage Rescue"
    Write-Host "  注意: recovery-identity.enc 按设计**不上云**（凭据纪律），密钥目录必须有第二处离线副本。"
    Write-Contract "done stage=primary rc=0"
    return 0
}

# ---------- Rescue ----------
function Invoke-Rescue([string]$Dir, [string]$AgeBin, [string]$KeygenBin) {
    $st = Get-KeySetState $Dir
    Write-StateContract $st
    if (-not $st.recipients) { Fail "NOT_INITIALIZED" "recipients.txt 不存在——先跑 .\init-keys.ps1（Primary 档）" }
    if ($st.recLines -ne 2) { Fail "RECIPIENTS_SHAPE" "recipients.txt 有 $($st.recLines) 行（应为 2 行），先人工核对" }
    if ($st.enc) {
        return (Report-RecoveryAlreadySealed $Dir $AgeBin $KeygenBin "rescue")
    }
    if (-not $st.tmp) {
        Fail "RECOVERY_LOST" "明文救援身份（.recovery-identity.tmp）已不在，恢复码对应的那把私钥无从封存——请重做本初始化（先确认已上云的密封件还能用主身份解开）"
    }
    if (-not (Test-InteractiveConsole)) {
        Write-Host "[ERR] 这一步要 age 在**终端**上索取 passphrase：脚本不经手口令，也没有可喂的管道（实测 age 在无 tty 时直接报错且不回退到 stdin）。"
        Write-Host "      请在交互式 PowerShell（Windows 上按 Win+R → powershell）里跑: .\init-keys.ps1 -Stage Rescue"
        Write-Contract "no-console stage=rescue"
        return 1
    }
    $enc = Join-Path $Dir "recovery-identity.enc"
    $tmp = Join-Path $Dir ".recovery-identity.tmp"
    Write-Host "[INFO] 接下来 age 会两次索取你抄写的那串恢复码（提示由 age 自己打，本脚本不经手、不落盘）"
    $ErrorActionPreference = "Continue"
    & $AgeBin -p -o $enc $tmp
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $enc -PathType Leaf)) {
        Fail "SEAL_FAILED" "age -p 封存救援身份失败（rc=$LASTEXITCODE）——明文临时身份仍保留，可重试"
    }
    Write-Contract "sealed enc=recovery-identity.enc"

    # 闭环验证（passphrase 那一半）：用恢复码把刚封的件解出来，取它的公钥，核对它确实在
    # recipients.txt 里。同 init-keys.exp 的 VERIFY-OK——少了这一步，「封上了」与「封对了」分不开，
    # 而 age 的空回车 autogenerate 那一手就是把「封错」伪装成「封好」的唯一途径。
    $v = Test-RecoveryPassphraseOpens $Dir $AgeBin $KeygenBin
    if (-not $v.ok) {
        if ("$($v.reason)".StartsWith("decrypt-rc", [System.StringComparison]::Ordinal)) {
            Fail "VERIFY_PASSPHRASE_FAILED" "恢复码解不开刚封存的身份（$($v.reason)）——删掉 $enc 重跑 -Stage Rescue（明文临时身份仍保留，不必重做整套密钥）"
        }
        Fail "VERIFY_NOT_IN_RECIPIENTS" "解出来的救援身份公钥不在 recipients.txt 里（$($v.reason)）——恢复码与已上云的历史清单对不上，别把这套当作可用"
    }
    Write-Contract "verify-rescue pubkey=match"

    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Contract "tmp removed=1"
    [void](Set-PrivateAclTree $Dir)
    Write-Host "[ OK ] 双恢复路径就位：identity.txt（本机）+ recovery-identity.enc（纸质恢复码）"
    Write-Contract "done stage=rescue rc=0"
    return 0
}

# ---------- 入口 ----------
# 退出码与 finally 的次序有讲究：pwsh 7 上「函数内的 exit」不跑外层 finally（rescue.ps1 同一口径，
# Fail 因此用 throw 而不是 exit），所以整个流程只设 $Rc，exit 留在 try/catch/finally **之后**。
$Rc = 0
try {
    if (-not $KeysDir) {
        if (-not $env:APPDATA) {
            Fail "KEYS_DIR_MISSING" "环境变量 APPDATA 不存在（非 Windows 宿主），请显式 -KeysDir <目录>"
        }
        $KeysDir = Join-Path $env:APPDATA "PartiverseBackup\age"
    }
    $KeysDir = (New-Object System.IO.FileInfo($KeysDir)).FullName

    $ageBin = Find-Binary $Age "BACKGUARD_AGE" "age"
    $keygenBin = Find-Binary $AgeKeygen "BACKGUARD_AGE_KEYGEN" "age-keygen"
    if (-not $ageBin -or -not $keygenBin) {
        Fail "BINARY_MISSING" "未找到 age / age-keygen（-Age / -AgeKeygen 指路径；装它 = backup.ps1 -Task Init 的 Install-Deps）"
    }
    Write-Contract ("begin mode={0} stage={1} keysdir={2}" -f `
        $(if ($Status) { "status" } else { "run" }), $Stage.ToLower(), $KeysDir)

    $st = Get-KeySetState $KeysDir
    if ($Status) {
        Write-StateContract $st
        # -Status **只数文件**：它不开任何加密件（开一次就要人打字，而它是要被脚本调的那一档）。
        # 所以 complete 一律带 verify=not-checked——「文件齐」与「恢复码真能解开」是两件事，
        # 后者由 -Stage Rescue 在有终端时重验（RECOVERY_UNUSABLE 那一发就是它抓出来的）。
        if (-not $st.exists) { Write-Contract "status dir=absent complete=0" }
        elseif ($st.recipients -and $st.enc) { Write-Contract "status complete=1 verify=not-checked" }
        else { Write-Contract "status complete=0 verify=not-checked" }
        Write-Host "[INFO] complete 只表示**文件齐**。恢复码到底解得开，请在有终端的地方跑: .\init-keys.ps1 -Stage Rescue（它撞到已封存的件会重验，不重封）"
        $Rc = 0
    } else {
        switch ($Stage.ToLower()) {
            "primary" { $Rc = Invoke-Primary $KeysDir $ageBin $keygenBin }
            "rescue" { $Rc = Invoke-Rescue $KeysDir $ageBin $keygenBin }
            default { Fail "BAD_STAGE" "未知 -Stage '$Stage'（可用: Primary / Rescue）" }
        }
    }
} catch {
    if ("$($_.Exception.Message)" -eq 'initkeys-abort') {
        $Rc = 1     # Fail 已经打过 [ERR] 与 ERROR <code>，这里不再重复一遍
    } else {
        Write-Host "[ERR] 未预期异常: $($_.Exception.Message)"
        Write-Contract "ERROR UNEXPECTED"
        $Rc = 1
    }
} finally {
    Restore-ConsoleEncoding
}
exit $Rc
