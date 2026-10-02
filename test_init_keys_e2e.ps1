# test_init_keys_e2e.ps1 —— init-keys.ps1（Windows 密钥初始化）的端到端守卫
#
# 怎么跑：
#   容器（本机无 pwsh；镜像里要装 age + age-keygen，pty 那几段还要 expect）：
#     docker run --rm -v "$PWD":/repo:ro --entrypoint /bin/bash backguard-native:deps \
#       -c 'pwsh -NoProfile -File /repo/test_init_keys_e2e.ps1 -Repo /repo'
#   （`-c` 那一层不能省：`--entrypoint /bin/bash` 后面的裸 `pwsh` 会被 bash 当脚本文件去找，
#     得到 `cannot execute binary file` rc=126。镜像必须宿主原生架构，口径同 test_rescue_e2e.ps1。）
#   windows job：`& "$PWD\test_init_keys_e2e.ps1"`（pwsh 7 一步 + 5.1 一步）。
# 期望最后一行 `INITKEYS-E2E-OK skipped=N`。**看到 OK 还要看 skipped 那一个数**：age /
# age-keygen 不在 PATH 时引擎那几段整段 Skip，expect 不在时 pty 那几段整段 Skip——「没证据」
# 不等于「通过」（口径同 test_rescue_e2e.ps1 / test_perms_logic.ps1）。windows runner 没有
# expect，pty 那五段在那儿是 Skip：**这是登记在案的覆盖缺口**，不是红也不是绿。
#
# 为什么每一步都是**子进程**：init-keys.ps1 与 rescue.ps1 一样是「可以拷到任意机器上单文件跑」
# 的入口脚本，契约面（argv、退出码、契约行、不经手口令）只有跨进程才测得到。
#
# 子进程的 stdin 一律挂一根管道（"`n" | & …），两层用途，第二层是保命的那层：
#   ①让 `Console.IsInputRedirected` 恒为 true → 被测脚本的「没有终端」判定与 CI/容器一致；
#   ②**没有 tty 就没有任何一发能等人打字**：Rescue 档撞到 age 的 passphrase 提示时，若 stdin
#     是终端，夹具会挂在那儿直到 CI step 超时（25 分钟整轮白跑），而不是报出「拒封」那一行。
#   pty 那几段走 expect（自己造伪终端），不经这条通道。
#
# 覆盖（26 条）：
#   ①入口闸门：KEYS_DIR_MISSING / BINARY_MISSING（显式路径不存在、指向目录）/ BAD_STAGE
#   ②依赖定位的优先级：显式参数 > 同名环境变量 > PATH——把 PATH 掏空只留 BACKGUARD_AGE 那一发
#     是 env 档唯一的实测口径（删掉 Find-Binary 读 env 的那三行，别的场景全绿，因为 age 也在 PATH）
#   ③Primary 全流程：契约行**顺序**（顺序就是流程次序：两把公钥先取齐才落 recipients.txt）、
#     默认 KeysDir（APPDATA 那一档）、recipients 恰好两行且无 BOM 无私钥、恢复码形状 8 组 4 位十六进制
#   ④**闭环由守卫自己重做一遍**：拿 recipients.txt 封一件探针，再用两把身份**分别**解开比对内容；
#     pty 那段封出来的 enc 也由夹具在脚本**之外**拿恢复码解开、取公钥、核对它确实在册——
#     产品自报的 `verify kind=… result=ok` 只是它自己的话
#   ⑤凭据面：恢复码与落盘那份同源、整段输出只出现一次、不进任何契约行、夹具收尾时只在
#     recovery-code.txt 里
#   ⑥状态机每一档：幂等重跑（不重建身份、pending stage=rescue）、HALF_STATE（不删 identity.txt）、
#     RECIPIENTS_SHAPE（两档都判）、RECOVERY_LOST（两档都判）、NOT_INITIALIZED、
#     无终端拒封（enc 没生成、tmp 还在、rc=1 但不报 ERROR）
#   ⑦pty 段（有 expect 才跑）：Rescue 真封存、重入只重验不重封（enc 字节不变）、Primary 重入撞
#     已封存的件在没终端时如实打 verify=deferred、**空回车陷阱**（见下）、空封件不删就直接重入必须
#     RECOVERY_UNUSABLE、封存那一步假成功（退出 0 却不落件）必须 SEAL_FAILED
#   ⑧-Status 三态，且它**只数文件**：不开任何加密件、不建目录
#   ⑨非 ASCII 契约行自警、权限面分支（applied / skipped=no-icacls；Windows 上核 DACL 只剩当前用户）
#   ⑩静态面（解析 0 错误、熵源是 RandomNumberGenerator 不是 Get-Random、不用 .NET Core 才有的静态
#     Fill、身份文件用 ascii 不用 utf8、全脚本只有一个顶层 `exit`、不经手口令）
#   ⑪接线面（探针的 EAP 文件清单里有它；semantic.ps1 找的那个 recipients.txt 就是它写的那个——
#     这条断了就意味着「密钥生成好了但密封那一步没看见」）
#
# **空回车陷阱**（10-03 容器实测，也是这份夹具最值钱的几条之一）：age 的第一句提示原文是
# `Enter passphrase (leave empty to autogenerate a secure one)`——回车按空等于封进一个谁都没
# 见过的随机口令，`age -p` 照样退出 0、`.enc` 照样落盘，而那张抄在纸上的恢复码从此解不开它。
# 「封上了」与「封对了」只有重新解一遍才分得开，所以场景 22 要求：假封那一次绝不许报
# `done stage=rescue rc=0`，而错封件躺在原地时用正确码重入必须撞 RECOVERY_UNUSABLE。
#
# **不覆盖**（如实登记）：
#   - windows runner 上的 pty 段（没有 expect）：今天的「真 age + 真终端」组合只在容器里验过，
#     DEPLOY.md 那一档仍要人坐在键盘前跑一次才算装机完成。
#   - NTFS 的 DACL 只在 windows runner 上验；容器里 icacls 不存在，只验 skipped 分支。
#   - 「恢复码抄到纸上」这一步没法测：测得到的是同源 + 只显一次 + 不落进契约行/日志。
#
# 变异台账（2026-10-03 容器 `backguard-native:deps`：pwsh 7.4.5 + age 1.2.1 + expect。判定口径同
# bash/ps1 侧其它夹具：驱动先比对**旧行内容**再改、回读确认变异落上，再跑整份夹具；没有汇总行＝
# 环境或守卫自己崩了，记 UNDETERMINED 而不是「断言没咬住」）。驱动在
# `tools/apply_mut_initkeys.ps1` + `tools/mutate_initkeys.sh`（变异树整棵拷进可写目录再跑，
# 日志落宿主挂载目录 `/mut/<id>/suite.log`——写在容器 /tmp 里容器一退就没，「没证据」与
# 「没咬住」长得一模一样，10-02 的 m15 就是这么被误判过一次）。
# 基线：113 条 `ok` / 0 `FAIL` / `INITKEYS-E2E-OK skipped=0`（容器里 expect 在，pty 那五段真跑）。
# **17 刀全部咬住**，逐刀（括号里是红的断言数与点名的那条）：
#   m01 Find-Binary 不读同名环境变量（env 档整段失效）→ 1：场景3「PATH 里没有 age、只有
#       BACKGUARD_AGE 时也认得引擎」。删掉读 env 那两行，别的场景全绿——age 也在 PATH，
#       所以这一发是 env 档唯一的实测口径。
#   m02 恢复码改用 Get-Random → 3：场景30 元判据 + 熵源 + GetBytes。**行为面抓不住它**
#       （形状仍是 8 组 4 位十六进制、长度仍是 32，弱随机与强随机在离线判据上不可分辨），
#       能抓住这条主张的只有静态判据——所以静态判据本身也要有刀（m14）。
#   m03 recipients.txt 用 `-Encoding utf8` 写 → 1：场景30「不许 Out-File … -Encoding utf8」。
#       **场景7 那条 BOM 断言在这一刀下是绿的**，因为 pwsh 7 的 `utf8` 不写 BOM，只有 5.1 写——
#       也就是说这发坏法在容器里只被静态判据咬住，行为面那一条要靠 CI 的 5.1 那一步。
#       两档宿主各咬一半，正是这一步要挂两遍的理由。
#   m04 recipients.txt 只写一行（两把身份只落第一把）→ 35：场景7「恰好两行」当场红，
#       随后 Primary/Rescue/-Status/pty 各档全线塌（救援身份不在册 → `VERIFY_DECRYPT_FAILED`）。
#       这一刀是**级联**，不是精修一条主张；留着是因为「单行＝只剩一条恢复路径而没人知道」
#       是全脚本最贵的坏法，级联本身就是它该有的样子。
#   m05 Primary 的闭环解密循环摘空（`foreach ($pair in @())`）→ 1：场景5 契约行**顺序**
#       （`verify kind=primary` / `verify kind=recovery` 两行不再出现）。注意场景8 那条
#       「守卫自己在外部重做一遍 round-trip」在这一刀下**照样绿**——密钥本身是好的；
#       所以「产品自报的那两行有没有落」只能由顺序断言管，两条各有职责，不能互相替代。
#   m06 Rescue 的恢复码重验换成恒 ok（`$v = @{ ok = $true }`）→ 4：场景26 **空回车陷阱**
#       四断言全红（假封那一次报了 `done stage=rescue rc=0`、不报 `VERIFY_PASSPHRASE_FAILED`、
#       错封件被当成功删掉 tmp、按提示重跑也救不回来）。这一刀就是文件头说的那颗陷阱本身。
#   m07 Primary 的 RECOVERY_LOST 报成「已初始化」→ 1：场景13 Primary 档。
#   m07b Rescue 的 RECOVERY_LOST 报成「已封存就完事了」→ 1：场景13 Rescue 档。
#       两档各一刀（同一句报错在两处是两个独立判定，只摘一处另一处照样绿）。
#   m08 HALF_STATE 改成静默删掉 identity.txt 再走正常流程 → 3：场景11 的 rc、identity **字节**、
#       recipients 不许被补出来。**这一刀第一次跑的时候只红两条**：identity 那条原本只测
#       「文件还在」，而变异把文件删了又重建，路径不变、私钥换了，存在性判据照样绿——
#       「路径不变、内容被换」这一类坏法必须比字节（同 §2「rclone 只比大小」那一课的另一侧）。
#   m09 Rescue 的「没有终端就拒封」判定摘掉 → 2：场景15（`age -p` 在无 tty 下直接报错，
#       于是报的是 `ERROR SEAL_FAILED` 而不是「这一步要人」那条非错误结论）。
#   m10 SEAL_FAILED 只看退出码、不看 `.enc` 是否真落盘 → 2：场景28（桩 age 退出 0 不落件，
#       于是 `sealed` 那行被写出来，而落笔前本该见过那个文件）。
#   m11 Primary 的「已初始化就早退」闸门失效（重跑走完整生成流程）→ 5：场景10 幂等重跑
#       （age-keygen 拒绝覆盖已有身份 → `KEYGEN_FAILED`）、场景12/13 各档、场景25 无终端重入。
#   m12 探针的 EAP 文件清单里去掉 init-keys.ps1 → 1：场景31 接线断言（「规则没跑」与
#       「跑过没问题」在契约面上必须分得开）。
#   m13 init-keys.ps1 里函数作用域的 `EAP=Continue` **全部**摘掉 → **夹具 0 红、探针抓到**：
#       `probe51-eap: files=4 nativeCalls=35 varForm=18 violations=6`、`probe_rc=1`。
#       如实登记这条分工：这条主张的守卫是 `probe_windows_ps51.ps1`，不是这份夹具；
#       夹具只在 pwsh 7 里跑（7 不抛那类异常），所以它在容器里对这一刀恒绿是**预期**，
#       不是死断言。CI 的 5.1 那一步才把它钉成行为面。
#   m14 静态判据的注释剥离换成空操作（`if ($false) { continue }`）→ 2：场景30 元判据
#       「静态判据真的滤掉了注释」+ 熵源。**这是给判据自己配的刀**：产品注释里本来就写着
#       「不是 `Get-Random`」，剥离一失效，判据立刻把合规脚本判红，而它的报错会与
#       「实现真的用了 Get-Random」一模一样——没有这条元断言，m02 与 m14 撞成同一句红。
#   m15 默认 KeysDir 的父目录改名（`PartiverseBackup` → `PartiverseBackupX`）→ 2：场景6 父链
#       的「age 的上一层名为 PartiverseBackup」+ 场景31 接线（semantic.ps1 读的就是那个相对路径）。
#       这一刀是给**新写的父链断言**证明它不是死断言用的：上一版拿相对路径字符串比，
#       在 Linux 上因 `Join-Path` 把反斜杠规范化掉而假红（实测 rel=`PartiverseBackup/age/…`），
#       改成父链逐层点名之后，改名这一刀当场咬住。
#   m16 非 Windows 宿主的权限分支谎报 `applied`（其实没动过 ACL）→ 1：场景22
#       「非 Windows 宿主如实打 skipped=no-icacls」。**登记一条缺口**：icacls 真收紧那一半
#       （`perms applied` + DACL 只剩当前用户）只在 windows runner 上验，容器里没有 icacls。
# 「摘掉被测实现而断言仍绿」的刀：0 把。m13 不计入（它的守卫是探针，见上）。
param([string]$Repo = '')
if (-not $Repo) { $Repo = $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:fail = 0
$script:skipped = @()

function Chk([string]$name, $cond, [string]$detail = '') {
    # 条件参数不收 [bool]：`-match` 的左操作数若是命令表达式走集合语义，空结果是 Object[]，
    # 绑不进 [bool]——断言会崩在守卫自己身上而不是报 FAIL（口径同 test_retention_logic.ps1）
    $ok = if ($null -eq $cond) { $false }
          elseif ($cond -is [System.Array]) { @($cond).Count -gt 0 }
          else { [bool]$cond }
    if ($ok) { Write-Host "ok   - $name $detail" }
    else { Write-Host "FAIL - $name $detail"; $script:fail++ }
}
function Skip([string]$name, [string]$why) {
    Write-Host "skip - $name（$why）"
    $script:skipped = @($script:skipped) + $name
}

$script:isWin = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
$script:initKeysPs = Join-Path $Repo 'init-keys.ps1'
Chk '被测脚本在仓库里' (Test-Path -LiteralPath $script:initKeysPs -PathType Leaf)
if (-not (Test-Path -LiteralPath $script:initKeysPs -PathType Leaf)) {
    Write-Host "INITKEYS-E2E-FAIL count=1 (no init-keys.ps1)"; exit 1
}

# 子进程用**同一个宿主**：5.1 那一步跑起来时被测的也是 5.1（Task Scheduler 注册的正是它）
$script:selfPs = 'pwsh'
try {
    $mp = (Get-Process -Id $PID).MainModule.FileName
    if ($mp -and (Test-Path -LiteralPath $mp -PathType Leaf)) { $script:selfPs = $mp }
} catch { }
try {
    $resolved = Get-Command $script:selfPs -ErrorAction Stop
    if ($resolved.Source) { $script:selfPs = $resolved.Source }
} catch { }

$script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('bginitkeys-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($script:root)

# ---------- 依赖发现 ----------
function Which([string]$Name) {
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return "$($c.Source)" }
    ''
}
$script:age = Which 'age'
$script:keygen = Which 'age-keygen'
$script:expectBin = Which 'expect'
$script:haveEngine = ($script:age.Length -gt 0 -and $script:keygen.Length -gt 0)
$script:havePty = ($script:haveEngine -and $script:expectBin.Length -gt 0)
Chk '依赖发现：age 与 age-keygen 在 PATH（不在就整段 Skip，别拿「绿」当「过」）' $script:haveEngine `
    "age=$($script:age) keygen=$($script:keygen)"

function Need-Engine([string]$name) {
    if ($script:haveEngine) { return $true }
    Skip $name 'age / age-keygen 不在 PATH'
    return $false
}
function Need-Pty([string]$name) {
    if ($script:havePty) { return $true }
    Skip $name 'expect 不在 PATH（这一段要有伪终端才测得了 passphrase）'
    return $false
}

# ---------- 子进程调用 ----------
function Invoke-InitKeys {
    param([string[]]$ChildArgs, [hashtable]$Env = @{})
    $prev = @{}
    foreach ($k in @($Env.Keys)) {
        $prev[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $Env[$k])
    }
    $lines = @(); $rc = -1
    try {
        # EAP=Continue：5.1 上子进程往 stderr 写一行就是终止性异常；2>&1 两路都收进来按行读
        $ErrorActionPreference = 'Continue'
        $lines = @("`n" | & $script:selfPs '-NoProfile' '-File' $script:initKeysPs @ChildArgs 2>&1 |
            ForEach-Object { "$_" })
        $rc = $LASTEXITCODE
    } finally {
        foreach ($k in @($Env.Keys)) { [Environment]::SetEnvironmentVariable($k, $prev[$k]) }
    }
    @{ rc = $rc; lines = $lines; text = ($lines -join "`n") }
}

$script:Cp = 'initkeys: '
function Contract([hashtable]$R, [string]$Prefix) {
    $want = $script:Cp + $Prefix
    # StartsWith 而不是 -like：路径里带 [ ] 时 -like 把它们当字符类——契约面按字面量读
    @($R.lines | Where-Object { $_.StartsWith($want, [System.StringComparison]::Ordinal) })
}
function ContractBody([hashtable]$R) {
    @( @(Contract $R '') | ForEach-Object { $_.Substring($script:Cp.Length) })
}
function HasError([hashtable]$R, [string]$Code) {
    # Fail 打的就是 `initkeys: ERROR <CODE>` 整行：按整行等值比，前缀比会把一条 ERROR 误算进另一条
    @($R.lines | Where-Object { $_ -eq ($script:Cp + 'ERROR ' + $Code) }).Count -gt 0
}
function Test-Order([string[]]$Lines, [string[]]$Want) {
    # 契约行的**顺序**就是流程次序：`recipients lines=2` 必须排在两发 keygen 之后、`code written`
    # 之前——那个次序是「两行同时落盘」这条不变量的外化。只断言「都在」等于没断言
    $prev = -1
    foreach ($w in $Want) {
        $i = [Array]::IndexOf($Lines, $w)
        if ($i -lt 0 -or $i -le $prev) { return $false }
        $prev = $i
    }
    return $true
}

function New-Dir([string]$Rel) {
    $p = Join-Path $script:root ($Rel + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][System.IO.Directory]::CreateDirectory($p)
    $p
}
function Run-Primary([string]$Dir) {
    Invoke-InitKeys -ChildArgs @('-Stage', 'Primary', '-KeysDir', $Dir,
        '-Age', $script:age, '-AgeKeygen', $script:keygen)
}
function Run-Rescue([string]$Dir) {
    Invoke-InitKeys -ChildArgs @('-Stage', 'Rescue', '-KeysDir', $Dir,
        '-Age', $script:age, '-AgeKeygen', $script:keygen)
}
function Run-Status([string]$Dir) {
    Invoke-InitKeys -ChildArgs @('-Status', '-KeysDir', $Dir,
        '-Age', $script:age, '-AgeKeygen', $script:keygen)
}
function Get-CodeText([string]$Dir) {
    $p = Join-Path $Dir 'recovery-code.txt'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return '' }
    ("$(Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue)").Trim()
}
# age-keygen -y：公钥可能打在 stdout 也可能随桩混进别的行，按形状取（与被测面同一口径）
function Pubkey-Of([string]$IdentityFile) {
    $ErrorActionPreference = 'Continue'
    @( & $script:keygen -y $IdentityFile 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -match '^age1[0-9a-z]{20,}$' } | Select-Object -First 1 )
}

# ---------- pty 驱动（expect）：passphrase 只有终端能喂 ----------
# 两个目标：`rescue` 跑 init-keys.ps1 -Stage Rescue（要喂 3 次口令：age -p 两次 + 重验一次），
# `age` 跑 `age -d -o <out> <enc>`（夹具**在脚本之外**独立解一次封存件用）。
# 恢复码不经 argv、不写进驱动文件：驱动运行时自己读 recovery-code.txt（凭据纪律）。
$script:expFile = Join-Path $script:root 'pty-driver.exp'
@'
set timeout 180
set log $env(BG_EXP_LOG)
set reply ""
if { $env(BG_EXP_REPLY) eq "code" } {
    set f [open $env(BG_RECOVERY_CODE) r]
    set raw [read $f]
    close $f
    set reply [string trim $raw]
}
log_user 0
log_file -a $log
if { $env(BG_EXP_TARGET) eq "age" } {
    spawn $env(BG_AGE) -d -o $env(BG_DEC_OUT) $env(BG_DEC_ENC)
} else {
    spawn $env(BG_PW) -NoProfile -File $env(BG_SCRIPT) -Stage Rescue -KeysDir $env(BG_KEYS_DIR) -Age $env(BG_AGE) -AgeKeygen $env(BG_KEYGEN)
}
expect {
    -re {Confirm passphrase:} { send -- "$reply\r"; exp_continue }
    -re {Enter passphrase}    { send -- "$reply\r"; exp_continue }
    timeout { send_user "BG-EXP-TIMEOUT\n"; exit 99 }
    eof { }
}
send_user "BG-EXP-EOF\n"
catch wait result
exit [lindex $result 3]
'@ | Out-File -FilePath $script:expFile -Encoding ascii

function Run-Pty {
    param([string]$Dir, [ValidateSet('rescue', 'age')]$Target = 'rescue',
          [ValidateSet('code', 'empty')]$Reply = 'code',
          [string]$Out = '', [string]$Enc = '', [string]$AgeBin = '')
    $log = Join-Path $script:root ('pty-' + [guid]::NewGuid().ToString('N') + '.log')
    $env = @{
        BG_PW = $script:selfPs; BG_SCRIPT = $script:initKeysPs; BG_KEYS_DIR = $Dir
        BG_AGE = $(if ($AgeBin) { $AgeBin } else { $script:age })
        BG_KEYGEN = $script:keygen; BG_EXP_LOG = $log
        BG_RECOVERY_CODE = (Join-Path $Dir 'recovery-code.txt')
        BG_EXP_REPLY = $Reply; BG_EXP_TARGET = $Target
        BG_DEC_OUT = $Out; BG_DEC_ENC = $Enc
    }
    $prev = @{}
    foreach ($k in @($env.Keys)) {
        $prev[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $env[$k])
    }
    $rc = -1; $own = @()
    try {
        $ErrorActionPreference = 'Continue'
        $own = @(& $script:expectBin $script:expFile 2>&1 | ForEach-Object { "$_" })
        $rc = $LASTEXITCODE
    } finally {
        foreach ($k in @($env.Keys)) { [Environment]::SetEnvironmentVariable($k, $prev[$k]) }
    }
    $txt = ''
    if (Test-Path -LiteralPath $log -PathType Leaf) {
        $txt = ((Get-Content -LiteralPath $log -ErrorAction SilentlyContinue) -join "`n") -replace "`r", ''
        # transcript 当场删：它里面可能有 age 提示的回显，恢复码不该活到夹具之外（场景 29 扫它）
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    # pty transcript 有两处**不是**「一行一条输出」：
    #   ①age 在换行前发 `ESC[F` + `ESC[K`（光标回退 + 擦行），于是契约行前面带着转义序列，
    #     `StartsWith('initkeys: ')` 当场读不到——实测丢的就是 `sealed` 与 `verify-rescue` 两条，
    #     而这两条正是这一档的主判据；
    #   ②age 的提示不带换行时，脚本紧接着写的那一条会拼在**同一物理行**上。
    # 所以先剥转义序列，再在每条契约标记前强制断行。人读行不作判据，切坏了也不影响结论。
    $esc = [string][char]27
    $txt = [regex]::Replace($txt, ($esc + '\[[0-9;?]*[A-Za-z]'), '')
    $txt = $txt.Replace($script:Cp, ("`n" + $script:Cp))
    $lines = @(@($txt -split "`n") + @($own))
    @{ rc = $rc; lines = $lines; text = ($lines -join "`n") }
}

# =====================================================================
# 场景 1：KEYS_DIR_MISSING——这一发在**没有** age 的宿主上也要跑（入口先定目录再找引擎）
$R1 = Invoke-InitKeys -ChildArgs @('-Stage', 'Primary') -Env @{ APPDATA = '' }
Chk '场景1 APPDATA 不存在且没给 -KeysDir → KEYS_DIR_MISSING 且 rc=1' (
    (HasError $R1 'KEYS_DIR_MISSING') -and $R1.rc -eq 1) "rc=$($R1.rc) text=$($R1.text)"

# ---------- 以下都要引擎 ----------
if (Need-Engine '场景2 BINARY_MISSING') {
    $d = New-Dir 'binmiss'
    $R = Invoke-InitKeys -ChildArgs @('-Stage', 'Primary', '-KeysDir', $d,
        '-Age', (Join-Path $d 'no-such-age'), '-AgeKeygen', $script:keygen)
    Chk '场景2 显式 -Age 指向不存在的文件 → BINARY_MISSING' (
        (HasError $R 'BINARY_MISSING') -and $R.rc -eq 1) "rc=$($R.rc) text=$($R.text)"
    # 指向**目录**：Test-Path -PathType Leaf 必须挡掉，否则后面 `& $dir` 报的是另一种错
    $R2 = Invoke-InitKeys -ChildArgs @('-Stage', 'Primary', '-KeysDir', $d,
        '-Age', $d, '-AgeKeygen', $script:keygen)
    Chk '场景2 显式 -Age 指向目录 → BINARY_MISSING（不是「跑起来了但引擎怪」）' (
        (HasError $R2 'BINARY_MISSING') -and $R2.rc -eq 1) "rc=$($R2.rc) text=$($R2.text)"
    Chk '场景2 没找到引擎时一个字节都不落（目录里是空的）' (
        @(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) `
        "实得: $(@(Get-ChildItem -LiteralPath $d -Force | ForEach-Object { $_.Name }) -join ' ')"
}

if (Need-Engine '场景3 依赖定位优先级：显式 > 环境变量 > PATH') {
    # 把 PATH 掏空（Windows 上只留 System32，否则宿主自己起不来），只靠 BACKGUARD_AGE 那一档找引擎。
    # 这一发是 env 档唯一的实测口径：删掉 Find-Binary 读 env 的那三行，别的场景照样绿。
    $d = New-Dir 'envtier'
    $noPath = if ($script:isWin) { "$env:SystemRoot\System32" } else { $d }
    $R = Invoke-InitKeys -ChildArgs @('-Status', '-KeysDir', $d) -Env @{
        PATH = $noPath; BACKGUARD_AGE = $script:age; BACKGUARD_AGE_KEYGEN = $script:keygen }
    Chk '场景3 PATH 里没有 age、只有 BACKGUARD_AGE 时也认得引擎' (
        $R.rc -eq 0 -and -not (HasError $R 'BINARY_MISSING') -and
        (Contract $R 'begin mode=status stage=primary').Count -eq 1) "rc=$($R.rc) text=$($R.text)"
    # 显式参数必须**压过**环境变量：坏路径当场报，而不是「悄悄用了 env 里那个」
    $R2 = Invoke-InitKeys -ChildArgs @('-Status', '-KeysDir', $d,
        '-Age', (Join-Path $d 'no-such-age')) -Env @{
        PATH = $noPath; BACKGUARD_AGE = $script:age; BACKGUARD_AGE_KEYGEN = $script:keygen }
    Chk '场景3 显式 -Age 压过 BACKGUARD_AGE（坏路径当场 BINARY_MISSING）' (
        (HasError $R2 'BINARY_MISSING') -and $R2.rc -eq 1) "rc=$($R2.rc)"
}

if (Need-Engine '场景4 BAD_STAGE 与 -Stage 大小写') {
    $d = New-Dir 'badstage'
    $R = Invoke-InitKeys -ChildArgs @('-Stage', 'Nonsense', '-KeysDir', $d,
        '-Age', $script:age, '-AgeKeygen', $script:keygen)
    Chk '场景4 未知 -Stage → BAD_STAGE 且 rc=1' (
        (HasError $R 'BAD_STAGE') -and $R.rc -eq 1) "rc=$($R.rc) text=$($R.text)"
    # **不叫 `$r2`**：PowerShell 变量名不区分大小写，而 `if {}` 块**不开作用域**，`$r2` 与上面
    # 各场景的 `$R2` 是同一个脚本级变量——今天按顺序赋值没事，将来谁把两档调换一下就串味。
    $rUpper = Invoke-InitKeys -ChildArgs @('-Stage', 'PRIMARY', '-KeysDir', (New-Dir 'upper'),
        '-Age', $script:age, '-AgeKeygen', $script:keygen)
    Chk '场景4 -Stage 大小写不敏感（Primary/PRIMARY 都得认，写错档位不该撞死在闸门上）' (
        $rUpper.rc -eq 0 -and -not (HasError $rUpper 'BAD_STAGE')) "rc=$($rUpper.rc)"
}

$script:dirP = New-Dir 'primary'
$script:code = ''
if (Need-Engine '场景5 Primary 干净序列') {
    $R = Run-Primary $script:dirP
    $body = ContractBody $R
    Chk '场景5 Primary rc=0' ($R.rc -eq 0) "rc=$($R.rc) text=$($R.text)"
    Chk '场景5 首行是 begin（mode/stage/keysdir 三项齐，keysdir 是绝对路径）' (
        $body.Count -gt 0 -and $body[0].StartsWith('begin mode=run stage=primary keysdir=',
            [System.StringComparison]::Ordinal) -and
        $body[0].EndsWith($script:dirP, [System.StringComparison]::Ordinal)) "实得: $($body[0])"
    Chk '场景5 起手 state 行四项全 absent（初判读的是真实空目录）' (
        $body -contains 'state recipients=absent lines=0 enc=absent tmp=absent code=absent') `
        "实得: $(@($body | Where-Object { $_ -like 'state *' }) -join ' / ')"
    Chk '场景5 契约行顺序就是流程次序（两把公钥先取齐才落 recipients.txt）' (
        (Test-Order $body @('identity created=primary', 'identity created=recovery',
            'recipients lines=2', 'code written=recovery-code.txt groups=8',
            'verify kind=primary result=ok', 'verify kind=recovery result=ok',
            'done stage=primary rc=0'))) "实得: $($body -join ' | ')"
    Chk '场景5 末行是 done stage=primary rc=0（后面不再有任何契约行）' (
        $body.Count -gt 0 -and $body[-1] -eq 'done stage=primary rc=0') "末行: $($body[-1])"
    Chk '场景5 没有任何 ERROR 行' (@(Contract $R 'ERROR ').Count -eq 0) ''
    foreach ($n in @('identity.txt', '.recovery-identity.tmp', 'recipients.txt', 'recovery-code.txt')) {
        Chk "场景5 落盘 $n" (Test-Path -LiteralPath (Join-Path $script:dirP $n) -PathType Leaf) ''
    }
    Chk '场景5 recovery-identity.enc 还没生成（Primary 不经手 passphrase，也不该假装封过）' (
        -not (Test-Path -LiteralPath (Join-Path $script:dirP 'recovery-identity.enc'))) ''

    $script:code = Get-CodeText $script:dirP
    Chk '场景5 恢复码形状：8 组 4 位十六进制，组间连字符（抄写口径与 init-keys.exp 一致）' (
        "$script:code" -match '^[0-9a-f]{4}(-[0-9a-f]{4}){7}$') "实得: $script:code"
    Chk '场景5 恢复码是 128-bit 熵（32 个十六进制位，不是时间戳拼出来的）' (
        ("$script:code" -replace '-', '').Length -eq 32) ''
}

if (Need-Engine '场景6 默认 KeysDir 走 APPDATA') {
    $fake = New-Dir 'appdata'
    $R6 = Invoke-InitKeys -ChildArgs @('-Stage', 'Primary',
        '-Age', $script:age, '-AgeKeygen', $script:keygen) -Env @{ APPDATA = $fake }
    Chk '场景6 不给 -KeysDir 时落在 APPDATA 下（rc=0）' ($R6.rc -eq 0) "rc=$($R6.rc) text=$($R6.text)"
    $found = @(Get-ChildItem -LiteralPath $fake -Recurse -File -Force |
        Where-Object { $_.Name -eq 'recipients.txt' })
    Chk '场景6 找到的正是 semantic.ps1 要读的那个相对路径' (@($found).Count -eq 1) `
        "命中 $(@($found).Count): $(@($found) | ForEach-Object { $_.FullName } | Select-Object -First 2)"
    if (@($found).Count -eq 1) {
        # **实测结论（10-03 容器 pwsh 7.4.5，别拿「反斜杠在 POSIX 是合法文件名字符」的直觉当保证）**：
        # `Join-Path $APPDATA "PartiverseBackup\age"` 在 Linux 上**也把反斜杠规范化掉**了——
        # 量到 `joined=/tmp/xapp/PartiverseBackup/age`、`(New-Object IO.FileInfo($joined)).FullName`
        # 同值、落盘后 `ls` 只有一层 `PartiverseBackup`。也就是说两个宿主上默认 KeysDir 是**同一个形状**
        # （两层目录），语义层 `semantic.ps1:212` 那串拼接在两边指向同一个位置。
        # 所以断言按「父链逐层点名」写，而不是比相对路径字符串：字符串会跟着宿主分隔符变（这正是
        # 上一版断言假失败的原因——它把 `PartiverseBackup\age` 当成期望的相对路径，而产品产出的
        # 是 `PartiverseBackup/age`）。父链比的是形状，两个宿主同真。
        $leaf = $found[0]
        $pAge = $leaf.Directory
        $pBase = $pAge.Parent
        Chk '场景6 recipients.txt 的直接父目录名为 age' ($leaf.Name -eq 'recipients.txt' -and $pAge.Name -eq 'age') `
            "leaf=$($leaf.Name) parent=$($pAge.Name)"
        Chk '场景6 age 的上一层名为 PartiverseBackup（与 semantic.ps1 的相对段一致）' (
            $pBase.Name -eq 'PartiverseBackup') "grandparent=$($pBase.Name)"
        Chk '场景6 再上一层正是喂给子进程的 APPDATA（没有偷偷写到别处）' (
            (Resolve-Path -LiteralPath $pBase.Parent.FullName).Path -eq (Resolve-Path -LiteralPath $fake).Path) `
            "want=$fake got=$($pBase.Parent.FullName)"
    }
}

if (Need-Engine '场景7 recipients.txt 形状') {
    $rec = Join-Path $script:dirP 'recipients.txt'
    $bytes = [System.IO.File]::ReadAllBytes($rec)
    Chk '场景7 recipients.txt 没有 BOM（5.1 的 -Encoding utf8 写三个字节，age 按字节读就废了）' (
        -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) `
        "首三字节: $(($bytes | Select-Object -First 3 | ForEach-Object { $_ }) -join ',')"
    $recLines = @((Get-Content -LiteralPath $rec -ErrorAction SilentlyContinue |
        ForEach-Object { "$_".Trim() }) | Where-Object { $_ -ne '' })
    Chk '场景7 recipients.txt 恰好两行（它同时是「已初始化」的标记：一行＝只剩一条恢复路径而没人知道）' (
        $recLines.Count -eq 2) "实得 $($recLines.Count): $($recLines -join ' | ')"
    Chk '场景7 两行都是 age1X25519 公钥形' (@(
        $recLines | Where-Object { $_ -match '^age1[02-9ac-hj-np-z]{58,60}$' }).Count -eq 2) `
        "实得: $($recLines -join ' | ')"
    Chk '场景7 recipients.txt 里没有私钥（它是随时间轴上云的那一半）' (
        ("$(Get-Content -LiteralPath $rec -Raw)").ToUpper().IndexOf('AGE-SECRET-KEY') -lt 0) ''
    Chk '场景7 私钥只在 identity.txt 里（该在的地方得在，否则上一条测的是空气）' (
        ("$(Get-Content -LiteralPath (Join-Path $script:dirP 'identity.txt') -Raw)").
            ToUpper().Contains('AGE-SECRET-KEY')) ''
    $pk2 = @(Pubkey-Of (Join-Path $script:dirP '.recovery-identity.tmp'))
    Chk '场景7 第二行确是救援身份的公钥（现算，不靠记忆）' (
        $pk2.Count -eq 1 -and $recLines[1] -eq $pk2[0]) "第2行: $($recLines[1]) 现算: $(@($pk2) -join ' ')"
    Chk '场景7 两行不相同（同一把写两行＝只有一条恢复路径却看着像两条）' (
        $recLines[0] -ne $recLines[1]) ''
}

if (Need-Engine '场景8 外部闭环：recipients 封、两把身份分别解') {
    # 产品内部也做这一手，但 `verify kind=… result=ok` 只是它自己的话；这里夹具自己封、自己解、
    # 自己比内容——摘掉产品那一段时这条不受影响，摘掉 recipients 的写入时这条立刻红
    $probe = Join-Path $script:root 'probe-plain.txt'
    $plain = 'backguard/init-keys/e2e-probe'
    Set-Content -LiteralPath $probe -Value $plain -Encoding ascii -NoNewline
    $enc = Join-Path $script:root 'probe-external.enc'
    $ErrorActionPreference = 'Continue'
    $null = & $script:age -R (Join-Path $script:dirP 'recipients.txt') -o $enc $probe 2>&1
    Chk '场景8 用 recipients.txt 密封探针成功' ($LASTEXITCODE -eq 0 -and
        (Test-Path -LiteralPath $enc -PathType Leaf)) "rc=$LASTEXITCODE"
    foreach ($pair in @(@{ kind = 'primary'; f = 'identity.txt' },
                        @{ kind = 'recovery'; f = '.recovery-identity.tmp' })) {
        $back = Join-Path $script:root ('back-' + $pair.kind + '.txt')
        $null = & $script:age -d -i (Join-Path $script:dirP $pair.f) -o $back $enc 2>&1
        $rcx = $LASTEXITCODE
        $got = if (Test-Path -LiteralPath $back -PathType Leaf) {
            ("$(Get-Content -LiteralPath $back -Raw -ErrorAction SilentlyContinue)") } else { '' }
        Chk "场景8 $($pair.kind) 身份解得开且内容逐字一致" ($rcx -eq 0 -and $got -eq $plain) `
            "rc=$rcx got=$got"
        Remove-Item -LiteralPath $back -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $enc, $probe -Force -ErrorAction SilentlyContinue
}

if (Need-Engine '场景9 凭据面：恢复码同源、只显一次、不进契约行') {
    $d = New-Dir 'codeonce'
    $R = Run-Primary $d
    $code2 = Get-CodeText $d
    Chk '场景9 恢复码在整段子进程输出里只出现一次（抄两张才有意义）' (
        ([regex]::Matches($R.text, [regex]::Escape("$code2"))).Count -eq 1) `
        "实得 $(([regex]::Matches($R.text, [regex]::Escape("$code2"))).Count) 次"
    $contractOnly = @(Contract $R '') -join "`n"
    Chk '场景9 恢复码不进任何契约行（契约行会被拿去判据、会进日志）' (
        -not "$contractOnly".Contains("$code2")) "契约行: $contractOnly"
    Chk '场景9 显示的那一串与落盘的那一份同源（两处各生成一次＝纸上那张是废的）' (
        $R.text.Contains("$code2")) ''
}

if (Need-Engine '场景10 Primary 幂等重跑') {
    $before = ([System.IO.File]::ReadAllBytes((Join-Path $script:dirP 'identity.txt')) -join ',')
    $R = Run-Primary $script:dirP
    Chk '场景10 重跑 rc=0 且不报错误码' ($R.rc -eq 0 -and @(Contract $R 'ERROR ').Count -eq 0) `
        "rc=$($R.rc) text=$($R.text)"
    Chk '场景10 报的是 pending stage=rescue（enc 还没封而 tmp 还在）' (
        (Contract $R 'pending stage=rescue enc=absent tmp=present').Count -eq 1) `
        "实得: $(ContractBody $R -join ' | ')"
    $after = ([System.IO.File]::ReadAllBytes((Join-Path $script:dirP 'identity.txt')) -join ',')
    Chk '场景10 主身份字节没变（重建会让已上云的历史清单再也解不开）' ($before -eq $after) ''
    Chk '场景10 state 行如实报现场（recipients=present lines=2 / enc=absent / tmp=present）' (
        (Contract $R 'state recipients=present lines=2 enc=absent tmp=present code=present').Count -eq 1) `
        "实得: $(@($body = ContractBody $R; $body | Where-Object { $_ -like 'state *' }) -join ' | ')"
    Chk '场景10 幂等重跑不再显示恢复码（早退那一档不重复打印）' (
        -not $R.text.Contains($script:code)) ''
}

if (Need-Engine '场景11 HALF_STATE（半成品不猜、不删）') {
    $d = New-Dir 'half'
    $null = & $script:keygen -o (Join-Path $d 'identity.txt') 2>&1
    Chk '场景11 夹具先造出 identity.txt' (
        Test-Path -LiteralPath (Join-Path $d 'identity.txt') -PathType Leaf) "rc=$LASTEXITCODE"
    # 取**字节**不取「在不在」：m08 那一刀（HALF_STATE 改成静默删掉 identity.txt 再走正常流程）
    # 只比存在性时照样「ok」——文件在，只是换了一把私钥，而已上云的历史清单从此解不开。
    # 「路径不变、内容被换」这一类坏法上，存在性是弱判据，字节才是判据。
    $idPath = Join-Path $d 'identity.txt'
    $idBytesBefore = ([System.IO.File]::ReadAllBytes($idPath) -join ',')
    $R = Run-Primary $d
    Chk '场景11 报 HALF_STATE 且 rc=1（不猜「该接着用还是该重来」）' (
        (HasError $R 'HALF_STATE') -and $R.rc -eq 1) "rc=$($R.rc) text=$($R.text)"
    Chk '场景11 identity.txt 还在**且是原来那一把**（静默删除再重建＝私钥换了而路径没变，只测存在性抓不到）' (
        (Test-Path -LiteralPath $idPath -PathType Leaf) -and
        (([System.IO.File]::ReadAllBytes($idPath) -join ',') -eq $idBytesBefore)) ''
    Chk '场景11 没顺手补出 recipients.txt（补出来就等于把半成品冒充成已初始化）' (
        -not (Test-Path -LiteralPath (Join-Path $d 'recipients.txt'))) ''
}

if (Need-Engine '场景12 RECIPIENTS_SHAPE（两行不变量，两档都判）') {
    $d = New-Dir 'shape'
    $null = & $script:keygen -o (Join-Path $d 'identity.txt') 2>&1
    $k1 = @(Pubkey-Of (Join-Path $d 'identity.txt'))
    ("$($k1[0])`r`n") | Out-File -FilePath (Join-Path $d 'recipients.txt') -Encoding ascii
    $Rp = Run-Primary $d
    Chk '场景12 Primary 撞到单行 recipients → RECIPIENTS_SHAPE 且 rc=1' (
        (HasError $Rp 'RECIPIENTS_SHAPE') -and $Rp.rc -eq 1) "rc=$($Rp.rc) text=$($Rp.text)"
    $Rr = Run-Rescue $d
    Chk '场景12 Rescue 也判同一件事（不许只有一档知道）' (
        (HasError $Rr 'RECIPIENTS_SHAPE') -and $Rr.rc -eq 1) "rc=$($Rr.rc) text=$($Rr.text)"
    Chk '场景12 state 行带现场数字 lines=1（只报码不报数，读的人无从判断）' (
        (Contract $Rr 'state recipients=present lines=1').Count -eq 1) "实得: $(ContractBody $Rr -join ' | ')"
}

if (Need-Engine '场景13 RECOVERY_LOST（recipients 在、enc 与 tmp 都不在）') {
    $d = New-Dir 'lost'
    $null = & $script:keygen -o (Join-Path $d 'identity.txt') 2>&1
    $other = Join-Path $script:root 'other-id.tmp'
    $null = & $script:keygen -o $other 2>&1
    $k1 = @(Pubkey-Of (Join-Path $d 'identity.txt')); $k2 = @(Pubkey-Of $other)
    # 两行都是合法公钥，但第二行那把的**私钥**不在现场（另一处、已删）——这正是「报成已初始化
    # 就把人骗到干净机器上才发现读不了」的那种现场
    ("$($k1[0])`r`n$($k2[0])`r`n") | Out-File -FilePath (Join-Path $d 'recipients.txt') -Encoding ascii
    Remove-Item -LiteralPath $other -Force -ErrorAction SilentlyContinue
    $Rp = Run-Primary $d
    Chk '场景13 Primary 报 RECOVERY_LOST 而不是「已初始化」' (
        (HasError $Rp 'RECOVERY_LOST') -and $Rp.rc -eq 1) "rc=$($Rp.rc) text=$($Rp.text)"
    Chk '场景13 Rescue 报 RECOVERY_LOST（明文临时身份没了，恢复码无从封存）' (
        (HasError (Run-Rescue $d) 'RECOVERY_LOST')) ''
    Chk '场景13 state 行是 enc=absent tmp=absent（判据的现场依据）' (
        (Contract $Rp 'state recipients=present lines=2 enc=absent tmp=absent').Count -eq 1) `
        "实得: $(ContractBody $Rp -join ' | ')"
}

if (Need-Engine '场景14 NOT_INITIALIZED') {
    $d = New-Dir 'notinit'
    $R = Run-Rescue $d
    Chk '场景14 Rescue 撞空目录 → NOT_INITIALIZED 且 rc=1' (
        (HasError $R 'NOT_INITIALIZED') -and $R.rc -eq 1) "rc=$($R.rc) text=$($R.text)"
    Chk '场景14 没在空目录里造任何东西' (@(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) ''
}

if (Need-Engine '场景15 Rescue 无终端时拒封而不是硬封') {
    # CI 与 windows runner 上真跑的就是这一档：age 的 passphrase 只认 tty，喂不了就不封，
    # 而且**不许把临时身份顺手清掉**——清掉之后这就变成 RECOVERY_LOST，是人造出来的丢密钥
    $d = New-Dir 'noconsole'
    $setup = Run-Primary $d
    Chk '场景15 夹具前置 Primary 成功' ($setup.rc -eq 0) "rc=$($setup.rc) text=$($setup.text)"
    $R = Run-Rescue $d
    Chk '场景15 打 no-console stage=rescue 且 rc=1' (
        (Contract $R 'no-console stage=rescue').Count -eq 1 -and $R.rc -eq 1) "rc=$($R.rc) text=$($R.text)"
    Chk '场景15 这不是一条错误码（旁路知道自己缺什么：报的是「这一步要人」，不是 ERROR）' (
        @(Contract $R 'ERROR ').Count -eq 0) ''
    Chk '场景15 recovery-identity.enc 没被造出来（喂不了口令就不封）' (
        -not (Test-Path -LiteralPath (Join-Path $d 'recovery-identity.enc'))) ''
    Chk '场景15 明文临时身份还在（拒封不许没收重试的资格）' (
        Test-Path -LiteralPath (Join-Path $d '.recovery-identity.tmp') -PathType Leaf) ''
    Chk '场景15 -Status 在这一档报 complete=0（enc 不在就是没完成，不数 tmp）' (
        (Contract (Run-Status $d) 'status complete=0 verify=not-checked').Count -eq 1) ''
}

if (Need-Engine '场景20 -Status 三态且只数文件') {
    $d1 = Join-Path $script:root ('status-absent-' + [guid]::NewGuid().ToString('N'))
    $R1 = Run-Status $d1
    Chk '场景20 目录不存在 → status dir=absent complete=0 且 rc=0' (
        (Contract $R1 'status dir=absent complete=0').Count -eq 1 -and $R1.rc -eq 0) `
        "rc=$($R1.rc) text=$($R1.text)"
    Chk '场景20 -Status 不把目录建出来（它是要被脚本调的那一档，不许有副作用）' (
        -not (Test-Path -LiteralPath $d1)) ''
    Chk '场景20 只有 Primary 跑过 → complete=0（enc 还没封）' (
        (Contract (Run-Status $script:dirP) 'status complete=0 verify=not-checked').Count -eq 1) ''
    # 造一份「文件齐」的现场：直接把明文身份**复制**成 enc——这同时证的是 -Status 真的只数文件
    # （这份 enc 根本不是 passphrase 件，它照样报 complete=1，而「能不能解开」由 Rescue 档重验）
    $d2 = New-Dir 'statusdone'
    [void](Run-Primary $d2)
    Copy-Item -LiteralPath (Join-Path $d2 '.recovery-identity.tmp') `
        -Destination (Join-Path $d2 'recovery-identity.enc') -Force
    $R2 = Run-Status $d2
    Chk '场景20 文件齐 → complete=1（-Status 不开任何加密件，这是设计不是漏洞）' (
        (Contract $R2 'status complete=1 verify=not-checked').Count -eq 1) "实得: $(ContractBody $R2 -join ' | ')"
    Chk '场景20 status 行一律带 verify=（「文件齐」与「恢复码解得开」必须写在同一行里分开）' (
        @( @(Contract $R2 'status ') | Where-Object { $_ -notmatch 'verify=' }).Count -eq 0) ''
}

if (Need-Engine '场景21 契约行含非 ASCII 时自打告警') {
    $cn = Join-Path $script:root ('中文目录-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [void][System.IO.Directory]::CreateDirectory($cn)
    $R = Run-Primary $cn
    Chk '场景21 中文 KeysDir 进 begin 行时当场自警' (
        (Contract $R 'WARN contract-line-has-non-ascii').Count -ge 1) "text=$($R.text)"
    Chk '场景21 自警不影响流程（该 done 还是 done；旁路不给自己判死）' ($R.rc -eq 0) "rc=$($R.rc)"
}

if (Need-Engine '场景22 权限面分支') {
    $d = New-Dir 'perms'
    $R = Run-Primary $d
    $permLines = @( @(Contract $R 'perms ') | ForEach-Object { $_.Substring($script:Cp.Length) })
    if ($script:isWin) {
        Chk '场景22 Windows 上走 applied 分支' ($permLines -contains 'perms applied sid-taken=1') `
            "实得: $($permLines -join ' | ')"
        try {
            $acl = Get-Acl -LiteralPath $d
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $allows = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' })
            Chk '场景22 密钥目录的 DACL 只剩当前用户（关继承 + 单条授权；目录先收紧再落盘）' (
                [bool]$acl.AreAccessRulesProtected -and $allows.Count -ge 1 -and
                @($allows | Where-Object { "$($_.IdentityReference.Value)" -ne $sid }).Count -eq 0) `
                "protected=$($acl.AreAccessRulesProtected) allows=$(@($allows | ForEach-Object { "$($_.IdentityReference.Value)" }) -join ',')"
        } catch {
            Chk '场景22 读 DACL 不该抛（读不到就如实报，别静默绿）' $false "异常: $($_.Exception.Message)"
        }
    } else {
        Chk '场景22 非 Windows 宿主如实打 skipped=no-icacls（不假装收紧过）' (
            $permLines -contains 'perms skipped=no-icacls') "实得: $($permLines -join ' | ')"
    }
    Chk '场景22 权限面那一发不判死（icacls 失败只告警，密钥还得能用）' ($R.rc -eq 0) "rc=$($R.rc)"
}

# ---------------- pty 段（有 expect 才跑）----------------
if (Need-Pty '场景23 Rescue 真封存（pty）') {
    $d = New-Dir 'ptyseal'
    $setup = Run-Primary $d
    Chk '场景23 夹具前置 Primary 成功' ($setup.rc -eq 0) "rc=$($setup.rc) text=$($setup.text)"
    $R = Run-Pty -Dir $d
    $body = ContractBody $R
    Chk '场景23 真终端里 Rescue rc=0' ($R.rc -eq 0) "rc=$($R.rc) text=$($R.text)"
    Chk '场景23 sealed → verify-rescue → tmp removed → done 四行按序' (
        (Test-Order $body @('sealed enc=recovery-identity.enc', 'verify-rescue pubkey=match',
            'tmp removed=1', 'done stage=rescue rc=0'))) "实得: $($body -join ' | ')"
    Chk '场景23 明文临时身份已删（封好了就不该再留一份无口令的）' (
        -not (Test-Path -LiteralPath (Join-Path $d '.recovery-identity.tmp'))) ''
    # 守卫在脚本之外独立解一次：拿 recovery-code.txt 那串喂给 age，解出来的身份取公钥、对册
    $outId = Join-Path $script:root 'pty-outside-id.txt'
    # **别把这个结果写回 $d**：PowerShell 的变量名不区分大小写，`$D = …` 会把目录路径覆盖成
    # 结果 hashtable，之后 `Join-Path $d 'recipients.txt'` 报的是
    # `Cannot find path 'System.Collections.Hashtable/recipients.txt'`——守卫自己把被测面换了。
    $rescueOut = Run-Pty -Dir $d -Target 'age' -Out $outId `
        -Enc (Join-Path $d 'recovery-identity.enc')
    Chk '场景23 恢复码在脚本之外也解得开（这条证的是「那张纸真能救」，不是自报）' (
        $rescueOut.rc -eq 0 -and (Test-Path -LiteralPath $outId -PathType Leaf)) "rc=$($rescueOut.rc)"
    if (Test-Path -LiteralPath $outId -PathType Leaf) {
        $pk = @(Pubkey-Of $outId)
        $recLines = @((Get-Content -LiteralPath (Join-Path $d 'recipients.txt') |
            ForEach-Object { "$_".Trim() }) | Where-Object { $_ -ne '' })
        Chk '场景23 解出来的正是 recipients 里登记的那一把救援公钥' (
            $pk.Count -eq 1 -and @($recLines | Where-Object { $_ -eq $pk[0] }).Count -eq 1) `
            "解出: $(@($pk) -join ' ') 在册: $($recLines -join ',')"
        Remove-Item -LiteralPath $outId -Force -ErrorAction SilentlyContinue
    }
}

if (Need-Pty '场景24 Rescue 重入只重验不重封（pty）') {
    $d = New-Dir 'ptyagain'
    [void](Run-Primary $d)
    $first = Run-Pty -Dir $d
    Chk '场景24 前置：首次封存成功' ($first.rc -eq 0) "rc=$($first.rc) text=$($first.text)"
    $enc = Join-Path $d 'recovery-identity.enc'
    $hashBefore = (Get-FileHash -LiteralPath $enc -Algorithm SHA256).Hash
    $again = Run-Pty -Dir $d
    Chk '场景24 重入 rc=0 且报 verify-rescue pubkey=match stage=rescue' (
        $again.rc -eq 0 -and @(Contract $again 'verify-rescue pubkey=match stage=rescue').Count -eq 1) `
        "rc=$($again.rc) text=$($again.text)"
    Chk '场景24 重入不再打 sealed（重封一次就是给同一把私钥换一层口令）' (
        @(Contract $again 'sealed ').Count -eq 0) "实得: $(ContractBody $again -join ' | ')"
    Chk '场景24 enc 字节没变（重验与重封必须分得开）' (
        (Get-FileHash -LiteralPath $enc -Algorithm SHA256).Hash -eq $hashBefore) ''
}

if (Need-Pty '场景25 Primary 重入撞已封存的件：没终端时如实打 verify=deferred') {
    $d = New-Dir 'ptydefer'
    [void](Run-Primary $d)
    [void](Run-Pty -Dir $d)
    $R = Run-Primary $d
    Chk '场景25 非交互重入 Primary rc=0 且 verify=deferred（既不证成也不证败，同 A6 的 UNKNOWN 口径）' (
        $R.rc -eq 0 -and (Contract $R 'exists action=none enc=present verify=deferred stage=primary').Count -eq 1) `
        "rc=$($R.rc) text=$($R.text)"
    Chk '场景25 早退那一档一个字节都不写（不再打 recipients lines=2）' (
        @(Contract $R 'recipients lines=2').Count -eq 0) "实得: $(ContractBody $R -join ' | ')"
    Chk '场景25 也**不许**在这条路上打 verify-rescue（没终端就没有「验过」这回事）' (
        @(Contract $R 'verify-rescue ').Count -eq 0) ''
}

if (Need-Pty '场景26 空回车 autogenerate 陷阱') {
    # age 提示原文 `Enter passphrase (leave empty to autogenerate a secure one)`：按空回车 =
    # 封进一个谁都没见过的随机口令，`age -p` 退出 0、.enc 照样落盘。抓不住这一手，那张纸就是废纸。
    $d = New-Dir 'ptyempty'
    [void](Run-Primary $d)
    $R = Run-Pty -Dir $d -Reply 'empty'
    Chk '场景26 假封那一次绝不许报 done stage=rescue rc=0' (
        -not ((ContractBody $R) -contains 'done stage=rescue rc=0')) "实得: $(ContractBody $R -join ' | ')"
    Chk '场景26 判 VERIFY_PASSPHRASE_FAILED 且 rc=1' (
        (HasError $R 'VERIFY_PASSPHRASE_FAILED') -and $R.rc -eq 1) "rc=$($R.rc) text=$($R.text)"
    Chk '场景26 明文临时身份保留（重试的资格不能被一次误封没收）' (
        Test-Path -LiteralPath (Join-Path $d '.recovery-identity.tmp') -PathType Leaf) ''
    Chk '场景26 那份错封的 enc 还在原地（报错要指到具体文件，别顺手删证据）' (
        Test-Path -LiteralPath (Join-Path $d 'recovery-identity.enc') -PathType Leaf) ''
    Remove-Item -LiteralPath (Join-Path $d 'recovery-identity.enc') -Force -ErrorAction SilentlyContinue
    $ok = Run-Pty -Dir $d
    Chk '场景26 按报错提示删掉错封件后，拿正确恢复码重跑能真封上' (
        $ok.rc -eq 0 -and ((ContractBody $ok) -contains 'done stage=rescue rc=0')) `
        "rc=$($ok.rc) text=$($ok.text)"
}

if (Need-Pty '场景27 错封件不删就直接重入：必须 RECOVERY_UNUSABLE') {
    $d = New-Dir 'ptyunusable'
    [void](Run-Primary $d)
    $bad = Run-Pty -Dir $d -Reply 'empty'
    Chk '场景27 前置：空回车确实封出了一份 enc' (
        Test-Path -LiteralPath (Join-Path $d 'recovery-identity.enc') -PathType Leaf) "rc=$($bad.rc)"
    $retry = Run-Pty -Dir $d
    Chk '场景27 用正确码重入撞 RECOVERY_UNUSABLE（错封件不会被认成已完成）' (
        (HasError $retry 'RECOVERY_UNUSABLE') -and $retry.rc -eq 1) "rc=$($retry.rc) text=$($retry.text)"
    Chk '场景27 报错给的是「删掉它重跑」而不是「已封存就完事了」' (
        $retry.text.Contains('RECOVERY_UNUSABLE') -and $retry.text.Contains('重跑')) ''
    Chk '场景27 重验解出来的临时件用完即删（.verify-rec-id 不残留）' (
        -not (Test-Path -LiteralPath (Join-Path $d '.verify-rec-id'))) ''
}

if (Need-Pty '场景28 封存假成功（退出 0 却不落件）→ SEAL_FAILED') {
    if ($script:isWin) {
        Skip '场景28 封存假成功（退出 0 却不落件）→ SEAL_FAILED' '桩是一支 sh 脚本，Windows 宿主跑不了'
    } else {
        # 「engine 退出 0」在这条 remote 上什么都没证明（AGENTS §2 那条 rclone 教训的引擎版）：
        # 判据必须同时看「件真的落盘了」。这一发把 age 换成一支 exit 0 的空壳。
        $stub = Join-Path $script:root 'age-stub.sh'
        "#!/bin/sh`nexit 0`n" | Out-File -FilePath $stub -Encoding ascii
        $ErrorActionPreference = 'Continue'
        $null = & /bin/chmod +x $stub 2>&1
        $d = New-Dir 'sealstub'
        [void](Run-Primary $d)
        $R = Run-Pty -Dir $d -AgeBin $stub
        Chk '场景28 判 SEAL_FAILED 且 rc=1（只看退出码就会报成封存成功）' (
            (HasError $R 'SEAL_FAILED') -and $R.rc -eq 1) "rc=$($R.rc) text=$($R.text)"
        Chk '场景28 绝不打 sealed（落笔前必须见过那个文件）' (
            @(Contract $R 'sealed ').Count -eq 0) "实得: $(ContractBody $R -join ' | ')"
        Chk '场景28 明文临时身份保留' (
            Test-Path -LiteralPath (Join-Path $d '.recovery-identity.tmp') -PathType Leaf) ''
        Remove-Item -LiteralPath $stub -Force -ErrorAction SilentlyContinue
    }
}

# ---------------- 收尾：清扫 + 静态 + 接线 ----------------
if (Need-Engine '场景29 夹具清扫') {
    # 每个 recovery-code.txt 的值都不许出现在**别的**文件里（契约行、transcript、日志、探针）
    $codeFiles = @(Get-ChildItem -LiteralPath $script:root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'recovery-code.txt' })
    Chk '场景29 夹具里有恢复码文件可扫（空清单＝上面那批场景整段没跑，这条也就没测到东西）' (
        $codeFiles.Count -ge 3) "实得 $($codeFiles.Count) 份"
    $others = @(Get-ChildItem -LiteralPath $script:root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'recovery-code.txt' -and $_.Length -lt 400KB })
    $hits = @()
    foreach ($cf in $codeFiles) {
        $cv = ("$(Get-Content -LiteralPath $cf.FullName -Raw -ErrorAction SilentlyContinue)").Trim()
        if ("$cv".Length -lt 8) { continue }
        foreach ($f in $others) {
            $t = ''
            try { $t = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
            if ($t.Contains($cv)) { $hits = @($hits) + ($cf.Name + ' <- ' + $f.FullName) }
        }
    }
    Chk '场景29 恢复码只留在 recovery-code.txt 里（其余文件一个字节都不许有）' (@($hits).Count -eq 0) `
        "命中: $(@($hits) | Select-Object -First 3 | Out-String)"
    Chk '场景29 pty transcript 用完即删（它里面可能有 age 提示的回显）' (
        @(Get-ChildItem -LiteralPath $script:root -File -Force |
            Where-Object { $_.Name -like 'pty-*.log' }).Count -eq 0) ''
    Chk '场景29 没有 .verify-rec-id 残留（重验解出来的私钥用完即删）' (
        @(Get-ChildItem -LiteralPath $script:root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq '.verify-rec-id' }).Count -eq 0) ''
}

$src = Get-Content -Raw -LiteralPath $script:initKeysPs
$toks = $null; $errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($script:initKeysPs, [ref]$toks, [ref]$errs)
Chk '场景30 init-keys.ps1 在本宿主解析 0 错误（语法面；5.1 那一步的主判据之一）' (
    @($errs).Count -eq 0) "实得 $(@($errs).Count) 条: $(@($errs) | ForEach-Object { $_.Message } | Select-Object -First 2)"
# 静态判据读**去掉整行注释后的源码**，不读 AST 令牌。AST 那条路在本宿主实测走不通（10-03 容器
# pwsh 7.4.5）：类型字面量 `[System.Management.Automation.Language.CommentToken]` 解析不了
# （`Unable to find type`），拿它做 `-isnot` 过滤的结果是**一条注释都没滤掉**（量到 comments=0），
# 于是产品文件自己的注释「不是 `Get-Random`」被判成了违规；而令牌 `Text` 拼接出来的串里连
# `.GetBytes(` 的点号都不在（member 调用的 `.` 不是独立令牌，量到 hasGB=False），拿它判实例方法
# 等于判一条恒假式。行级剥离不如 AST 严（行尾注释里的违禁词仍会误判），但误判方向是**判红**：
# 只会让合规脚本变红让人去看，不会替违规脚本放行。产品里 `Get-Random` / `Fill()` 两处确实只在
# 整行注释里（grep 核对过），所以这一版判据在两个宿主上都站得住。
function Strip-CommentLines([string]$Text) {
    $keep = @()
    $inBlock = $false
    foreach ($line in ($Text -split "`r?`n")) {
        $t = "$line".TrimStart()
        if ($inBlock) {
            if ($t.Contains('#>')) { $inBlock = $false }
            continue
        }
        if ($t.StartsWith('<#')) {
            if (-not $t.Contains('#>')) { $inBlock = $true }
            continue
        }
        if ($t.StartsWith('#')) { continue }
        $keep += $line
    }
    ($keep -join "`n")
}
$codeSrc = Strip-CommentLines $src
Chk '场景30 静态判据真的滤掉了注释（拿产品自己那句「不是 Get-Random」当探针；没滤掉就是判据自己是死的）' (
    -not ($codeSrc -match 'Get-Random') -and ($src -match 'Get-Random')) ''
Chk '场景30 熵源是 RandomNumberGenerator（Get-Random 是弱随机且 5.1/7 实现不同）' (
    $codeSrc.Contains('RandomNumberGenerator') -and -not ($codeSrc -match 'Get-Random')) ''
Chk '场景30 用实例 GetBytes 而不是静态 Fill（Fill 只在 .NET Core 上有，5.1 当场炸）' (
    ($codeSrc -match '\.GetBytes\(') -and -not ($codeSrc -match 'RandomNumberGenerator\]::Fill')) ''
Chk '场景30 身份/恢复码文件走 ascii 不写 utf8（5.1 的 utf8 带 BOM，age 按字节读 recipients.txt）' (
    ($codeSrc -match '-Encoding\s+ascii') -and -not ($codeSrc -match 'Out-File[^\r\n]*-Encoding\s+utf8')) ''
Chk '场景30 不经手口令：没有 Read-Host / SecureString（口令只由 age 向终端索取）' (
    -not ($codeSrc -match 'Read-Host|SecureString')) ''
$exitLines = @($src -split "`n" | Where-Object { $_ -match '^\s*exit\b' })
Chk '场景30 全脚本只有一个顶层 exit（函数内 exit 在 pwsh 7 上不跑 finally，明文临时身份就漏了）' (
    $exitLines.Count -eq 1 -and "$($exitLines[0])".Trim() -eq 'exit $Rc') "实得: $($exitLines -join ' / ')"
Chk '场景30 Fail 用 throw 不用 exit' ($src.Contains('throw "initkeys-abort"')) ''

$probePs = Join-Path $Repo 'probe_windows_ps51.ps1'
$probeSrc = if (Test-Path -LiteralPath $probePs -PathType Leaf) { Get-Content -Raw $probePs } else { '' }
Chk '场景31 探针文件在仓库里（不在就等于 EAP 那条规则没跑，不许静默绿）' (
    "$probeSrc".Length -gt 0) $probePs
$eapLine = @($probeSrc -split "`n" | Where-Object { $_ -match '^\$eapFiles\s*=' } | Select-Object -First 1)
Chk '场景31 探针的 EAP 文件清单里有 init-keys.ps1' (
    @($eapLine).Count -eq 1 -and "$($eapLine[0])".IndexOf('init-keys.ps1',
        [System.StringComparison]::Ordinal) -ge 0) "实得: $(($eapLine | Out-String).Trim())"
$semSrc = ''
$semPs = Join-Path $Repo 'semantic/semantic.ps1'
if (Test-Path -LiteralPath $semPs -PathType Leaf) { $semSrc = Get-Content -Raw $semPs }
Chk '场景31 semantic.ps1 读的 recipients.txt 就是 init-keys.ps1 写的那个相对路径' (
    $semSrc.Contains('PartiverseBackup\age\recipients.txt') -and
    $src.Contains('Join-Path $env:APPDATA "PartiverseBackup\age"')) `
    "semantic 命中: $($semSrc.Contains('PartiverseBackup\age\recipients.txt')) / init-keys 命中: $($src.Contains('Join-Path $env:APPDATA "PartiverseBackup\age"'))"

Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail -gt 0) {
    Write-Host "INITKEYS-E2E-FAIL count=$script:fail skipped=$(@($script:skipped).Count)"
    exit 1
}
Write-Host "INITKEYS-E2E-OK skipped=$(@($script:skipped).Count)"
