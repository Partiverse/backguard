# test_rescue_e2e.ps1 —— rescue.ps1 逃生恢复的端到端守卫（真 restic + 真 age，隔离临时目录）
#
# 怎么跑：
#   容器（本机无 pwsh，仓库根挂 /repo；镜像里要装 restic + age）：
#     docker run --rm -v "$PWD":/repo:ro --entrypoint /bin/bash backguard-native:deps \
#       -c 'pwsh -NoProfile -File /repo/test_rescue_e2e.ps1 -Repo /repo'
#   （`-c` 那一层不能省：`--entrypoint /bin/bash` 后面的裸 `pwsh` 会被 bash 当**脚本文件**去找，
#     找到 /usr/bin/pwsh 这个二进制后再当 shell 脚本执行，得到 `cannot execute binary file` rc=126。）
#   **镜像必须是宿主原生架构**（arm64 = ubuntu:24.04 + apt restic + pwsh/age 的 linux-arm64
#   tarball）。mcr 的 `powershell:lts` 只出 amd64 与 arm/v7，Apple Silicon 上拉到的是 arm/v7，
#   跑在 qemu 的 TCG 下会在随机一条原生命令处炸 `Assertion failed: (dc->base.pc_next & 1) == 0
#   (target/arm/tcg/translate.c)`——那是模拟器的，不是被测实现的。
#   windows job：CI 直接 `& "$PWD\test_rescue_e2e.ps1"`（pwsh 7 一步 + 5.1 一步）。
# 期望最后一行 `RESCUE-E2E-OK skipped=N`。**看到 OK 还要看 skipped 那一个数**：restic/age
# 不在 PATH 时真引擎那几段整段 Skip——「没证据」不等于「通过」（口径同 test_perms_logic.ps1）。
#
# 为什么每一步都是**子进程**跑 rescue.ps1 而不是 dot-source：逃生工具的契约之一就是
# 「独立文件、独立进程、只吃命令行」，而 -Get 那条链路要的正是「把 -Find 打出来的那串路径
# 原样喂回去」——dot-source 在同一个 runspace 里做这件事，argv 引号面（`[01]`、空格）与
# 控制台编码面全都测不到。子进程那一份的 stdout 按行读，判据只认 ASCII 契约行
# （`rescue: <事实>`），中文人读行一律不作断言（cp1252 会把中文打成 ?，见 rescue.ps1 文件头）。
#
# 覆盖（24 条）：
#   ①-Guide / 无动作 / 备份根不存在三种出口的退出码与错误码
#   ②两种仓库布局（本地 restic-<cls> 与云端 <cls>）+ borg 仓库明确说「去用 rescue.sh」
#   ③没有 restic 时 -List 仍然给时间轴那一半（旁路降级不给整条判死）
#   ④引擎读不出（口令错）与「无匹配」分开说：前者必须非零 + engine-fail，不许被说成 hits=0
#   ⑤字面量匹配（`[01]` 不是正则）+ 从 -Find 输出原样往返到 -Get
#   ⑥取回落进**本次创建的**暂存目录里数文件：-To 里原有的诱饵文件不许冒充「取回了」
#   ⑦-Archive 指历史快照取回的内容真的是历史那份（跨归档错配在这里当场露）+ 不存在的 ID 报错
#   ⑧账本路径 A（真 age 解封）：条目/过滤/格式告警/restore= 字段直接喂 -Get 走得通
#   ⑨缺恢复材料 / 主身份不配对 / 快照未密封 / 时间轴两种旧形与认不出
#   ⑩路径 B 的调用序列与凭据面由桩钉（age 对 passphrase 只读终端，CI 打不了字，交互那一步
#     测不到——桩证的是「两步调用 + argv 里没有口令 + 解出来的私钥用完即删」）
#   ⑪隐私面收尾清扫：整棵夹具里不许留下明文 manifest.json，也不许留下 RESTIC_PASSWORD 的值
#
# **不覆盖**（如实登记，别当 Windows 真机）：
#   - 路径 B 的**交互提示**本身（真 age 在 CI 里等不到人打字）；
#   - 非 ASCII 文件名的 argv 往返（跨控制台代码页把中文 argv 往返验的是运气；夹具用 `[01]` 与
#     空格这类 ASCII 元字符，中文只在人读行里出现，不作断言）；
#   - Windows 上 restic 仓库内路径的分隔符形状——这条不靠猜：-Find → -Get 的往返就是它的判据，
#     两种宿主各自跑自己那一份，红了看得见（容器是 /，runner 上是 restic 在 Windows 打出的形）。
#
# 变异台账（2026-10-02，容器 `backguard-native:deps` = ubuntu:24.04 arm64 + pwsh 7.4.5 + restic +
# age，宿主原生架构——amd64/arm/v7 走 qemu 会 `rc=139` TCG 崩，那是环境不是判决）。判定口径同
# bash 侧：驱动先 `grep` 确认变异落上，再跑整份夹具，看首条 FAIL 是否就是这一刀主张的那件事。
# 前 15 刀全部咬住（count= 这一轮 FAIL 总数），m16 如实记为 ESCAPED 并写明它是冗余实现：
#   m01 类别不归一小写                 BITTEN count=2  首条=场景14 `-Class Files` 归一后照常工作
#   m02 快照列表返回裸数组（摊平）     BITTEN count=34  首条=场景3 认出本地布局与 2 个快照
#       ——1 个元素出来是字符串，`$ids[-1]` 取到 ID 最后一个字符；空数组出来是 $null，空仓库冒充引擎失败
#   m03 空仓库不报 NO_ARCHIVE          BITTEN count=1  首条=场景20 空仓库报 NO_ARCHIVE
#   m04 字面量匹配换成正则             BITTEN count=2  首条=场景9 字面量命中 1 条（`[01]` 被当字符类）
#   m05 restore 恒用 path（raw 失效）  BITTEN count=2  首条=场景15 有 raw 时取回路径用 raw
#   m06 契约行非 ASCII 自警摘掉        BITTEN count=1  首条=场景23 契约行含非 ASCII 时自打告警
#   m07 旧形时间轴（带设备层）不认     BITTEN count=3  首条=场景19 -List 认得旧形
#   m08 云端布局 <base>/<cls> 不认     BITTEN count=2  首条=场景4 云端布局 layout=cloud
#   m09 borg 仓库不再识别              BITTEN count=2  首条=场景6 -List 认出 borg 并标注不支持
#   m10 取回计数改成数 -To 全部内容    BITTEN count=1  首条=场景10 诱饵文件不算取回
#   m11 引擎失败当成「读到了但没快照」 BITTEN count=3  首条=场景7 报的是 ENGINE_UNREADABLE
#   m12 -List 不逐条输出快照 ID        BITTEN count=5  首条=场景3 逐快照 ID 行 = 3 条 实得 0
#   m13 -Last 5 改成 -Last 1           BITTEN count=1  首条=场景3 两个快照目录都列出
#   m14 主身份缺失不单独报码           BITTEN count=1  首条=场景17 报 IDENTITY_MISSING
#   m15 WORK 清扫白名单守卫写歪        BITTEN count=1  首条=场景22 临时工作目录用完删掉
#       ——首跑驱动把逐刀日志写进容器内 `/tmp/mutlog`，容器退出即失，于是这刀被记成 ESCAPED；
#         单独重跑、日志挂到宿主目录后才看见它其实咬住（38 个 `bg-rescue-*` 残留）。
#         教训：**变异驱动的每刀日志必须落在挂载进容器的宿主目录**，否则「没证据」会长得
#         和「没咬住」一模一样。
#   m16 调用点 `$ids = @($snap.ids)` 的 @() 摘掉  ESCAPED（suite_rc=0 / 97 条 ok / skipped=0，
#       变异按行号落上并回读验过 landed=True、rewrote-line=331）——**这不是死断言，是冗余实现**：
#       摊平只发生在**函数返回**那道边界（m02 摘的就是那里，34 条一起红），而 hashtable 的
#       **属性访问不摊平**，`$snap.ids` 出来本来就是数组。所以挡住「最后一个字符」的是
#       「返回对象」这一手，调用点的 `@()` 只是保险，**别把它当成被测面去信赖**。
#       （这一刀第一次跑时驱动被 docker 的「单文件挂进已挂载目录」套娃搞成 0 字节，于是跑了
#        一份**没变异**的夹具而得出 rc=0——落地校验 `landed=True` 就是为这种时刻写的。）
#   另有两刀的** catching 方是 probe_windows_ps51.ps1 事实 5，不是这份夹具**，记在这里因为
#   被测面是 rescue.ps1 的 EAP 纪律：
#     m17 把探针取变量名的 `$e0.VariablePath.UserPath` 改回 `$e0.UserPath`  BITTEN probe rc=1
#         （nativeCalls 从 29 掉回 17、varForm=0 → 「变量形 <5」那道下限当场报红）。
#         这一刀暴露的是**守卫自己的盲区**：7.4 的 VariableExpressionAst 上没有 UserPath 属性，
#         取到 $null 就 `continue`，于是 `& $ResticBin` 整类（backup 13 + rescue 6）从未登记过，
#         而 AGENTS 写的是「AST 扫每个原生命令调用点」。
#     m18 摘掉 rescue.ps1 `Get-ResticSnapshots` 首句的 EAP=Continue  BITTEN probe rc=1
#         （violations=1，报的正是 `rescue.ps1:195 ResticBin`——5.1 宿主上那一行写 stderr 就抛）。
#   驱动口径补一条：**只验「新行 == 新文本」不算落地校验**——m17 第一次把行号数到注释行上，
#   替换后校验照样 landed=True，拿一份没变异的树跑出绿灯。落刀器现在先比对**旧行内容**再改。
#
#   m19（10-03，场景10b 落地树取证）整条目枚举偷偷换成 `-File`（→ entries 恒等于 files）
#       BITTEN count=1  首条=场景10b 全条目枚举真含目录（entries>files；退化成 -File 就相等）
#       ——这一刀钉的是「取证行给的 entries 到底是不是全条目」：不带 -File 才含目录，
#         而 drill 那一发的病灶形状正是「target 底下只有目录」，取证行退化成只数文件就看不见它。
#   m20 取证行只打 Write-Host、不 `Add-Content` 落盘（读回来是 0 行）
#       BITTEN count=5  首条=场景10b 取证行真的落盘并读得回（只判内存字符串＝死断言）
#       ——断言读的是**盘上那一行**，不是当场拼出来的内存串；否则「写法漂了」和「根本没写」同形。
#   m21 deepest 判据换成写死的 `to_len-5`（比 -To 本身还短）
#       BITTEN count=1  首条=场景10b 最深落点长过 -To 本身（落点树在 -To 之下，不是在别处）
#       ——这一条是给真宿主准备的：容器 `to_len=57 entries=6 files=3 deepest=122`，Windows 上
#         若落点形状变成「只走到第三层就断」，这里先报出来而不是等产品的 FAIL 行。
#         **长 `-To` 那一档仍未测**：drill 坏在 132 字符的 target，本夹具只有 57。
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
$script:rescuePs = Join-Path $Repo 'rescue.ps1'
Chk '被测脚本在仓库里' (Test-Path -LiteralPath $script:rescuePs -PathType Leaf)
if (-not (Test-Path -LiteralPath $script:rescuePs -PathType Leaf)) {
    Write-Host "RESCUE-E2E-FAIL count=1 (no rescue.ps1)"; exit 1
}

# 子进程用**同一个宿主**：5.1 那一步跑起来时，被测的也是 5.1（Task Scheduler 注册的正是它）
$script:selfPs = 'pwsh'
if ($PSVersionTable.PSVersion.Major -lt 6) { $script:selfPs = 'powershell.exe' }
else {
    try {
        $mp = (Get-Process -Id $PID).MainModule.FileName
        if ($mp -and (Test-Path -LiteralPath $mp -PathType Leaf)) { $script:selfPs = $mp }
    } catch { }
}

$script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('bgrescue-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($script:root)

# ---------- 子进程调用：env 覆盖只活在这一发调用里 ----------
function Invoke-Rescue {
    param([string[]]$ChildArgs, [hashtable]$Env = @{})
    $prev = @{}
    foreach ($k in @($Env.Keys)) {
        $prev[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $Env[$k])
    }
    $lines = @(); $rc = -1
    try {
        # EAP=Continue：5.1 上子进程往 stderr 写一行就会变成终止性异常（restic 的进度就写在
        # 那儿）；2>&1 把两路都收进来按行读，判据只认 ASCII 契约行
        $ErrorActionPreference = 'Continue'
        $lines = @(& $script:selfPs '-NoProfile' '-File' $script:rescuePs @ChildArgs 2>&1 |
            ForEach-Object { "$_" })
        $rc = $LASTEXITCODE
    } finally {
        foreach ($k in @($Env.Keys)) { [Environment]::SetEnvironmentVariable($k, $prev[$k]) }
    }
    @{ rc = $rc; lines = $lines; text = ($lines -join "`n") }
}
function Contract([hashtable]$R, [string]$Prefix) {
    $want = 'rescue: ' + $Prefix
    # StartsWith 而不是 -like：路径里带 [ ] 时 -like 会把它们当字符类读——被测面自己
    # 按字面量匹配，守卫反过来用通配语义就是「同一个坑踩两遍」
    @($R.lines | Where-Object { $_.StartsWith($want, [System.StringComparison]::Ordinal) })
}
# 契约行的值部分：`rescue: hit|/a/b` → 取前缀后面那一段
function ContractValue([hashtable]$R, [string]$Prefix) {
    $l = @(Contract $R $Prefix)
    if ($l.Count -eq 0) { return '' }
    $l[0].Substring(('rescue: ' + $Prefix).Length)
}
function HasError([hashtable]$R, [string]$Code) {
    # Fail 打的就是 `rescue: ERROR <CODE>` 整行，所以按整行等值比，不按前缀——
    # 前缀比会把 ERROR NO_MODE 算进 ERROR NO 的命中里
    @($R.lines | Where-Object { $_ -eq ('rescue: ERROR ' + $Code) }).Count -gt 0
}
# row 契约行的字段化读法：`rescue: row|<cls>|<path>|<size>|<restore>`。
# 不用 -like 拼路径：路径是数据，`[ ]` 在被测面里是合法文件名（夹具就造了一个 `a [01] b.txt`），
# 拿它当模式的一部分等于「守卫用通配语义读字面量」——同一条坑不许踩第二遍。
function Rows([hashtable]$R) {
    @( @(Contract $R 'row|') | ForEach-Object {
        $f = $_.Substring('rescue: '.Length) -split '\|'
        if ($f.Count -ne 5) { return }
        @{ cls = $f[1]; path = $f[2]; size = $f[3]; restore = $f[4] }
    } | Where-Object { $null -ne $_ })
}
function RowFor([hashtable]$R, [string]$Cls, [string]$Path) {
    # 调用点必须 `@(RowFor …)`：函数输出恒被管道摊平，命中 1 条时出来的是**那个 hashtable 本身**，
    # `$rNote[0]` 于是变成「按键 0 索引哈希表」＝ $null，整条断言永远为假（10-02 容器首轮就是
    # 这个形状：count=1 却 FAIL，报错里啥都看不出来）。摊平与 rescue.ps1 的快照 ID 同一课。
    @(Rows $R | Where-Object { $_.cls -eq $Cls -and $_.path -eq $Path } | Select-Object -First 1)
}
# 命令行 token 切分（桩日志每行是一次调用的 argv 拼接）：判「有没有 -i 这个参数」必须按
# token 比，不能拿正则扫整行——`recovery-identity.enc` 里就躺着一个 `-i` 子串。
function Tokens([string]$Line) { @($Line -split '\s+' | Where-Object { $_ }) }

function New-Dir([string]$Rel) {
    $p = Join-Path $script:root $Rel
    [void][System.IO.Directory]::CreateDirectory($p)
    $p
}
function Write-File([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content)
    $Path
}

# ---------- 依赖探测：真引擎缺失时相关场景整段 Skip ----------
$resticCmd = Get-Command restic -ErrorAction SilentlyContinue
$ageCmd = Get-Command age -ErrorAction SilentlyContinue
$keygenCmd = Get-Command age-keygen -ErrorAction SilentlyContinue
$script:restic = if ($resticCmd) { $resticCmd.Source } else { '' }
$script:age = if ($ageCmd) { $ageCmd.Source } else { '' }
$script:ageKeygen = if ($keygenCmd) { $keygenCmd.Source } else { '' }
$script:pw = 'ci-rescue-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
Write-Host "# 宿主: PS $((Get-Host).Version) isWin=$($script:isWin) restic=$(if ($script:restic) { 'yes' } else { 'NO' }) age=$(if ($script:age) { 'yes' } else { 'NO' })"

$script:haveReal = [bool]($script:restic -and $script:age -and $script:ageKeygen)

function Run-Native([string[]]$A) {
    $ErrorActionPreference = 'Continue'
    $o = @(& $A[0] @($A[1..($A.Count - 1)]) 2>&1 | ForEach-Object { "$_" })
    @{ rc = $LASTEXITCODE; lines = $o; text = ($o -join "`n") }
}

# ---------- 夹具 ----------
$srcFiles = New-Dir 'src-files'
$notePath = Write-File (Join-Path $srcFiles 'note.txt') "note v1`n"
$oddPath = Write-File (Join-Path $srcFiles 'a [01] b.txt') "odd content`n"
$otherPath = Write-File (Join-Path $srcFiles 'other.dat') "other payload`n"
$srcConf = New-Dir 'src-config'
$confNote = Write-File (Join-Path $srcConf 'confnote.txt') "config payload`n"

# 本地布局：<base>\restic-files（两个快照）+ restic-config（一个快照）
$base = New-Dir 'base'
$repoFiles = Join-Path $base 'restic-files'
$repoConf = Join-Path $base 'restic-config'

if ($script:haveReal) {
    # 口令**必须在 init 之前**进环境：没有 RESTIC_PASSWORD 时 restic 转去读 stdin，`init` 拿到
    # 空串就是 `Fatal: an empty password is not a password` rc=1——10-02 容器首轮整条夹具红在
    # 第一行，后面二十二段一段都没读到。依赖不齐时也不跑 init（`& ''` 是另一种死法）。
    $env:RESTIC_PASSWORD = $script:pw
    $b1 = Run-Native @($script:restic, '-r', $repoFiles, 'init')
    $b2 = Run-Native @($script:restic, '-r', $repoConf, 'init')
    Chk '夹具：restic init 两份仓库' ($b1.rc -eq 0 -and $b2.rc -eq 0) "rc=$($b1.rc)/$($b2.rc) $($b1.text)"
    $k1 = Run-Native @($script:restic, '-r', $repoFiles, 'backup', $srcFiles)
    Start-Sleep -Seconds 2
    Write-File $notePath "note v2 changed`n" | Out-Null
    $k2 = Run-Native @($script:restic, '-r', $repoFiles, 'backup', $srcFiles)
    $k3 = Run-Native @($script:restic, '-r', $repoConf, 'backup', $srcConf)
    Chk '夹具：真 restic 存下 2+1 个快照' ($k1.rc -eq 0 -and $k2.rc -eq 0 -and $k3.rc -eq 0) "$($k1.text) $($k2.text) $($k3.text)"
    # 时间轴：两个快照目录 + profile.json（新形，无设备层）
    $snapNew = Join-Path $base 'timeline/2026/10/02/0234-night'
    $snapOld = Join-Path $base 'timeline/2026/10/01/0234-morning'
    [void][System.IO.Directory]::CreateDirectory($snapNew)
    [void][System.IO.Directory]::CreateDirectory($snapOld)
    Write-File (Join-Path $base 'timeline/profile.json') `
        ('{ "format": "backguard/profile/1", "device_id": "ci-rescue-win", "generated_at": "2026-10-02T02:34:00" }') | Out-Null
    # 云端布局副本：<cloud>\files 就是同一个仓库（判据与产品一致：rclone 推 <cls>）
    $cloud = New-Dir 'cloud'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $cloud 'files'))
    Copy-Item -Path (Join-Path $repoFiles '*') -Destination (Join-Path $cloud 'files') -Recurse -Force
    [void][System.IO.Directory]::CreateDirectory((Join-Path $cloud 'timeline/2026/10/02/0234-night'))
    Write-File (Join-Path $cloud 'timeline/profile.json') '{ "device_id": "ci-rescue-win" }' | Out-Null
    # borg 仓库一份：Windows 上没有 borg 引擎，必须明确说话而不是「找不到仓库」
    [void][System.IO.Directory]::CreateDirectory((Join-Path $script:root 'mixed/borg-files'))
    Write-File (Join-Path $script:root 'mixed/borg-files/config') 'borg 仓库的样子' | Out-Null
    # 时间轴认不出：第一层两个非年份目录（既不是新形也不是唯一设备目录）
    [void][System.IO.Directory]::CreateDirectory((Join-Path $script:root 'ambig/timeline/devA'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $script:root 'ambig/timeline/devB'))
    # 未密封：快照目录在，manifest.json.enc 不在
    [void][System.IO.Directory]::CreateDirectory((Join-Path $script:root 'unsealed/timeline/2026/10/02/0234-night'))
    Write-File (Join-Path $script:root 'unsealed/timeline/profile.json') '{ "device_id": "ci-rescue-win" }' | Out-Null
    # 旧形时间轴（迁移前的副本多一层设备目录）
    $oldSnap = Join-Path $script:root 'oldbase/timeline/ci-rescue-win/2026/09/28/0234-night'
    [void][System.IO.Directory]::CreateDirectory($oldSnap)
    Write-File (Join-Path $script:root 'oldbase/timeline/ci-rescue-win/profile.json') '{ "device_id": "ci-rescue-win" }' | Out-Null
}

# ---------- 场景 1：-Guide 不需要任何目录、任何引擎 ----------
$g = Invoke-Rescue @{} -ChildArgs @('-Guide') -Env @{ 'RESTIC_PASSWORD' = '' }
Chk '场景1 -Guide 退出 0' ($g.rc -eq 0) "rc=$($g.rc)"
Chk '场景1 -Guide 有收尾契约行' (@(Contract $g 'done mode=guide').Count -eq 1) "实得 $(@(Contract $g 'done').Count) 条 done"
Chk '场景1 -Guide 不报任何错误码' (-not ($g.text -match 'rescue: ERROR')) ''

# ---------- 场景 2：缺动作 / 备份根不存在，两种出口的码与退出码都不同 ----------
$n = Invoke-Rescue -ChildArgs @()
Chk '场景2 缺动作退 2' ($n.rc -eq 2) "rc=$($n.rc)"
Chk '场景2 缺动作报 NO_MODE' (HasError $n 'NO_MODE') $n.text
$b = Invoke-Rescue -ChildArgs @('-List', '-Base', (Join-Path $script:root 'nope'))
Chk '场景2 备份根不存在退 1' ($b.rc -eq 1) "rc=$($b.rc)"
Chk '场景2 备份根不存在报 BASE_NOT_FOUND' (HasError $b 'BASE_NOT_FOUND') $b.text
Chk '场景2 两种出口码不同（不是同一个 catch）' ($n.rc -ne $b.rc) "no-mode=$($n.rc) bad-base=$($b.rc)"

if (-not $script:haveReal) {
    Skip '场景3-24 真 restic + 真 age 那二十二段' 'PATH 里没有 restic/age/age-keygen：没有证据不等于通过'
} else {
    # ---------- 场景 3：本地布局 + 时间轴（新形）一次读全 ----------
    $l = Invoke-Rescue -ChildArgs @('-List', '-Base', $base) -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景3 -List 退出 0' ($l.rc -eq 0) "rc=$($l.rc) text=$($l.text)"
    Chk '场景3 files 认出本地布局与 2 个快照' (@(Contract $l 'class=files layout=local snapshots=2').Count -eq 1) `
        "实得: $(Contract $l 'class=')"
    Chk '场景3 config 认出本地布局与 1 个快照' (@(Contract $l 'class=config layout=local snapshots=1').Count -eq 1) ''
    Chk '场景3 system 如实说没有仓库' (@(Contract $l 'class=system missing').Count -eq 1) ''
    Chk '场景3 逐快照 ID 行 = 3 条' (@(Contract $l 'snapshot ').Count -eq 3) "实得 $(@(Contract $l 'snapshot ').Count)"
    Chk '场景3 时间轴根指向 timeline，快照数与设备名读自 profile.json' (
        ((ContractValue $l 'timeline=') -as [string]).Contains('timeline') -and
        ((ContractValue $l 'timeline=') -as [string]).Contains(' snapshots=2 ') -and
        ((ContractValue $l 'timeline=') -as [string]).EndsWith('device=ci-rescue-win')) `
        "实得: $(Contract $l 'timeline=')"
    Chk '场景3 两个快照目录都列出（相对根、正斜杠）' (
        @(Contract $l 'timeline-snapshot 2026/10/02/0234-night').Count -eq 1 -and
        @(Contract $l 'timeline-snapshot 2026/10/01/0234-morning').Count -eq 1) "实得: $(Contract $l 'timeline-snapshot')"
    Chk '场景3 契约行全 ASCII（不许有中文混进判据）' (-not ($l.text -match 'rescue: WARN contract-line-has-non-ascii')) ''

    # ---------- 场景 4：云端副本布局 <base>/<cls>（Windows 设备从网盘取回时那一份）----------
    $c = Invoke-Rescue -ChildArgs @('-List', '-Base', $cloud) -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景4 云端布局 layout=cloud' (@(Contract $c 'class=files layout=cloud snapshots=2').Count -eq 1) `
        "实得: $(Contract $c 'class=')"
    Chk '场景4 云端布局不是被当本地布局读出来的' (-not ($c.text -match 'layout=local')) ''
    # 云端副本是在两次备份都存完之后整棵拷的，所以快照数与本地同形（2）——不是「云端只有一份」。
    # 写死这个数是为了让场景 3 与场景 4 用的是同一棵仓库树这件事被验证，而不是被假设。
    Chk '场景4 云端那份读出的 ID 与本地一致' (
        (@(Contract $c 'snapshot files|').Count -eq 2) -and
        (-not (ContractValue $c 'class=system layout'))) ''

    # ---------- 场景 5：没有 restic 时 -List 仍然给时间轴那一半 ----------
    $noBin = Join-Path $script:root 'definitely-not-restic'
    $m = Invoke-Rescue -ChildArgs @('-List', '-Base', $base, '-Restic', $noBin)
    Chk '场景5 引擎缺失那一段如实标 unreadable' (@(Contract $m 'class=files layout=local unreadable=no-restic').Count -eq 1) `
        "实得: $(Contract $m 'class=')"
    Chk '场景5 时间轴那一半照样给（旁路降级不判死整条）' (@(Contract $m 'timeline=').Count -eq 1 -and $m.rc -eq 0) `
        "rc=$($m.rc) 实得: $(Contract $m 'timeline=')"

    # ---------- 场景 6：borg 仓库明确说「去用 rescue.sh」，而不是「找不到仓库」----------
    $mb = New-Dir 'mixed'
    $lb = Invoke-Rescue -ChildArgs @('-List', '-Base', $mb) -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景6 -List 认出 borg 仓库并标注不支持' (@(Contract $lb 'class=files engine=borg-unsupported').Count -eq 1) `
        "实得: $(Contract $lb 'class=')"
    $fb = Invoke-Rescue -ChildArgs @('-Base', $mb, '-Class', 'files', '-Find', 'x') -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景6 -Find 撞见 borg 仓库必须退 1' ($fb.rc -eq 1) "rc=$($fb.rc)"
    Chk '场景6 报的是 BORG_REPO_ON_WINDOWS 不是 REPO_NOT_FOUND' (
        (HasError $fb 'BORG_REPO_ON_WINDOWS') -and -not (HasError $fb 'REPO_NOT_FOUND')) $fb.text

    # ---------- 场景 7：引擎读不出（口令错）与「没有匹配」是两种坏法，话必须分开 ----------
    $wrong = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Find', 'note') `
        -Env @{ 'RESTIC_PASSWORD' = 'wrong-password-on-purpose' }
    Chk '场景7 口令错必须非零退出' ($wrong.rc -ne 0) "rc=$($wrong.rc) text=$($wrong.text)"
    Chk '场景7 报的是 ENGINE_UNREADABLE' (HasError $wrong 'ENGINE_UNREADABLE') $wrong.text
    Chk '场景7 带引擎调用失败证据行' (@(Contract $wrong 'engine-fail cmd=snapshots rc=').Count -ge 1) `
        "实得: $(Contract $wrong 'engine-fail')"
    Chk '场景7 不许被说成「无快照」或「0 条匹配」' (
        -not (HasError $wrong 'NO_ARCHIVE') -and ($wrong.text -notmatch 'rescue: hits=0')) $wrong.text
    $nolist = Invoke-Rescue -ChildArgs @('-List', '-Base', $base) -Env @{ 'RESTIC_PASSWORD' = 'wrong-password-on-purpose' }
    Chk '场景7 -List 里口令错标 unreadable=engine 且不算成功' (@(Contract $nolist 'class=files layout=local unreadable=engine').Count -eq 1) `
        "实得: $(Contract $nolist 'class=')"

    # ---------- 场景 8：无匹配是另一种结果（退出 0 + hits=0），与场景 7 分档 ----------
    $zero = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Find', 'nothing-matches-this') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景8 无匹配退 0 且 hits=0' ($zero.rc -eq 0 -and @(Contract $zero 'hits=0').Count -eq 1) `
        "rc=$($zero.rc) 实得: $(Contract $zero 'hits=')"

    # ---------- 场景 9：字面量匹配——`[01]` 不许被当正则读 ----------
    $odd = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Find', 'a [01] b') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景9 字面量命中 1 条' ($odd.rc -eq 0 -and @(Contract $odd 'hits=1').Count -eq 1) `
        "rc=$($odd.rc) 实得: $(Contract $odd 'hits=') text=$($odd.text)"
    $hitOdd = ContractValue $odd 'hit|'
    # 后缀判定用 IndexOf(..., Ordinal) 而不是 -like 也不是 EndsWith：`[01]` 在 -like 里是字符类
    # （匹配单个 0 或 1），拿通配语义读「夹具专门造出来的字面量文件名」等于守卫自己踩被测面刚
    # 躲开的那个坑；而 `EndsWith(string, StringComparison)` 这个重载在 .NET Framework 上没有
    # （5.1 那一步会直接 MethodOnExtensionNotFound），只有 IndexOf 重载两档宿主都在。
    $oddTail = 'a [01] b.txt'
    Chk '场景9 hit 行把整条路径原样交出来（含空格与方括号）' (
        $hitOdd.Length -ge $oddTail.Length -and
        $hitOdd.IndexOf($oddTail, [System.StringComparison]::Ordinal) -eq ($hitOdd.Length - $oddTail.Length)) "实得: $hitOdd"
    # 反证：同一条路径按正则读会命中 0 条——这条断言自己也得有牙齿（把 Ordinal 换成正则
    # 就是场景 9 第一条的落点，而这一条说明「正则版确实与字面量版不同」）
    $asRegex = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Find', 'a [01] b\.txt$') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景9 加了的正则写法 0 条（证明两条口径不重合）' (@(Contract $asRegex 'hits=0').Count -eq 1) `
        "实得: $(Contract $asRegex 'hits=')"

    # ---------- 场景 10：-Find 的输出原样喂给 -Get，落点与内容都对 ----------
    $hitNote = ''
    $f1 = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Find', 'note.txt') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    $hitNote = ContractValue $f1 'hit|'
    Chk '场景10 -Find 交出 note.txt 的归档内路径' ($hitNote -like '*note.txt') "实得: $hitNote"
    # -To 里预置两份诱饵文件：「取回」的计数只能来自本次创建的暂存目录，不能被诱饵冒充
    $to = New-Dir 'restore-to'
    Write-File (Join-Path $to 'decoy1.txt') 'pre-existing' | Out-Null
    Write-File (Join-Path $to 'decoy2.txt') 'pre-existing' | Out-Null
    $gt = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Get', $hitNote, '-To', $to) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景10 -Get 退出 0' ($gt.rc -eq 0) "rc=$($gt.rc) text=$($gt.text)"
    Chk '场景10 计数只算本次取回的 1 个文件（诱饵不算）' (
        @(Contract $gt 'got files=1').Count -eq 1) "实得: $(Contract $gt 'got')"
    $landed = Get-ChildItem -LiteralPath $to -Recurse -File -Force |
        Where-Object { $_.Name -eq 'note.txt' } | Select-Object -First 1
    Chk '场景10 文件真的落在 -To 下面（保留仓库内结构）' ($null -ne $landed) "找遍 -To: $((Get-ChildItem -LiteralPath $to -Recurse -File -Force | ForEach-Object { $_.FullName }) -join ' ')"
    Chk '场景10 内容是最新快照那一份（v2）' ($landed -and (Get-Content -LiteralPath $landed.FullName -Raw) -match 'v2') `
        "实得: $(if ($landed) { Get-Content -LiteralPath $landed.FullName -Raw } else { '(没落地)' })"
    Chk '场景10 暂存目录用完自己收掉（不许留 .bg-rescue-*）' (
        @(Get-ChildItem -LiteralPath $to -Force -Directory | Where-Object { $_.Name -like '.bg-rescue-*' }).Count -eq 0) `
        "残留: $((Get-ChildItem -LiteralPath $to -Force -Directory | ForEach-Object { $_.Name }) -join ' ')"

    # ---------- 场景10b：落点取证行（10-03 演练那一发的教训——长度依赖只有真宿主看得见）----------
    # 演练侧坏在「引擎报 `Restored 9 / 1 files/dirs` 而 target 之下递归枚举只有 3 个**目录**条目」，
    # 两个候选（引擎少写 vs 枚举看不见深路径）都没被那一轮证据排掉，**成因未定**（登记在 AGENTS §2
    # 「第五轮」）；`dump` 只是绕开了它，没有解释它。`rescue.ps1` 的 -Get 仍是
    # `restore --include --target`，所以同一类坏法在这边到底有没有对应形状，**要量而不是猜**：
    # 这一档夹具的 -To 是 temp 根下的一层（短），真机现场用户给的 -To 可能深得多。
    # 三条设计约束：①**全条目枚举、不带 `-File`**——上一版演练取证用 `-File` 时，「只落了目录」与
    # 「一个文件都没落」报出来同为 0，这一发不许再犯（所以下面那条判据是 `entries > files`，
    # 它本身就是「枚举真的数到了目录」的存活证据）；②取证行**写盘再读回**——只判内存里那个字符串
    # 等于拿它自己比它自己（场景5 那一类死断言），剥掉写入这行必须红；③数值与产品自报对得上：
    # -To 里预置 2 个诱饵 + 取回 1 个，所以 `files >= 3`。
    $all10 = @(Get-ChildItem -LiteralPath $to -Recurse -Force -ErrorAction SilentlyContinue)
    $files10 = @($all10 | Where-Object { -not $_.PSIsContainer })
    $deep10 = 0
    foreach ($it10 in $all10) {
        $len10 = "$($it10.FullName)".Length
        if ($len10 -gt $deep10) { $deep10 = $len10 }
    }
    $echo10 = "# rescue-landed to_len=$("$to".Length) entries=$($all10.Count) files=$($files10.Count) deepest=$deep10"
    $echoFile10 = Join-Path $script:root 'rescue-landed.txt'
    [void](Add-Content -LiteralPath $echoFile10 -Value $echo10)
    Write-Host $echo10
    $line10 = @(@(Get-Content -LiteralPath $echoFile10 -ErrorAction SilentlyContinue) |
        Where-Object { $_.StartsWith('# rescue-landed ', [System.StringComparison]::Ordinal) })
    Chk '场景10b 取证行真的落盘并读得回（只判内存字符串＝死断言）' ($line10.Count -eq 1) `
        "实得 $($line10.Count) 行: $(($line10 | Out-String).Trim())"
    $m10 = [regex]::Match("$($line10 | Select-Object -First 1)",
        '^# rescue-landed to_len=(?<tolen>\d+) entries=(?<entries>\d+) files=(?<files>\d+) deepest=(?<deepest>\d+)$')
    Chk '场景10b 四数从盘上那一行解析得出（写法漂了就解析不出）' ($m10.Success) "$($line10 | Select-Object -First 1)"
    Chk '场景10b 全条目枚举真含目录（entries>files；退化成 -File 就相等）' (
        $m10.Success -and [int]$m10.Groups['entries'].Value -gt [int]$m10.Groups['files'].Value) `
        "$($line10 | Select-Object -First 1)"
    Chk '场景10b 取回的条数与产品自报对得上（-To 里 2 诱饵 + 1 取回）' (
        $m10.Success -and [int]$m10.Groups['files'].Value -ge 3) "$($line10 | Select-Object -First 1)"
    Chk '场景10b 最深落点长过 -To 本身（落点树在 -To 之下，不是在别处）' (
        $m10.Success -and [int]$m10.Groups['deepest'].Value -gt [int]$m10.Groups['tolen'].Value) `
        "$($line10 | Select-Object -First 1)"

    # ---------- 场景 11：路径写错不能静默「成功」----------
    $bogus = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Get', "$hitNote".Replace('note.txt', 'NOPE.txt'), '-To', (New-Dir 'restore-bogus')) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景11 取不到东西必须退 1' ($bogus.rc -eq 1) "rc=$($bogus.rc)"
    Chk '场景11 报 NOTHING_RESTORED' (HasError $bogus 'NOTHING_RESTORED') $bogus.text
    Chk '场景11 失败后不留暂存目录' (@(Get-ChildItem -LiteralPath (Join-Path $script:root 'restore-bogus') -Force | Where-Object { $_.Name -like '.bg-rescue-*' }).Count -eq 0) ''

    # ---------- 场景 12：-Archive 指历史快照 → 取回的是历史那一份内容 ----------
    # 快照 ID 从 -List 自己的契约行里取（顺序 = restic 的时间升序，ids[0] 就是最旧那份）：
    # 不在夹具里再跑一遍 restic，否则「rescue 读出的 ID 表」与「断言用的 ID 表」是两份真相
    $ids = @(Contract $l 'snapshot files|' |
        ForEach-Object { $_.Substring('rescue: snapshot files|'.Length) })
    Chk '场景12 -List 交出 2 个 files 快照 ID' ($ids.Count -eq 2) "实得: $($ids -join ',')"
    $older = $ids[0]
    $ho = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Archive', $older, '-Get', $hitNote, '-To', (New-Dir 'restore-old')) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景12 -Archive 取历史快照退 0' ($ho.rc -eq 0) "rc=$($ho.rc) text=$($ho.text)"
    $oldLanded = Get-ChildItem -LiteralPath (Join-Path $script:root 'restore-old') -Recurse -File -Force |
        Where-Object { $_.Name -eq 'note.txt' } | Select-Object -First 1
    Chk '场景12 内容确实是 v1（不是最新那份）' ($oldLanded -and
        (Get-Content -LiteralPath $oldLanded.FullName -Raw) -match 'v1' -and
        (Get-Content -LiteralPath $oldLanded.FullName -Raw) -notmatch 'changed') `
        "实得: $(if ($oldLanded) { Get-Content -LiteralPath $oldLanded.FullName -Raw } else { '(没落地)' })"
    Chk '场景12 用的归档就是点名的那个' (
        @(Contract $ho 'target class=files').Count -eq 1 -and
        ((ContractValue $ho 'target ') -as [string]).Contains('archive=' + $older)) "实得: $(Contract $ho 'target')"
    $ghost = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Archive', 'deadbeef', '-Find', 'note') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景12 不存在的快照 ID 报错而不是取最新' ($ghost.rc -eq 1 -and (HasError $ghost 'ARCHIVE_NOT_FOUND')) `
        "rc=$($ghost.rc) text=$($ghost.text)"

    # ---------- 场景 13：-Get 缺 -To ----------
    $noTo = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Get', $hitNote) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景13 缺 -To 报 TO_REQUIRED' ($noTo.rc -eq 1 -and (HasError $noTo 'TO_REQUIRED')) $noTo.text

    # ---------- 场景 14：-Class 缺失 / 非法 / 大小写 —— 三种输入三种答案 ----------
    $noCls = Invoke-Rescue -ChildArgs @('-Base', $base, '-Find', 'note') -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景14 没有 -Class 报 CLASS_REQUIRED' ($noCls.rc -eq 1 -and (HasError $noCls 'CLASS_REQUIRED')) $noCls.text
    $badCls = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'data', '-Find', 'note') -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景14 非法类别报 CLASS_REQUIRED（不能退化成 REPO_NOT_FOUND）' (
        $badCls.rc -eq 1 -and (HasError $badCls 'CLASS_REQUIRED') -and -not (HasError $badCls 'REPO_NOT_FOUND')) $badCls.text
    # 大小写归一：`-Class Files` 是逃生现场最容易打出来的一发。归一必须**同时**作用于校验与
    # 仓库路径——只在校验处归一（`-contains` 本来就不区分大小写）时，Windows 宿主照样找得到
    # `restic-Files`（文件系统不区分），Linux 宿主则报 REPO_NOT_FOUND：同一份脚本两种答案。
    $caseCls = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'Files', '-Find', 'note') -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景14 -Class Files 归一后照常工作（不是「非法类别」）' ($caseCls.rc -eq 0) "rc=$($caseCls.rc) text=$($caseCls.text)"
    Chk '场景14 归一后的类别真是小写（仓库路径按它拼）' (
        @(Contract $caseCls 'target class=files repo=').Count -eq 1) "实得: $(Contract $caseCls 'target')"

    # ---------- 场景 15：密封账本（真 age，路径 A）——账本 → -Get 的链路 ----------
    $ageDir = New-Dir 'age'
    $kg = Run-Native @($script:ageKeygen, '-o', (Join-Path $ageDir 'identity.txt'))
    Chk '场景15 age-keygen 造出主身份' ($kg.rc -eq 0 -and (Test-Path -LiteralPath (Join-Path $ageDir 'identity.txt'))) "$($kg.text)"
    $ident = Join-Path $ageDir 'identity.txt'
    $pubText = Get-Content -LiteralPath $ident -Raw
    $pub = ''
    if ($pubText -match '(age1[0-9a-z]+)') { $pub = $matches[1] }
    Write-File (Join-Path $ageDir 'recipients.txt') ($pub + "`n") | Out-Null
    Chk '场景15 recipients 里有 X25519 公钥' ($pub.StartsWith('age1')) "实得: $pub"

    # 归档内路径**从引擎自己的列表里取**（跨宿主分隔符不靠猜）
    $foOther = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'files', '-Find', 'other.dat') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    $hitOther = ContractValue $foOther 'hit|'
    $foConf = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'config', '-Find', 'confnote') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    $hitConf = ContractValue $foConf 'hit|'
    # 单快照档案的 target 行必须是**完整 ID**。这一发是 10-02 容器首轮真炸出来的：
    # Get-ResticSnapshots 只有 1 个元素时被 PowerShell 摊平成字符串，`$ids[-1]` 取到的是那个
    # 字符串的**最后一个字符** → `archive=b` → restic `no matching ID found for prefix "b"` →
    # 报成 ENGINE_UNREADABLE。双快照的 files 仓库永远不会露头（数组没摊平），而逃生现场最常见
    # 恰恰是「仓库里只有一个快照」，所以这条判据钉的是最常见那一档，不是边角。
    $cfgId = ContractValue $l 'snapshot config|'
    $confLine = @(Contract $foConf 'target class=config') | Select-Object -First 1
    $confArchive = ''
    if ("$confLine" -match 'archive=([0-9a-f]+)\s*$') { $confArchive = $matches[1] }
    Chk '场景15 单快照档案的 target 用完整快照 ID（不是最后一个字符）' (
        $confArchive.Length -ge 8 -and $confArchive -eq $cfgId) `
        "want=[$cfgId] got=[$confArchive] line=[$confLine]"
    Chk '场景15 三个归档内路径都拿到了' ($hitNote -and $hitOther -and $hitConf) `
        "$hitNote / $hitOther / $hitConf || conf rc=$($foConf.rc) text=$($foConf.text)"

    $sizeOf = { param($p) (Get-Item -LiteralPath $p).Length }
    # 账本形状里 **raw 与 path 故意不同值**（config 那条）：`restore = raw ?? path` 这条规则
    # 只有在两者不同值时才测得出来——同值时把实现摘成「永远用 path」，全链路照样绿。
    # 不同值正是 bg 侧的真实形状（path 给人看，raw 是归档内的取回入参）。
    $manifest = @{
        format = 'backguard/manifest/1'
        snapshot = @{ id = 'ci'; time = '2026-10-02T02:34:00' }
        device = @{ id = 'ci-rescue-win'; os = 'windows' }
        engine = 'restic'
        classes = @{
            files = @{ entries = @(
                    @{ path = $hitNote; size = (& $sizeOf $notePath); mtime = 1 },
                    @{ path = $hitOther; size = (& $sizeOf $otherPath); mtime = 2; raw = $hitOther }
                ); stats = @{ count = 2 } }
            config = @{ entries = @(
                    @{ path = '/confnote.txt'; size = (& $sizeOf $confNote); mtime = 3; raw = $hitConf }
                ); stats = @{ count = 1 } }
        }
    }
    $plain = Join-Path $script:root 'plain-manifest.json'
    ($manifest | ConvertTo-Json -Depth 8) | Out-File -FilePath $plain -Encoding utf8
    $encPath = Join-Path $snapNew 'manifest.json.enc'
    $seal = Run-Native @($script:age, '-R', (Join-Path $ageDir 'recipients.txt'), '-o', $encPath, $plain)
    Chk '场景15 密封账本（age -R）' ($seal.rc -eq 0 -and (Test-Path -LiteralPath $encPath)) "$($seal.text)"
    Remove-Item -LiteralPath $plain -Force   # 明文只在这一会儿存在，密封完立刻删
    # 旧形时间轴里也放一份（迁移前的真副本长这样）；那个快照目录由夹具段 $oldSnap 建，这里只放密文
    Copy-Item -LiteralPath $encPath -Destination (Join-Path $oldSnap 'manifest.json.enc') -Force

    $led = Invoke-Rescue -ChildArgs @('-Base', $base, '-Ledger', '-Identity', $ident) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景15 -Ledger 路径 A 退出 0' ($led.rc -eq 0) "rc=$($led.rc) text=$($led.text)"
    Chk '场景15 账本 3 条全给（跨类别）' (
        @(Contract $led 'ledger entries=3 matched=3 format=backguard/manifest/1').Count -eq 1) "实得: $(Contract $led 'ledger')"
    Chk '场景15 row 行带类别/路径/大小/取回路径（5 段，一条不缺）' (@(Rows $led).Count -eq 3) "实得: $(Contract $led 'row|')"
    $rNote = @(RowFor $led 'files' $hitNote)
    Chk '场景15 note.txt 那条：没有 raw 时取回路径退回 path，size 与源文件一致' (
        $rNote.Count -eq 1 -and $rNote[0].restore -eq $hitNote -and
        $rNote[0].size -eq "$(& $sizeOf $notePath)") `
        "count=$($rNote.Count) want=[$hitNote] got_restore=[$($rNote[0].restore)] got_size=[$($rNote[0].size)] disk=$(& $sizeOf $notePath)"
    $rConf = @(RowFor $led 'config' '/confnote.txt')
    Chk '场景15 config 那条：有 raw 时取回路径用 raw 而不是 path' (
        $rConf.Count -eq 1 -and $rConf[0].restore -eq $hitConf -and $rConf[0].path -eq '/confnote.txt') `
        "count=$($rConf.Count) want_restore=[$hitConf] got_restore=[$($rConf[0].restore)] got_path=[$($rConf[0].path)]"
    Chk '场景15 格式对时不打格式告警' (-not ($led.text -match 'rescue: warn manifest-format=')) $led.text

    # 账本的取回字段直接喂 -Get（「30 分钟内盲恢复」那条链路的最后一公里）。用的是 raw≠path
    # 那条：所以这一发同时证明「给人看的路径写错了也不影响真取回」。
    $restoreFromLedger = $rConf[0].restore
    $gt2 = Invoke-Rescue -ChildArgs @('-Base', $base, '-Class', 'config', '-Get', $restoreFromLedger, '-To', (New-Dir 'restore-from-ledger')) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景15 账本给出的取回路径真能取到文件' ($gt2.rc -eq 0 -and @(Contract $gt2 'got files=1').Count -eq 1) `
        "rc=$($gt2.rc) 实得: $(Contract $gt2 'got') text=$($gt2.text)"

    # ---------- 场景 16：-Ledger -Find 是过滤，不是改动作 ----------
    $lf = Invoke-Rescue -ChildArgs @('-Base', $base, '-Ledger', '-Identity', $ident, '-Find', 'other') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景16 过滤后 matched=1 而 entries 仍是 3' (
        @(Contract $lf 'ledger entries=3 matched=1').Count -eq 1) "实得: $(Contract $lf 'ledger')"
    Chk '场景16 只打出一条 row' (@(Contract $lf 'row|').Count -eq 1) "实得 $(@(Contract $lf 'row|').Count)"

    # ---------- 场景 17：缺恢复材料 / 主身份不配对，两种失败分开说 ----------
    $nomat = Invoke-Rescue -ChildArgs @('-Base', $base, '-Ledger') -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景17 无材料报 NO_MATERIAL 且退 1' ($nomat.rc -eq 1 -and (HasError $nomat 'NO_MATERIAL')) $nomat.text
    $other2 = New-Dir 'age2'
    [void](Run-Native @($script:ageKeygen, '-o', (Join-Path $other2 'identity.txt')))
    $wrongId = Invoke-Rescue -ChildArgs @('-Base', $base, '-Ledger', '-Identity', (Join-Path $other2 'identity.txt')) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景17 不相干的主身份报 LEDGER_OPEN_FAILED（不是「无匹配」）' ($wrongId.rc -eq 1 -and
        (HasError $wrongId 'LEDGER_OPEN_FAILED') -and -not (HasError $wrongId 'NO_MATERIAL')) $wrongId.text
    $missingId = Invoke-Rescue -ChildArgs @('-Base', $base, '-Ledger', '-Identity', (Join-Path $script:root 'no-such-identity.txt')) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景17 主身份文件不存在报 IDENTITY_MISSING' (HasError $missingId 'IDENTITY_MISSING') $missingId.text

    # ---------- 场景 18：格式非预期只告警不判死（清单格式演进时旧 rescue 还得能用）----------
    $badPlain = Join-Path $script:root 'bad-format.json'
    $badDoc = @{ format = 'backguard/manifest/99'; classes = @{ files = @{ entries = @(@{ path = $hitNote; size = 1 }) } } }
    ($badDoc | ConvertTo-Json -Depth 6) | Out-File -FilePath $badPlain -Encoding utf8
    $badSnap = Join-Path $base 'timeline/2026/10/01/0234-morning'
    [void](Run-Native @($script:age, '-R', (Join-Path $ageDir 'recipients.txt'), '-o', (Join-Path $badSnap 'manifest.json.enc'), $badPlain))
    Remove-Item -LiteralPath $badPlain -Force
    $bf = Invoke-Rescue -ChildArgs @('-Base', $base, '-Ledger', '-Identity', $ident,
        '-Snapshot', '2026/10/01/0234-morning') -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景18 非预期格式仍退 0 并打告警行' ($bf.rc -eq 0 -and @(Contract $bf 'warn manifest-format=').Count -eq 1) `
        "rc=$($bf.rc) 实得: $(Contract $bf 'warn')"

    # ---------- 场景 19：旧形时间轴（迁移前的真副本）必须照样能读 ----------
    $oldList = Invoke-Rescue -ChildArgs @('-List', '-Base', (Join-Path $script:root 'oldbase')) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景19 -List 认得旧形（根落在设备目录上）' (
        (ContractValue $oldList 'timeline=') -like '*timeline*' -and $oldList.text -match 'timeline-snapshot 2026/09/28/0234-night') `
        "实得: $(Contract $oldList 'timeline=') / $(Contract $oldList 'timeline-snapshot')"
    Chk '场景19 旧形里也读到设备名' ($oldList.text -match 'device=ci-rescue-win') "实得: $(Contract $oldList 'timeline=')"
    $oldLed = Invoke-Rescue -ChildArgs @('-Base', (Join-Path $script:root 'oldbase'), '-Ledger', '-Identity', $ident, '-Find', 'other') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景19 旧形时间轴的账本读得出（逃生工具面向的是历史副本）' ($oldLed.rc -eq 0 -and
        @(Contract $oldLed 'ledger entries=3 matched=1').Count -eq 1) "rc=$($oldLed.rc) 实得: $(Contract $oldLed 'ledger') text=$($oldLed.text)"

    # ---------- 场景 20：时间轴认不出 / 快照不存在 / 未密封，三种坏法三个码 ----------
    $amb = Invoke-Rescue -ChildArgs @('-List', '-Base', (Join-Path $script:root 'ambig')) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景20 -List 认不出时只告警不失败' ($amb.rc -eq 0 -and @(Contract $amb 'timeline unrecognized').Count -eq 1) `
        "rc=$($amb.rc) 实得: $(Contract $amb 'timeline')"
    $ambLed = Invoke-Rescue -ChildArgs @('-Base', (Join-Path $script:root 'ambig'), '-Ledger', '-Identity', $ident) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景20 -Ledger 认不出必须失败（不能给一份读不全的账本当成功）' (
        $ambLed.rc -eq 1 -and (HasError $ambLed 'TIMELINE_UNRECOGNIZED')) "rc=$($ambLed.rc) text=$($ambLed.text)"
    $uns = Invoke-Rescue -ChildArgs @('-Base', (Join-Path $script:root 'unsealed'), '-Ledger', '-Identity', $ident) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景20 未密封的快照报 LEDGER_NOT_SEALED' (HasError $uns 'LEDGER_NOT_SEALED') $uns.text
    $noSnap = Invoke-Rescue -ChildArgs @('-Base', $base, '-Ledger', '-Identity', $ident, '-Snapshot', '2031/01/01/0000-ghost') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景20 点名的快照不存在报 SNAPSHOT_NOT_FOUND' (HasError $noSnap 'SNAPSHOT_NOT_FOUND') $noSnap.text
    # 空仓库（init 完还没备份、或备份全被裁掉）是 NO_ARCHIVE。它和上一条是**同一类退化的两面**：
    # 函数返回 0 个元素时输出被摊平成「什么都没写」，调用点拿到 $null——与引擎失败长得一模一样，
    # 不修的话空仓库会被报成 ENGINE_UNREADABLE，把人往「仓库损坏、要重装备份」的方向支走。
    $emptyBase = New-Dir 'emptybase'
    $e0 = Run-Native @($script:restic, '-r', (Join-Path $emptyBase 'restic-files'), 'init')
    Chk '场景20 夹具：一个空的 restic 仓库' ($e0.rc -eq 0) "$($e0.text)"
    $e1 = Invoke-Rescue -ChildArgs @('-Base', $emptyBase, '-Class', 'files', '-Find', 'anything') `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景20 空仓库报 NO_ARCHIVE（不是 ENGINE_UNREADABLE，也不许带 engine-fail）' (
        $e1.rc -eq 1 -and (HasError $e1 'NO_ARCHIVE') -and -not (HasError $e1 'ENGINE_UNREADABLE') -and
        ($e1.text -notmatch 'engine-fail')) "rc=$($e1.rc) text=$($e1.text)"
    $e2 = Invoke-Rescue -ChildArgs @('-List', '-Base', $emptyBase) `
        -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景20 -List 对空仓库给 snapshots=0（不是空值，也不是 missing）' (
        @(Contract $e2 'class=files layout=local snapshots=0').Count -eq 1) "实得: $(Contract $e2 'class=')"

    # ---------- 场景 21：路径 B 的调用序列（桩 age：交互那一步 CI 走不到）----------
    $stubDir = New-Dir 'stubage'
    $stubLog = Join-Path $script:root 'age-argv.log'
    $stubBody = if ($script:isWin) {
        @(
            '@echo off'
            'echo %*>> "%STUB_LOG%"'
            'if not "%~1"=="-d" exit /b 0'
            'set HASI='
            'for %%a in (%*) do if "%%a"=="-i" set HASI=1'
            # 第 2 步 `-d -i <身份> -o <明文> <密文>`：明文写 %~5；第 1 步 `-d -o <救援身份明文> <enc>`：写 %~3
            'if defined HASI ('
            '  copy /y "%PLAIN_SRC%" "%~5" >nul'
            '  exit /b 0'
            ')'
            # 不在括号块里用 `call set OUTVAR=%5` + `echo …> %OUTVAR%`：块解析时 %OUTVAR% 还是空，
            # 而 %~5 这类**入参**在执行时展开是安全的——AGENTS §2 那条「括号块按块解析时展开变量」
            # 的同一课（retention 桩的 `set /p MSG` 就是这么打成字面量 %MSG% 的）。
            'echo ----- AGE-KEY-X25519-stub-identity> "%~3"'
            'exit /b 0'
        ) -join "`r`n"
    } else {
        @(
            '#!/bin/sh'
            'printf "%s\n" "$*" >> "$STUB_LOG"'
            'if [ "$1" = "-d" ]; then'
            '  for a in "$@"; do [ "$a" = "-i" ] && HASI=1; done'
            # 第 2 步的 argv 是 `-d -i <身份> -o <明文> <密文>`：输出文件在 **$5**（$4 是字面量 -o）。
            # 数错一个位置就等于把明文写进一个叫 "-o" 的文件——桩自己不会报错，而断言只看得见
            # 「账本读不出」，看起来像实现坏了。第 1 步 `-d -o <救援身份明文> <enc>` 才是 $3。
            '  if [ -n "${HASI:-}" ]; then cp "$PLAIN_SRC" "$5"; exit 0; fi'
            '  printf -- "----- AGE-KEY: X25519 <- stub-identity\n" > "$3"; exit 0'
            'fi'
            'exit 0'
        ) -join "`n"
    }
    $stubExt = if ($script:isWin) { 'cmd' } else { 'sh' }
    $stubPath = Join-Path $stubDir ("age-stub." + $stubExt)
    [System.IO.File]::WriteAllText($stubPath, $stubBody)
    if (-not $script:isWin) { try { chmod 755 $stubPath } catch { } }
    $pathBPlain = Join-Path $script:root 'pathb-manifest.json'
    ($manifest | ConvertTo-Json -Depth 8) | Out-File -FilePath $pathBPlain -Encoding utf8
    $recEnc = Join-Path $ageDir 'recovery-identity.enc'
    # 用真 age 造一份「被口令包住的救援身份」在 CI 里做不到（age 加密侧也要口令）——桩把这一步
    # 伪装成成功即可，判据是**调用序列与凭据面**：两步、argv 里没口令、私钥明文用完即删。
    Write-File $recEnc 'STUB-recovery-identity.enc' | Out-Null
    $env:STUB_LOG = $stubLog
    $env:PLAIN_SRC = $pathBPlain
    $bLed = Invoke-Rescue -ChildArgs @('-Base', $base, '-Ledger', '-Recovery', $recEnc, '-Age', $stubPath,
        '-Find', 'other') -Env @{ 'RESTIC_PASSWORD' = $script:pw }
    Chk '场景21 路径 B 退 0 并读出账本' ($bLed.rc -eq 0 -and @(Contract $bLed 'ledger entries=3 matched=1').Count -eq 1) `
        "rc=$($bLed.rc) 实得: $(Contract $bLed 'ledger') text=$($bLed.text)"
    $argvLines = @()
    if (Test-Path -LiteralPath $stubLog) { $argvLines = @(Get-Content -LiteralPath $stubLog | Where-Object { $_ }) }
    Chk '场景21 age 被调用两步（先解救援身份，再用它解封账本）' ($argvLines.Count -eq 2) `
        "实得 $($argvLines.Count) 行: $($argvLines -join ' / ')"
    # 「有没有 -i 这个参数」按 token 比，不拿正则扫整行：`recovery-identity.enc` 里就躺着一个
    # `-i` 子串，扫整行的那条断言在第一发调用上会**假报「带了 -i」**（反过来说它恒真＝死断言）
    $tok0 = if ($argvLines.Count -ge 1) { @(Tokens $argvLines[0]) } else { @() }
    $tok1 = if ($argvLines.Count -ge 2) { @(Tokens $argvLines[1]) } else { @() }
    Chk '场景21 第一步不带 -i（口令走终端，不经 argv）' (@($tok0 | Where-Object { $_ -eq '-i' }).Count -eq 0) `
        "tokens: $($tok0 -join ' ')"
    Chk '场景21 第二步才带 -i（用第一步解出来的救援身份解封账本）' (@($tok1 | Where-Object { $_ -eq '-i' }).Count -eq 1) `
        "tokens: $($tok1 -join ' ')"
    $secretToks = @($argvLines | ForEach-Object { @(Tokens $_) } | Where-Object { $_ -eq '-p' -or $_ -eq '--passphrase' })
    Chk '场景21 凭据纪律：argv 里没有口令类参数' (@($secretToks).Count -eq 0) "实得: $($argvLines -join ' / ')"
    Chk '场景21 桩吐出的救援身份明文没落在夹具目录里（WORK 之外）' (
        @(Get-ChildItem -LiteralPath $script:root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'recovery-identity.txt' }).Count -eq 0) ''

    # ---------- 场景 22：明文面清扫（隐私红线 §1.1 + 凭据纪律 §1.2 的落盘面）----------
    # 扫两处：夹具根（-Base 与恢复材料都在这儿，实现若把明文写在快照目录/夹具里就是漏盘）与
    # 系统临时目录（rescue.ps1 的 WORK 落点）。
    # **测不到的一面如实登记**：Open-Ledger 内部那句「救援身份明文用完即删」在这两条扫里
    # 恒真——外层 finally 会连整个 WORK 目录一起删掉，摘掉内层 Remove-Item 也留不下痕迹。
    # 那一处靠代码读与 §不覆盖 台账，不拿它冒充变异验证过的覆盖。
    $plainNames = @('manifest.json', 'recovery-identity.txt')
    $leavable = @(Get-ChildItem -LiteralPath $script:root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in $plainNames })
    # 临时目录**只扫本工具形状的 WORK**（bg-rescue-<32hex>），不整棵递归 /tmp 或 RUNNER_TEMP：
    # 同一轮 CI 里别的夹具也可能产出叫 manifest.json 的东西，整棵扫会把它们的文件报成我们的漏盘
    $workLeft = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^bg-rescue-[0-9a-f]{32}$' })
    $leavable = @($leavable) + @(foreach ($w in $workLeft) {
        Get-ChildItem -LiteralPath $w.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in $plainNames }
    })
    Chk '场景22 夹具根与残留 WORK 里都没有解封出来的明文（清单/救援身份）' (@($leavable).Count -eq 0) `
        "残留: $(@($leavable) | ForEach-Object { $_.FullName } | Select-Object -First 3 | Out-String)"
    Chk '场景22 临时工作目录用完删掉（白名单守卫没把自己漏在外面）' ($workLeft.Count -eq 0) `
        "残留: $(($workLeft | ForEach-Object { $_.Name }) -join ' ')"
    $pwLeak = @(Get-ChildItem -LiteralPath $script:root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -lt 200KB -and (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($script:pw) })
    Chk '场景22 口令没落进任何文件（rescue 不写日志）' ($pwLeak.Count -eq 0) `
        "命中: $(($pwLeak | ForEach-Object { $_.FullName }) -join ' ')"

    # ---------- 场景 23：非 ASCII 契约行的自警（拿一个中文目录名喂进契约行）----------
    # 这条测的是 Write-Contract 自己的闸门：路径里出现非 ASCII 时必须如实打告警行，
    # 而不是让守卫在同一条码页坑上静默假通过（rescue.ps1 文件头那条口径的反面）
    $cnDir = Join-Path $script:root ('中文目录-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [void][System.IO.Directory]::CreateDirectory($cnDir)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $cnDir 'restic-files'))
    $cn = Invoke-Rescue -ChildArgs @('-List', '-Base', $cnDir, '-Restic', $noBin)
    Chk '场景23 契约行含非 ASCII 时自打告警' ($cn.text -match 'rescue: WARN contract-line-has-non-ascii') `
        "text=$($cn.text)"

    # ---------- 场景 24：整份脚本在宿主上解析得动（语法面；5.1 那一步的主判据之一）----------
    $toks = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script:rescuePs, [ref]$toks, [ref]$errs)
    Chk '场景24 rescue.ps1 解析 0 错误' (@($errs).Count -eq 0) "实得 $(@($errs).Count) 条: $(@($errs) | ForEach-Object { $_.Message } | Select-Object -First 2)"
}

# ---------- 静态接线：产品面没被写成死代码（口径同 A2a/⑧ 的接线断言）----------
$srcRescue = Get-Content -Raw $script:rescuePs
Chk '静态 rescue.ps1 里没有 rclone sync（红线 §1.4）' ($srcRescue -notmatch 'rclone\s+sync') ''
# 「每个原生命令调用点都在 EAP=Continue 的作用域里」这件事**由探针事实 5 逐点判**（AST 定作用域，
# 正则给不出答案）。这里只钉接线：rescue.ps1 必须在它扫的文件清单里。
# 为什么不再是「数 `$script:ResticBin` 出现几次」：那种断言在实现把调用点合并/改名后照样绿，
# 而清单里漏一个文件时它什么都看不见——它测的是文本，不是规则真跑过。
$probePs = Join-Path $Repo 'probe_windows_ps51.ps1'
$probeSrc = if (Test-Path -LiteralPath $probePs -PathType Leaf) { Get-Content -Raw $probePs } else { '' }
Chk '静态 探针文件在仓库里（不在就等于这条规则没跑，不许静默绿）' ("$probeSrc".Length -gt 0) $probePs
$eapLine = @($probeSrc -split "`n" | Where-Object { $_ -match '^\$eapFiles\s*=' } | Select-Object -First 1)
Chk '静态 探针事实 5 的文件清单里有 rescue.ps1' (
    @($eapLine).Count -eq 1 -and $eapLine[0].IndexOf('rescue.ps1', [System.StringComparison]::Ordinal) -ge 0) `
    "实得: $(($eapLine | Out-String).Trim())"

Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail -gt 0) {
    Write-Host "RESCUE-E2E-FAIL count=$script:fail skipped=$(@($script:skipped).Count)"
    exit 1
}
Write-Host "RESCUE-E2E-OK skipped=$(@($script:skipped).Count)"
