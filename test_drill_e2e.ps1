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
#   密封里真带了 sha256（场景1g 读的是 `[manifest] drill-hash n/N` 那行现场信号——锚点必须是
#   ASCII，10-03 windows step 12 实测 5.1 上那行的中文段读不出来而同一轮 hashed=6 全对，
#   n=0 就是整段退化），
#   演练里真按它比内容（场景2 换掉一个哈希必须当场露）。
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
#   ⑩取回的字节保真（10-03 第五轮，行为面）：夹具自己做一个含 NUL 与非法 UTF-8 序列的 1 KiB 文件，
#     路径带空格与 `[01]`，另放一条**同名同尺寸、内容不同**的诱饵进同一个快照，然后按产品调用点
#     同形地调一次 Dump-DrillFile。判四件事：退出码 0（引号内的空格没把 argv 切成两项）、落盘字节数
#     = 报告字节数 = 源尺寸、头 6 字节逐字节原样、内容哈希等于**指定的那条**而不等于诱饵。
#     这一节换掉的是原来的「argv 桩钉 --include 形状」——桩测的是字符串，而这一发真正会坏的是字节
#     （PowerShell 把原生命令 stdout 落盘的顺手写法一律按文本重编码，见 semantic.ps1 的注释）。
#   ⑪取回侧三档坏法的**可诊断性**（静态面）：dump 退出码档（带归档内路径）/ 字节数档（清单 vs 取回）/
#     「仅比大小」档，三条各占一句且不许并回一句；旧的合并消息与旧的「退出 0 但没挑中这条」都不许回来。
#   ⑫取回**机制**本身的契约（静态面，10-03 第五轮 re-ground）：stdout 必须走 `.BaseStream.CopyTo`、
#     不许用 `Start-Process` 重定向、不许回到 `restore --target`、前导斜杠补回那一句在位、
#     参数拼法不许用 5.1 没有的 `ArgumentList`、取证行 [drill-dump] 带 rc 与字节数。
#     判「代码里有没有 X」之前先**整行剥注释**（这份文件的注释里就写着被禁的那几个词），
#     并给剥离本身配一条存活判据（剥完必须还认得出被测函数）。
#   ⑬取回落点的逃生探测 + 归档内路径真身（行为面）：夹具拿一条真样本、按产品调用点同形地跑一次
#     Dump-DrillFile，对整棵临时树做**路径差分**——指定的那个文件之外出现任何新路径都是
#     「演练写到别处」的确证（真机上＝覆盖用户活着的源文件，数据面事故）。同一段差分再拿一个
#     诱饵文件跑第二次，必须报出它，这才是上面那条判据的存活证据。两条与形状无关、因此两档宿主
#     都可判的判据：`restic ls` 交回的归档内路径必须与组装出的那条**逐字同形**（少补/多补前导斜杠
#     在这里露），且落盘字节数必须等于清单尺寸（引擎退 0 而产物是空的＝另一种坏法）。
#
# **不覆盖**（如实登记）：
#   - Windows 上归档内路径带盘符那一种形状（`C:/…` 被 restic 存成 `C/Users/…`，于是清单里的 path
#     是真归档路径的**后缀**）。容器造不出盘符，这一支由 windows job 用同一份夹具跑：场景11/13 的
#     判据都不拿字面量形状当判据，而是**当场向 `restic ls` 取真身再逐字比**，所以它在两档宿主上判
#     的是同一件事。（10-03 之前这一支只能靠 argv 桩钉实现契约，因为 `--include` 是模式不是路径，
#     posix 上加不加前导斜杠等价——换成 `dump` 之后它降级成「容器只会绿、真宿主才红」的普通档。）
#   - `Arguments` 字符串里路径含**单引号**时 posix 的 .NET 解析会把它当定界符切开（登记在
#     semantic.ps1 的注释里）。生产这一档只跑在 Windows（Go 的 argv 解析不认单引号），夹具的临时
#     路径也不含它，所以两档宿主都测不到——不是「测过没事」。
#   - age 对 passphrase 只读终端的交互解封（恢复码路径 B，CI 打不了字；由 init-keys/rescue 那两份
#     守卫以桩证调用序列）。
#   - 网盘（123Pan WebDAV）语义：场景10 的「云端」是本地目录 + 真 rclone，不是 WebDAV。
#
# 变异台账（口径：一刀一份独立工作树 + 回读校验落刀 + 改动后的三份文件先过解析；判据取
# **首条 FAIL 是不是这一刀主张的那件事**，不只看 rc。驱动 `backguard-native:drill` 容器，
# 每刀日志落在挂进容器的宿主目录 /tmp/bg-mut-r{5,6,7}-*/<id>/run.log——容器内 /tmp 随容器消失）。
#
# **10-03 第五轮（取回机制换成 `restic dump`）在当前代码上重跑 25 刀：24 CAUGHT + 1 逃逸登记**
# （m33 是刀本身磨错，重磨为 m33b 已咬住）。旧编号里钉住实现落在本轮 diff 范围内的都换了新编号
# 重跑（映射见下）；m14/m15 的被测文件 `backup.ps1` 本轮一行未改，沿用其结论；
# m10/m11/mA/mB/m16–m21 **随机制一起作废**，逐条写明原因——留着条目不写原因就是死刀。
#
# —— 本轮新刀（m27–m39：dump 机制本身 + 三档判据 + 场景12/13 的自证）：
#   m27 stdout 换成文本读法（`ReadToEnd` + `UTF8.GetBytes`）→ 场景11 落盘字节数：disk=2056
#       reported=2056（1024 B 的二进制被重编码撑成两倍），同刀再咬头 6 字节 `00 EF BF BD …`
#   m28 argv 去掉每项各自的引号 → 场景11 dump 退出码 rc=1（路径里的空格把一项切成多项）
#   m29 摘掉前导斜杠补回 → 场景13 「组装出的路径与 restic ls 逐字同形」（internal 少一个 `/`），
#       同一条在场景11 也红——两档宿主都可判，这是换机制换来的最大一处覆盖面
#   m30 机制换回 `restore --include --target` → 场景1 无失败项
#   m31 参数拼法换成 `ArgumentList` → 场景12 静态那条（5.1 的 .NET Framework 没有这个属性）
#   m32 差分「见过就跳过」换成「恒跳过」→ 场景13 差分判据是活的（decoy_hits=0）
#   m33 前缀判据 `-eq 0` 换成 `-ge 0`——**ESCAPED，刀本身磨错**：`IndexOf` 找不到时给 -1，
#       `-ge 0` 照样放行诱饵，测的是「换个语义」而不是「恒真」。落刀前先问「替换后的表达式恒吗」
#   m33b m33 重磨为 `-ge -1`（恒真）→ 场景13 差分判据是活的 + 诱饵真的点名到自己
#   m34 靶子不写回原字节 → 场景13 靶子已写回原字节（夹具不许自己留脏基线，后面几段靠它）
#   m35 归档内路径真身换成 `restic snapshots`（不交路径）→ 场景13 restic ls 交出归档内路径
#   m36 取证行整段 `if ($env:BACKUP_LOG)` → `if ($false)` → 场景1 取证行真的落进 backup.log。
#       **这一刀只有行为面抓得到**：静态面读的是源码，那行始终在（旧编号 m22 的同一条主张）
#   m37 同名同尺寸诱饵换成别的扩展名（于是不在快照内）→ 场景11 两条都在归档里
#   m38 场景12 的注释剥离换成「全留」（`{ $true }`）→ 「上一版『退出 0 但没挑中这条』不许回来」
#       这一档负判据的**分母自证**：剥离如果把被测函数也剥掉了，「代码里没有 X」就恒真
#   m39 头 6 字节换成纯 ASCII（`ABCDEF`）→ 只有场景11 头 6 字节那条红——证明 NUL/非法 UTF-8
#       才是文本通道那一维的靶子，换成 ASCII 靶子就消失了
#
# —— 本轮重跑的旧刀（新编号 ← 旧编号；钉住实现落在本轮改过的 `Invoke-Drill` / 密封侧）：
#   m40 ← m13 摘掉尺寸闸门（`$res.bytes -ne [long]$ssize` → `$false`）→ 场景4 尺寸不符当场露
#   m42 ← m03 内容哈希只验「算得出」不比值 → 场景2 判定为失败
#   m43 ← m12 「仅比大小：清单未记内容哈希」标注砍短 → 场景4 每条 PASS 都写明依据
#   m44 ← m04 抽不到条目改写成 `RESULT: 0 PASS / 0 FAIL` → 场景4 抽不到条目判失败
#   m46 ← m06 缺料三查（age / 主身份 / 密封件）整段短路 → 场景5 快照目录没密封件 → Code=20
#   m47 ← m07 样本仓库不按类别查（拿第一个仓库硬解）→ 场景1 无失败项（跨类别错配）
#   m48 ← m01 密封侧不带 `--hash-drill-samples` → 场景1 内容哈希这一维真的生效（hashed=0）
#   m49 ← m02 splat 退回带括号的 `@($hashArgs)` → 场景1 结论行五个计数都解析得出
#       这一刀就是首轮那个真 bug：三个参数粘成一个 argv，bg 的报错与「参数真没被认出来」逐字同形；
#       现场写出的是 `RESULT: FAIL（sample 没抽到条目…）`——「密封成功」那道自报什么都没证明
#   m50 ← m05 摘掉 30 天节流闸门 → 场景3 刚跑过 → Code=10
#   m51 ← m08 判定改回「整行含 FAIL」→ 场景7 a-只有汇总行0失败 want=False
#   m52 ← m09 结论行缺失/两行不判失败 → 场景7 c-结论行缺失 want=True
#
# —— 现场信号行的 **ASCII 锚点**（`drill-hash`）本身也在被测面内（10-03，5.1 那一步实测之后立的）：
#   m53 摘掉 bg 的那句 print（`[manifest] drill-hash n/N …` 整行消失）
#       → 本夹具两条一起红：场景1「现场信号那行真的进了备份日志」+ 场景4「第二轮的日志里没有
#          记哈希那行 count=0」；bash 车道同时红在 `test_drill_e2e.sh:107`（E2E-FAIL「生产
#          seal_manifest 没记下任何源哈希」）。count=2 skipped=0。
#   m54 锚点换回纯中文旧措辞（`[manifest] 演练样本内容哈希：n/N 个已记入密封清单`）
#       → 红的还是那两条，而 bash 车道的报错里**带着那行中文原文**（`…：[manifest] 演练样本
#          内容哈希：6/7 个已记入密封清单`）——这就是「判据确实落在锚点上，不是落在那件事上」
#          的证据：内容一模一样、只是没有 ASCII 锚点，守卫就判败。
#       为什么要有 m54 这一刀：10-03 真 windows runner 的 step 12（Windows PowerShell 5.1）上，
#       同一轮 `hashed=6 / sizeOnly=0`（这两个数来自 drill 解封后的报告，不来自日志）证明密封侧
#       真记上了哈希，而 backup.log 里按中文匹配的那两条断言双双落空。那一行是 bg 的 stderr 经
#       `2>> $env:BACKUP_LOG` 落进日志的唯一产物，缘故是 5.1 把**子进程的 stderr 按控制台代码页
#       解码之后**才写盘，中文段落进去已不是原字节（机制是这一档宿主的已知行为、与现场对得上；
#       **逐字节形态没在这轮量过**——要量的得在 5.1 上把那行的字节打出来，而这一发改的是锚点，
#       不依赖那串中文还在）。真机部署走 `powershell.exe -File backup.ps1`（Task Scheduler），
#       也就是说**在恰好最容易记 0 条哈希的那台宿主上，这行唯一的现场信号会先从日志里读不出来**
#       ——所以修的是产品那行的锚点，不是教守卫去猜乱码。`verify-nightly.sh` 反过来两种措辞都认
#       （部署树 5fb2c79 今晚还吐旧那行），那是版本漂移容忍，不是判据松掉。
#
# —— 沿用（被测文件本轮一行未改，`git status` 只有三行）：
#   m14 `--exclude` 根本没拼进 rclone 命令行 → 场景10 rescue-test.txt 没上云
#   m15 时间轴调用点漏登记排除名（推送函数照旧，只有接线漏）→ 场景10 调用点登记了排除名
#       这两刀钉的是 `backup.ps1`；catcher 只有静态那条抓得到「函数对、接线错」这一类
#
# —— 作废（钉住的实现随机制一起没了）：
#   m10 `--include` 强制前导斜杠 → 旧场景11 的 argv 桩。桩测的是字符串，而 posix 上加不加前导
#       斜杠在 restic 那里**等价**（10-03 实测两种写法都取回得到），这一刀在容器里本来就咬不住；
#       换成 dump 之后同一维由 m29 接管（对着 `restic ls` 逐字比，两档宿主可判），桩整个删除
#   m11 取回命中改按文件名相等（不按后缀）→ dump 没有「挑哪一条」这一步，落点就是我们给的路径
#   mA  后缀判定锚到不可能的前缀 / mB restore 加一个不存在的开关 → 都是 `restore` 时代的分档证据；
#       引擎报错那一档现在由 m28（行为面：rc≠0 当场可见）+ 场景12（静态面：消息写法）两头顶住
#   m16–m18 三档消息「不许并回一句」的旧写法 → 场景12 里同名判据换了新文案，等价的坏法由
#       m30/m31/m38 覆盖
#   m19–m21 落地树枚举取证（`landed=N` / 枚举不许带 `-File` / target 为空时列父目录）→ dump 只有
#       一个落点、没有第二套计数，这三行连消息一起从产品里删了；场景12 的反断言钉「不许回来」
#
# **登记测不到的两支**（不变）：①「取回不许写到指定落点之外」这条判据在容器里恒绿——容器里
#   restic 不逃，真 windows runner 才是它的现场；②`cache13` 那档排除防的是**假报警**，容器那一轮
#   一个新条目都不产生，所以它没有对应的红刀。两支都由 windows job 那一档宿主负责，别当已覆盖。
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
    # 取证行**真的写出去了**才算数：Dump-DrillFile 那段 Add-Content 包在 `try { … } catch { }`
    # 里（旁路不许把演练带走，§1.3），所以「写失败」与「这一轮没跑取回」在日志里同形。
    # 场景1 走的是真 restic、真 BACKUP_LOG，这一条是这条写路径唯一的行为面证据。
    Chk '场景1 取回取证行真的落进 backup.log（catch 吞掉的写失败在这里露）' `
        $logText.Contains('[drill-dump] rc=')

    # 现场回显：这一份守卫在真 windows runner 上红过一次（10-03 第二轮 13 条 FAIL），而 CI 日志
    # 里只有「DRILL-E2E-FAIL count=13」和一句分不开成因的 FAIL 行——断言判红却没有证据，
    # 下一轮还是盲的。所以**判红就把自己看到的两件事打到 stdout**：报告里逐条 FAIL 行
    # （现在是「restic dump 退出码≠0（带组装出的归档内路径）」／「大小不符（带两边字节数）」
    # ／「内容哈希不符（带清单值与取回值）」三档），以及 $env:BACKUP_LOG 里 Dump-DrillFile
    # 落的 [drill-dump] 行（rc / bytes / internal / out / stderr 尾巴）。
    # 这不是断言，不改结论；它只保证「红的那一轮」在日志里可读。
    if (Test-Path -LiteralPath $rtPath -PathType Leaf) {
        $failLines = @((Read-U8 $rtPath) | Where-Object { $_.StartsWith('FAIL ') })
        if ($failLines.Count -gt 0) {
            Write-Host "--- 现场：rescue-test.txt 逐条 FAIL（$($failLines.Count) 条）---"
            $failLines | ForEach-Object { Write-Host $_ }
            $logLines = @($logText -split "`n")
            $diag = New-Object System.Collections.Generic.List[string]
            for ($li = 0; $li -lt $logLines.Count; $li++) {
                if ($logLines[$li].Contains('[drill-dump]')) { $diag.Add($logLines[$li]) }
            }
            Write-Host "--- 现场：backup.log 的 [drill-dump] 行（$($diag.Count) 条）---"
            $diag | Select-Object -Last 90 | ForEach-Object { Write-Host $_ }
        }
    }
    # 锚点取 `drill-hash`（ASCII）而不是那行中文：10-03 真 windows runner 的 step 12（Windows
    # PowerShell 5.1）实测——同一轮 hashed=6 全对，而这两处按中文匹配的断言双双报红；缘故是 5.1 把
    # bg 的 stderr 按控制台代码页解码后才写进 backup.log，中文段落进去已不是原字节（逐字节形态未量，
    # 见文件头台账 m54）。判据落在两档宿主都保得住的那一段上（口径同 rescue.ps1 的 ASCII 契约行）。
    $hm = [regex]::Match($logText, '\[manifest\] drill-hash (\d+)/(\d+)')
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

        # 同一份无哈希清单再把**大小**改错：这一支走的是「大小不符」那一档，与内容哈希
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
    $hashLines2 = @([regex]::Matches((Read-U8 $env:BACKUP_LOG) -join "`n", '\[manifest\] drill-hash '))
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

    # ---------- 场景13：取回落点与归档内路径形状——探测（10-03 第四轮的差分机，第五轮换被测面）----------
    # 上一轮这一段是为了回答「restic 报 Restored 9 / 1 而 target 之下只枚举到 3 个目录，文件到底
    # 落到哪儿去了」。答案（真 windows runner，轮 37093574349）：**没落到 target 之外**
    # （escaped=0，活文件字节没变），而是短 target（95 字符）那一次真的落了 9 个条目含 1 个文件、
    # 长 target（132 字符，与产品同形）那一次只有 3 个——差别只有 target 长度，成因未定。
    # 产品侧已改用 `restic dump`，根本不拼目录树，所以这一段的判据跟着换两件事，而**逃生探测留着**：
    #  ① 落点判据变成「只写我们指定的那一个文件」：整棵临时树差分，target 之外（out 文件与
    #     backup.log 之外）出现任何新路径都是「演练写到别处」的确证——真机上那是覆盖用户活文件的
    #     那类事故。探测本身只读：除被测那一次 Dump-DrillFile 之外只跑 `restic ls`（§2「探测=只读」）。
    #  ② **组装出的归档内路径与 `restic ls` 逐字相同**：这一条把「前导斜杠」那一维变成两档宿主都
    #     可判——上一轮它只能靠 argv 钉（posix 上 restic 对加不加前导斜杠等价，真引擎抓不到），
    #     而 `dump` 要的是**精确路径**：`ls` 交出的是引擎认的那条真身（posix `/tmp/…`、
    #     Windows `/C/Users/…`），代码少补一个斜杠就当场不同形，两档宿主都红。
    #  ③ 存活证据照旧：同一段差分拿诱饵文件再跑一次必须报出它，否则「escaped=0」与「差分自己是死的」
    #     在日志里同形。
    #  ④ 靶子=夹具自己的源文件（写一次性标记再跑取回，标记消失＝被写回活路径的确证）；测完写回原字节。
    $d13 = New-Dir 'probe13'
    $plain13 = Join-Path $d13 'manifest.json'
    $u13 = Run-Native @($script:age, '-d', '-i', $keys.ident, '-o', $plain13, $encPath)
    Chk '场景13 探测前解封出带哈希的那份清单' `
        ($u13.rc -eq 0 -and (Test-Path -LiteralPath $plain13 -PathType Leaf)) $u13.text
    $s13 = $null
    if ($u13.rc -eq 0) {
        # 与产品同一个 sample 调用（Invoke-Drill 用的就是它），不自己拼清单条目——否则
        # 「sample 交出的 path 形状」这一维又回到没被测
        $p13Txt = (@(Invoke-Bg sample --manifest $plain13 --count 99 2>$null) -join "`n")
        $p13 = $null
        try { $p13 = ConvertFrom-Json $p13Txt } catch { $p13 = $null }
        $knownCls = @($script:drillItems | ForEach-Object { "$($_.cls)" })
        foreach ($cand in @(if ($p13 -and $p13.samples) { $p13.samples })) {
            if ($knownCls -contains "$($cand.class)") { $s13 = $cand; break }
        }
    }
    Chk '场景13 抽到一条类别在册的样本' ($null -ne $s13) "path=$(if ($s13) { $s13.path } else { '' })"
    if ($s13) {
        $cls13 = "$($s13.class)"
        $inc13 = "$($s13.path)"
        $name13 = $inc13.Substring($inc13.LastIndexOf('/') + 1)
        if ($name13.IndexOf('\') -ge 0) { $name13 = $name13.Substring($name13.LastIndexOf('\') + 1) }
        $item13 = @($script:drillItems | Where-Object { "$($_.cls)" -eq $cls13 }) | Select-Object -First 1
        # 活路径只能按「类别 → 夹具给自己那个类别建的源目录 → 文件名」拼回来：
        # 拿清单里的 path 直接当文件系统路径用正是被测的那个假设，用它当靶子位置等于预设答案。
        $live13 = Join-Path $srcOf[$cls13] $name13
        Chk '场景13 活着的源文件在位（逃生靶子）' (Test-Path -LiteralPath $live13 -PathType Leaf) "live=$live13"
        $bytes13 = [System.IO.File]::ReadAllBytes($live13)
        $marker13 = 'escape-probe-' + [guid]::NewGuid().ToString('N')
        Write-U8 $live13 ($marker13 + "`n")
        $out13 = Join-Path $d13 'dump-13.bin'
        # restic 的 cache 目录在 $env:LOCALAPPDATA（夹具把它指进临时树），它不属于演练的取回面，
        # 差分必须把它摘掉——否则「cache 新建了一个 pack 子目录」会被报成逃生，判据就废了。
        $cache13 = $env:LOCALAPPDATA
        $cwdC13 = Join-Path (Get-Location).Path 'C'
        $cmp13 = if ($script:isWin) { [System.StringComparer]::OrdinalIgnoreCase } `
                 else { [System.StringComparer]::Ordinal }
        $seen13 = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList $cmp13
        foreach ($p in @(Get-ChildItem -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue)) {
            [void]$seen13.Add("$($p.FullName)")
        }
        $baseCount13 = $seen13.Count
        $cwdHadC13 = Test-Path -LiteralPath $cwdC13 -PathType Container
        $repoHadC13 = Test-Path -LiteralPath (Join-Path $Repo 'C') -PathType Container

        # 就这一次：与产品调用点逐字同形（semantic.ps1 的 Dump-DrillFile 调用）
        $res13 = Dump-DrillFile -Bin $script:restic -Repo "$($item13.repo)" -Snap "$($item13.snap)" `
            -ArchivePath $inc13 -OutFile $out13

        $new13 = @(); $cache13New = 0
        foreach ($p in @(Get-ChildItem -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue)) {
            $fn = "$($p.FullName)"
            if ($seen13.Contains($fn)) { continue }
            if ($fn.IndexOf($out13, [System.StringComparison]::OrdinalIgnoreCase) -eq 0) { continue }
            if ($cache13 -and $fn.IndexOf($cache13, [System.StringComparison]::OrdinalIgnoreCase) -eq 0) {
                $cache13New++
                continue
            }
            $new13 += $fn
        }
        $esc13 = @($new13)
        $dumpBytes13 = if (Test-Path -LiteralPath $out13 -PathType Leaf) {
            ([System.IO.File]::ReadAllBytes($out13)).Length } else { -1 }
        $cwdCNow13 = Test-Path -LiteralPath $cwdC13 -PathType Container
        $repoCNow13 = Test-Path -LiteralPath (Join-Path $Repo 'C') -PathType Container
        $liveTxt13 = try { [System.IO.File]::ReadAllText($live13) } catch { '' }
        $liveHit13 = (-not $liveTxt13.Contains($marker13))

        # 回显先于断言：红了的那一轮必须在 CI 日志里看得见落点，光有 count 分不开三种坏法
        Write-Host ("# p13 rc=" + $res13.rc + " archive-path=" + $inc13)
        Write-Host ("# p13 internal=" + $res13.internal + " internal_len=" + "$($res13.internal)".Length)
        Write-Host ("# p13 out=" + $out13 + " out_len=" + $out13.Length +
            " bytes_on_disk=" + $dumpBytes13 + " bytes_reported=" + $res13.bytes +
            " escaped=" + $esc13.Count + " cache_dir_new=" + $cache13New +
            " tree_base=" + $baseCount13)
        foreach ($e in @($esc13 | Select-Object -First 10)) { Write-Host "# p13 escaped-path: $e" }
        Write-Host ("# p13 cwd=" + (Get-Location).Path + " cwd_C_dir=" +
            $(if ($cwdCNow13) { "yes(before=$cwdHadC13)" } else { 'no' }) +
            " repo_C_dir=" + $(if ($repoCNow13) { "yes(before=$repoHadC13)" } else { 'no' }))
        Write-Host ("# p13 live_marker_survived=" + $(if ($liveHit13) { 'no' } else { 'yes' }))
        $ls13 = Run-Native @($script:restic, '-r', "$($item13.repo)", 'ls', "$($item13.snap)")
        $lsName13 = @($ls13.lines | Where-Object { $_.Contains($name13) })
        Chk '场景13 restic ls 交出归档内路径（dump 要的精确路径就以它为准）' `
            (@($lsName13).Count -ge 1) "rc=$($ls13.rc) lines=$(@($lsName13).Count)"
        foreach ($l in @($lsName13 | Select-Object -First 3)) { Write-Host "# p13 internal-path: $l" }
        # 逐字同形（大小写差一档宿主不背：Windows 归档内路径的大小写由 restic 存的那一刻定）
        $lsSame13 = @($lsName13 | Where-Object {
            $_.Length -eq "$($res13.internal)".Length -and
            $_.IndexOf("$($res13.internal)", [System.StringComparison]::OrdinalIgnoreCase) -eq 0 })
        Chk '场景13 组装出的归档内路径与 restic ls 逐字同形（少补/多补前导斜杠在这里露）' `
            (@($lsSame13).Count -ge 1) "internal=$($res13.internal) ls=$(@($lsName13 | Select-Object -First 2) -join ' | ')"

        Chk '场景13 取回只写指定的那一个文件（别处出现新条目＝演练写到用户活路径的前半）' `
            (@($esc13).Count -eq 0) "escaped=$(@($esc13).Count) first=$(if (@($esc13).Count -gt 0) { $esc13[0] } else { '' })"
        Chk '场景13 取回不许覆盖活着的源文件（数据面事故，与取证无关）' (-not $liveHit13) `
            "live=$live13 marker_gone=$liveHit13"
        Chk '场景13 盘符段没被当成相对路径写进当前目录或源码树' `
            (($cwdHadC13 -or (-not $cwdCNow13)) -and ($repoHadC13 -or (-not $repoCNow13))) `
            "cwd_C=$cwdCNow13 repo_C=$repoCNow13"
        Chk '场景13 取回真的写满字节（0 或 -1＝引擎退 0 而产物是空的，那是另一种坏法）' `
            ($dumpBytes13 -eq [long]$s13.size -and $res13.bytes -eq $dumpBytes13) `
            "on_disk=$dumpBytes13 reported=$($res13.bytes) manifest_size=$($s13.size) rc=$($res13.rc)"

        # 对照：同一段差分换个「一定算新生」的输入再跑一次。这一条两档宿主都必须绿，
        # 它是上面那条落点判据的存活证据——没有它，escaped=0 与差分死掉长得一模一样。
        $decoy13 = New-Dir 'decoy13'
        $decoyFile13 = Join-Path $decoy13 'planted.txt'
        Write-U8 $decoyFile13 'planted by the guard, not by restic'
        $decoyHit13 = @()
        foreach ($p in @(Get-ChildItem -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue)) {
            $fn = "$($p.FullName)"
            if ($seen13.Contains($fn)) { continue }
            if ($fn.IndexOf($out13, [System.StringComparison]::OrdinalIgnoreCase) -eq 0) { continue }
            if ($cache13 -and $fn.IndexOf($cache13, [System.StringComparison]::OrdinalIgnoreCase) -eq 0) { continue }
            $decoyHit13 += $fn
        }
        Chk '场景13 差分判据是活的（诱饵文件必须被报成新生）' `
            (@($decoyHit13).Count -ge 1) "decoy_hits=$(@($decoyHit13).Count) escaped_above=$(@($esc13).Count)"
        Chk '场景13 诱饵真的点名到自己（差分不是只报一个数）' `
            (@($decoyHit13 | Where-Object { $_.IndexOf($decoyFile13, [System.StringComparison]::OrdinalIgnoreCase) -eq 0 }).Count -eq 1)

        # 收尾：靶子写回原字节，夹具不留脏状态（后面几段与场景8 的清扫都要干净基线）
        [System.IO.File]::WriteAllBytes($live13, $bytes13)
        $back13 = [System.IO.File]::ReadAllBytes($live13)
        Chk '场景13 靶子已写回原字节（夹具自己不许留改过的源文件）' `
            ($back13.Length -eq $bytes13.Length -and -not ([System.IO.File]::ReadAllText($live13)).Contains($marker13))
        Remove-Item -LiteralPath $decoy13 -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $plain13 -Force -ErrorAction SilentlyContinue
    }
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

# ---------- 场景11：dump 的三件事——字节保真 / 怪名字 / 精确路径（真引擎；10-03 第五轮换被测面）----------
# 这一节整段换掉是机制变更的结果，不是补断言。上一版用 argv 桩钉 `--include` 的形状，理由是
# 「加不加前导斜杠」在 posix 上真引擎分不开（restic 两种写法都接受），变异在容器里必然逃逸；
# 换成 `restic dump` 之后这一维由场景13 的「组装出的路径与 restic ls 逐字同形」承担，两档宿主
# 都可判，桩就没了存在理由。更要紧的是**桩测错了对象**：它钉「拼出来的字符串长什么样」，而这一发
# 真正会坏的是**字节**——PowerShell 把原生命令 stdout 落盘的所有「顺手写法」都按文本重编码
# （10-03 容器实测：600 B 二进制经 `Start-Process -RedirectStandardOutput` 变成 1187 B，多出来
# 的全是逐个替换出来的 EF BF BD），于是内容哈希永远不符，而 restic 自己一个字都没错。
# 三件事各自对应一种坏法：
#  ① 字节保真：内容里放 NUL 与非法 UTF-8 序列（FF FE 80、截断的 C3 28）。任何文本通道都会改它们。
#  ② 怪名字：目录名与文件名都含空格，文件名另带 `[01]`——AGENTS §2「判断字面量路径永远别用
#     -like」那一维的被测面。换成正则或通配的实现当场红（`[01]` 在 -like 里是字符类、在正则里是
#     字符集），而引号内的空格是 argv 切分的经典靶子。
#  ③ 同名同尺寸诱饵：另一棵子树里一条**同名、同尺寸、内容不同**的文件，两条都在同一个快照内。
#     「按后缀挑一条」的实现挑中哪一半没有证据；dump 只认精确路径，所以哈希必须等于指定那条。
if (-not $script:haveReal) {
    Skip '场景11（需要真 restic）' 'deps missing：字节保真、怪名字路径与同名诱饵三支都测不到'
} else {
    $env:RESTIC_PASSWORD = $script:pw   # Dump-DrillFile 不传口令，靠的就是进程环境（同生产那条）
    $binSrc = New-Dir 'bin-src'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $binSrc 'space dir'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $binSrc 'other'))
    $pat11 = New-Object 'byte[]' 1024
    $pat11d = New-Object 'byte[]' 1024
    for ($i = 0; $i -lt 1024; $i++) {
        $pat11[$i] = [byte](($i * 7 + 3) -band 0xFF)
        $pat11d[$i] = [byte](($i * 7 + 4) -band 0xFF)
    }
    # 前 6 字节钉成「任何文本编码通道都过不去」的那几种：NUL、FF FE 80（UTF-8 非法）、C3 28（截断）
    $head11 = @(0x00, 0xFF, 0xFE, 0x80, 0xC3, 0x28)
    for ($i = 0; $i -lt $head11.Count; $i++) { $pat11[$i] = [byte]$head11[$i] }
    # 名字逐字相同、尺寸逐字相同、内容逐字节不同——「仅比大小」那一档在这一对文件上是死的
    $tgt11 = Join-Path (Join-Path $binSrc 'space dir') 'a b [01].bin'
    $decoy11f = Join-Path (Join-Path $binSrc 'other') 'a b [01].bin'
    [System.IO.File]::WriteAllBytes($tgt11, $pat11)
    [System.IO.File]::WriteAllBytes($decoy11f, $pat11d)
    $repo11 = Join-Path (New-Dir 'bin-repo') 'r11'
    $i11 = Run-Native @($script:restic, '-r', $repo11, 'init')
    $b11 = Run-Native @($script:restic, '-r', $repo11, 'backup', $binSrc)
    Chk '场景11 夹具：怪名字的两条二进制文件真的进了快照' `
        ($i11.rc -eq 0 -and $b11.rc -eq 0) "init=$($i11.rc) backup=$($b11.rc) $($b11.text)"
    $snap11 = Get-LatestSnap $repo11
    Chk '场景11 快照 id 取到（取不到时下面每条都红，先把它单独钉住）' ([bool]$snap11) "snap=$snap11"
    $ls11 = Run-Native @($script:restic, '-r', $repo11, 'ls', $snap11)
    $sameName11 = @( @($ls11.lines) | Where-Object { $_.Contains('a b [01].bin') } )
    Chk '场景11 同名同尺寸的两条都在归档里（诱饵必须在快照内，不在磁盘上）' `
        (@($sameName11).Count -eq 2) ($sameName11 -join ' | ')
    $one11 = @( @($sameName11) | Where-Object { $_.Contains('space dir') -and $_.StartsWith('/') } )
    Chk '场景11 指定的那一条在 ls 里唯一（两条同名，按后缀挑的实现分不开）' `
        (@($one11).Count -eq 1) ($one11 -join ' | ')
    $internal11 = if (@($one11).Count -eq 1) { [string]@($one11)[0] } else { '' }
    if ($internal11) {
        # 喂进去的是**清单那一档形状**：ls 交出带前导斜杠的真身，bg 的 _norm_path 把斜杠剥掉，
        # 所以「剥掉再喂」才是产品调用点收到的参数，「组装时补回来」才是被测的那一句。
        $fed11 = $internal11.Substring(1)
        $out11 = Join-Path (New-Dir 'bin-out') 'dumped.bin'
        $res11 = Dump-DrillFile -Bin $script:restic -Repo $repo11 -Snap $snap11 `
            -ArchivePath $fed11 -OutFile $out11
        $got11 = if (Test-Path -LiteralPath $out11 -PathType Leaf) {
            [System.IO.File]::ReadAllBytes($out11) } else { New-Object 'byte[]' 0 }
        Write-Host ("# p11 internal=" + $internal11 + " len=" + $internal11.Length)
        Write-Host ("# p11 rc=" + $res11.rc + " reported=" + $res11.bytes +
            " on_disk=" + $got11.Length + " out=" + $out11)
        Chk '场景11 dump 退出码 0（空格与方括号在引号内是字面量，没被切成两项）' `
            ($res11.rc -eq 0) "rc=$($res11.rc) internal=$($res11.internal)"
        Chk '场景11 组装的归档内路径逐字回到 ls 那条（少补前导斜杠在这里露）' `
            ($res11.internal.Length -eq $internal11.Length -and
                $res11.internal.IndexOf($internal11, [System.StringComparison]::Ordinal) -eq 0) `
            "got=$($res11.internal) want=$internal11"
        Chk '场景11 落盘字节数 = 报告字节数 = 源文件字节数（文本重编码会把 1024 变成别的数）' `
            ($got11.Length -eq 1024 -and [int]$res11.bytes -eq 1024) `
            "disk=$($got11.Length) reported=$($res11.bytes)"
        Chk '场景11 取回件头 6 字节原样（NUL 与非法 UTF-8 被换成 EF BF BD＝走了文本通道）' `
            ($got11.Length -gt 5 -and $got11[0] -eq 0 -and $got11[1] -eq 0xFF -and
                $got11[2] -eq 0xFE -and $got11[3] -eq 0x80 -and $got11[4] -eq 0xC3 -and
                $got11[5] -eq 0x28) `
            $(if ($got11.Length -gt 5) { ($got11[0..5] | ForEach-Object { $_.ToString('X2') }) -join ' ' } else { 'too short' })
        $shaTgt11 = (Get-FileHash -Algorithm SHA256 -LiteralPath $tgt11).Hash
        $shaDec11 = (Get-FileHash -Algorithm SHA256 -LiteralPath $decoy11f).Hash
        $shaGot11 = if ($got11.Length -gt 0) { (Get-FileHash -Algorithm SHA256 -LiteralPath $out11).Hash } else { '' }
        Chk '场景11 取回内容与指定的那一条逐字节相同（哈希，不只尺寸）' `
            ($shaGot11 -eq $shaTgt11) "got=$shaGot11 want=$shaTgt11"
        Chk '场景11 取回的不是那条同名诱饵（两条同尺寸同名，只有精确路径分得开）' `
            ($shaGot11 -ne $shaDec11 -and [bool]$shaGot11) "got=$shaGot11 decoy=$shaDec11"
    }
}

# ---------- 场景12：取回机制与三档判据的契约（纯静态，恒跑；10-03 第五轮 re-ground 到 dump）----------
# 为什么这一维只能静态钉：它钉的是「不许退回上一版的坏法」，而三种坏法在合并消息下逐字同形——
# 10-03 第二轮真 windows runner 的 13 条 FAIL 就是靠一句「restic 退出码≠0 **或**没挑中这条」把两件
# 不同的事混成一件，下一轮仍是盲的。行为面已各自量过：引擎报错 → 「restic dump 退出码…没解出来」
# （场景1 全链路 + 假开关那刀）；字节不满 → 「大小不符：清单…取回…B」（改尺寸那刀）；
# 清单未记哈希 → 「仅比大小…」（场景5 的缺料调用）。这里钉的是**写法不许合回去**，
# 以及机制本身（这三种坏法都是换机制才修掉的，所以机制写法也在被测面内）。
# 只扫 semantic.ps1——bash 侧 semantic.sh 那句合并消息仍在（posix 没有盘符形状，两种坏法在那边
# 本来就分不出来），扫它是误伤同事的实现。
# **整行注释先剥掉再判「代码里有没有 X」**（AGENTS §2 立过的口径）：这份文件的注释里就写着
# `restore --include --target` 与 `Start-Process -RedirectStandardOutput`（那两段是「为什么不用它」
# 的论证），不剥的话下面三条负判据恒假——恒假的负判据与「实现违规」在日志里都是同一句红。
$drillSrcAll = Read-U8 $semPs
$drillSrc = @( $drillSrcAll | Where-Object { -not $_.TrimStart().StartsWith('#') } ) -join "`n"
# 剥离自身的存活证据：剥完还得认得出被测函数在。否则「代码里没有 --target」可能只是因为
# 整份被剥空了——那是一条恒真的负判据（同场景13 的诱饵对照，一个道理）。
Chk '场景12 剥注释后被测函数仍在（负判据的分母没被剥掉）' $drillSrc.Contains('function Dump-DrillFile')
Chk '场景12 引擎报错那一档单独成行（带归档内路径，不只带 rc）' `
    ($drillSrc.Contains('dump 退出码') -and $drillSrc.Contains('$($res.internal)'))
Chk '场景12 字节那一档单独成行（清单尺寸 vs 取回字节）' `
    ($drillSrc.Contains('大小不符') -and $drillSrc.Contains('取回 $($res.bytes) B'))
Chk '场景12 「只比大小」那一档仍在（清单未记哈希时不许冒充按内容比过）' `
    $drillSrc.Contains('仅比大小：清单未记内容哈希')
Chk '场景12 旧的合并消息不许回来' (-not $drillSrc.Contains('（取回失败或大小不符）'))
Chk '场景12 上一版「退出 0 但没挑中这条」那一档不许回来（枚举已删，留着就是死消息）' `
    (-not $drillSrc.Contains('没挑中这条'))
Chk '场景12 rc 与字节数不许并成一条判据' (-not ($drillSrc -match '\$res\.rc -ne 0 -or'))
Chk '场景12 stdout 走字节通道 BaseStream（文本读法会重编码；行为面证据在场景11）' `
    $drillSrc.Contains('.BaseStream.CopyTo')
Chk '场景12 不许改用 Start-Process 重定向落盘（10-03 实测它把 600 B 变成 1187 B）' `
    (-not $drillSrc.Contains('Start-Process'))
Chk '场景12 不许回到 restore --target（Windows 上落点与枚举分不开的那一版）' `
    (-not $drillSrc.Contains('--target'))
Chk '场景12 前导斜杠补回那一句在位（dump 要精确路径；行为面在场景13 与 ls 逐字比）' `
    $drillSrc.Contains("StartsWith('/')")
Chk '场景12 参数拼法不许换成 ArgumentList（5.1 的 .NET Framework 上没有这个属性）' `
    (-not $drillSrc.Contains('ArgumentList'))
Chk '场景12 取证行落在 backup.log（[drill-dump] 带 rc 与字节数）' `
    ($drillSrc.Contains('[drill-dump] rc=') -and $drillSrc.Contains('bytes='))

Result-Line
