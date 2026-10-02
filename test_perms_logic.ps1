# test_perms_logic.ps1 —— backup.ps1 的权限面归一化（Set-PrivateAcl）逻辑 + 行为测试
#
# 怎么跑（本机无 pwsh；容器里跑的是 `.sh` 桩那一支 + 逻辑断言，真 icacls 只有 windows runner 走得到）：
#   docker run --rm -v "$PWD":/repo:ro --entrypoint /bin/bash \
#     mcr.microsoft.com/powershell:lts -lc 'pwsh -NoProfile -File /repo/test_perms_logic.ps1'
# 在 Windows runner 上（CI 那一步）：pwsh -NoProfile -File test_perms_logic.ps1
# 期望最后一行 PERMS-LOGIC-OK skipped=1；真 icacls 那一段在非 Windows 上整段 Skip 并如实标注。
#
# **为什么这一发值得单独写**：Windows 上新建的目录一律从父目录**继承** DACL，而 %APPDATA% /
# %LOCALAPPDATA% / %USERPROFILE% 的默认继承里都带着 `BUILTIN\Users`——也就是说在真机上
# `secrets.env`（restic 口令）与 `age\` 私钥目录同机别的账号读得到。bash 侧那一课的原话是
# 「点名式清单注定还要漏」（补了 `*.log` 就漏 `age/` 子目录，10-01 真机实测），产品因此改成整树
# 归一化；ps1 侧此前**一次都没做过**这件事，AGENTS §2 的权限面那条只覆盖 bash。
#
# 分工：桩负责 argv 逐字、非致命分档、成功流干净；**真 icacls** 负责「继承真的断开、子项真的跟着
# 变」——桩只会告诉我它被叫什么，不会告诉我 DACL 变成了什么。
#
# 不覆盖的（在这里注册，别假装覆盖）：
#   - 容器里没有 icacls，所以「断开继承后子项靠动态继承跟上」这一整段只有 windows runner 拿得到
#     证据（场景6）。这不是可选项：它正是这条产品面成立与否的全部理由。
#   - 「别人还能不能靠所有者/备份特权读进去」不在断言里——同机管理员本来就能 take ownership，
#     这条面挡的是**同机普通账号的顺手遍历**，与 bash 侧 0700/0600 同口径。
#   - 不测 Task Scheduler 换账号运行的后果（产品假设注册用户 = 建目录用户）。
#
# 变异台账（摘 backup.ps1 的实现、这份必须报 FAIL；跑法同其它 logic 套件的规矩）：
#   m01 摘掉 /inheritance:r              CAUGHT（1 条：场景1 argv 逐字）
#   m02 /grant:r → /grant                CAUGHT（1 条：场景1 argv 逐字）
#   m03 grant 去掉 (OI)(CI)              CAUGHT（1 条：场景1 argv 逐字）
#   m04 icacls 非零改成 throw            CAUGHT（1 条：场景2「只告警不抛」）
#   m05 只告警不记 bad                   CAUGHT（1 条：场景2「失败的那棵树进了 bad 清单」）
#   m06 引擎输出摘掉 | Out-Host          CAUGHT（1 条：场景1「applied 两棵、bad 空」——chatter
#                                        混进返回流后 `$bad` 那一路的计数直接失真）
#   m07 去掉「树不存在就跳过」           CAUGHT（1 条：场景3「跳过的那棵没被叫给 icacls」，实得 2 行）
#   m08 夜间那一轮的调用点整条摘掉       CAUGHT（1 条：场景5「两处调用点都在」，实得 1 处）
#   m09 清单少写第四棵树                 CAUGHT（1 条：场景5「清单里有第四棵树」）
#   m10 函数首句 EAP=Continue 摘掉       CAUGHT（1 条：场景4 那句静态钉）
#   m11 SID 写死成 Administrators        CAUGHT（1 条：场景4「SID 由 WindowsIdentity 现取」）
#   m12 catch 的告警文本不含 [perms]      CAUGHT（1 条：场景5「调用点包在 try/catch 里」）
#   合计 12/12 CAUGHT、0 MISS。
#   **两刀第一次交回的是 qemu 的 rc=139（容器环境崩了，不是断言没咬住）**：m04、m07 各重跑一次才
#   落账（m04 -> 场景2「只告警不抛」实得 threw=[perms] icacls rc=1；m07 -> 场景3「跳过的那棵没被
#   叫给 icacls」实得 2 行）。裸 rc 不是结论，判定看 ^FAIL 行并重试（AGENTS §3）。
#   **两条删除型变异（m07/m10）第一轮交回的是 UNDETERMINED，而病灶在变异脚本自己身上**：
#   存活探针写的是「替换后的第一行要在树上」，删除型变异的替换是空串，于是探针恒假——
#   变异其实落上了。删除型的探针口径是**「原文真的不在了」+「守卫仍能按哨兵切出函数」**
#   （后半条防的是「切歪了所以什么都没断言」这种假 CAUGHT）。这与 AGENTS §3 分诊表里
#   「变异脚本自己也必须 set -e 并验落上」是同一条规矩在**删除型**上的具体形状。
param([string]$Repo = '')
if (-not $Repo) { $Repo = $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:fail = 0
# 条件参数**不收 [bool]**：`-match` 的左操作数是命令表达式时走集合语义、返回匹配到的元素，
# 绑不进 [bool]（口径与由来见 test_retention_logic.ps1 头部与 AGENTS §3 分诊表④）。
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
. ([scriptblock]::Create((Slice 'PERMS')))
Chk '切出了被测函数' ($null -ne (Get-Command Set-PrivateAcl -ErrorAction SilentlyContinue))

$script:isWin = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
$script:root = Join-Path ([System.IO.Path]::GetTempPath()) ("bgperms-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:root | Out-Null

# ---------- 桩：把 argv 记进 STUB_LOG，rc 由开关文件决定 ----------
# 开关与日志都放在**树外面**（$script:root 下）：被测函数会对「树目录本身」跑 icacls，
# 一个住在被测对象里的开关会跟着被改 DACL——场景2 的 rc 因此得能整轮不变。
$script:stubExt = if ($script:isWin) { 'cmd' } else { 'sh' }
$script:stubPath = Join-Path $script:root ("icacls-stub." + $script:stubExt)
$script:stubRc = Join-Path $script:root 'stub.rc'
$script:stubLog = Join-Path $script:root 'stub-argv.log'
[System.IO.File]::WriteAllText($script:stubRc, '0')
if ($script:isWin) {
    @(
        '@echo off'
        # `%*>>` 之间不许有空格：`echo %* >> f` 会把重定符前那个空格一起写进文件，argv 逐字断言
        # 当场差一个尾空格（10-02 的 retention 套件事先在 windows runner 上红在这里，形状抄自
        # test_integrity_logic.ps1 那份已跑绿的桩）。
        'echo %*>> "%STUB_LOG%"'
        'echo stub-chatter-to-stdout'
        'set RC=0'
        'set /p RC=<"%STUB_RC%"'
        'exit /b %RC%'
    ) | Out-File -FilePath $script:stubPath -Encoding ascii
} else {
    @(
        '#!/bin/sh'
        'printf "%s\n" "$*" >> "$STUB_LOG"'
        'echo stub-chatter-to-stdout'
        'exit "$(cat "$STUB_RC")"'
    ) | Out-File -FilePath $script:stubPath -Encoding ascii
    try { chmod 755 $script:stubPath } catch { }
}
function Set-StubRc([int]$Rc) { [System.IO.File]::WriteAllText($script:stubRc, "$Rc") }
function Clear-StubLog { Remove-Item -LiteralPath $script:stubLog -Force -ErrorAction SilentlyContinue }
function StubCalls {
    if (-not (Test-Path -LiteralPath $script:stubLog)) { return @() }
    @(Get-Content -LiteralPath $script:stubLog)
}
function New-Tree([string]$Name) {
    $p = Join-Path $script:root $Name
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    $p
}
# 返回值与抛出的异常一起收：少收一条流就有断言恒假，而「函数抛终止性异常被上层 catch 降成
# warning」与「压根没被调用」在产物上长得一模一样（AGENTS §1.3 同一条）。
# 外层保持 Stop：这正是产品要证明的那一档——它自己作用域里压回 Continue，所以不该有任何东西抛出来。
function Run-Perms([string[]]$Trees, [string]$Sid = 'S-1-5-21-TESTSID') {
    $env:STUB_LOG = $script:stubLog
    $env:STUB_RC = $script:stubRc
    $got = $null
    $threw = ''
    try {
        $got = & Set-PrivateAcl -Tree $Trees -Sid $Sid -IcaclsBin $script:stubPath
    } catch {
        $threw = $_.Exception.Message
    }
    @{ r = $got; threw = $threw }
}

# ---------- 场景1：argv 逐字（这是这条面「到底做了什么」的唯一现场证据） ----------
Clear-StubLog
$t1 = New-Tree 't1'
$t2 = New-Tree 't2'
$r = Run-Perms -Trees @($t1, $t2)
$calls = StubCalls
Chk '场景1 每棵树各调一次引擎' ($calls.Count -eq 2) "实得 $($calls.Count) 行"
$want1 = "$t1 /inheritance:r /grant:r *$($r.r.sid):(OI)(CI)F"
Chk '场景1 argv 逐字：树 /inheritance:r /grant:r "*<SID>:(OI)(CI)F"' ($calls[0] -eq $want1) "实得: [$($calls[0])]"
Chk '场景1 第二棵树用的是同一个 SID' `
    ($calls[1] -eq "$t2 /inheritance:r /grant:r *$($r.r.sid):(OI)(CI)F") "实得: [$($calls[1])]"
Chk '场景1 结论交回调用点（applied 两棵、bad 空）' `
    ($r.r.applied.Count -eq 2 -and @($r.r.bad).Count -eq 0) "实得 applied=$($r.r.applied.Count) bad=$(@($r.r.bad).Count)"
Chk '场景1 成功流只有一个结果对象（引擎 stdout 没混进返回流）' `
    ($r.r -is [hashtable]) "实得类型: $(if ($r.r) { $r.r.GetType().Name } else { 'null' })"
$chatter = @((($r.r | ConvertTo-Json -Depth 4) -split "`n") | Where-Object { $_ -match 'stub-chatter' })
Chk '场景1 桩吐的那行 stdout 不在返回值里' ($chatter.Count -eq 0) `
    '返回流里混进任何一行引擎输出，调用点对 applied/bad 的判定就失真（与 Push-TreeToCloud 同一课）'

# ---------- 场景2：非致命分档（icacls 失败＝维持原状，不许把整轮带走） ----------
Clear-StubLog
Set-StubRc 1
$t3 = New-Tree 't3'
$r2 = Run-Perms -Trees @($t3)
Set-StubRc 0
Chk '场景2 icacls 非零只告警不抛（旁路没资格终止本体，§1.3）' ($r2.threw -eq '') "实得 threw=$($r2.threw)"
Chk '场景2 失败的那棵树进了 bad 清单（只报不记＝调用点无从改结论）' `
    (@($r2.r.bad).Count -eq 1 -and $r2.r.bad[0] -eq $t3) "实得 bad=$($r2.r.bad -join ',')"
Chk '场景2 失败时 applied 为空（两档不许同时计数）' (@($r2.r.applied).Count -eq 0)

# ---------- 场景3：不存在的树不判失败，但也不叫引擎 ----------
Clear-StubLog
$ghost = Join-Path $script:root 'no-such-tree'
$r3 = Run-Perms -Trees @($ghost, $t1)
$c3 = StubCalls
Chk '场景3 没建的树整棵跳过（首备前的日志树本来就不存在）' ($r3.threw -eq '') "实得 threw=$($r3.threw)"
Chk '场景3 跳过的那棵没被叫给 icacls' ($c3.Count -eq 1) "实得 $($c3.Count) 行: $($c3 -join ' | ')"
Chk '场景3 跳过既不算成功也不算失败' `
    ($r3.r.applied.Count -eq 1 -and @($r3.r.bad).Count -eq 0) "实得 applied=$($r3.r.applied.Count)"

# ---------- 场景4：SID 的来源与 grant 形状（产品不许写死 SID） ----------
$fnBody = Slice 'PERMS'
Chk '场景4 SID 由 WindowsIdentity 现取（写死一条＝别人机器上把别的账号收成唯一授权对象）' `
    ($fnBody -match 'WindowsIdentity\]::GetCurrent\(\)')
Chk '场景4 现取只在调用方没给时发生（守卫要能注入假 SID，否则场景1 绑不出真值）' `
    ($fnBody -match 'if \(-not \$Sid\)')
Chk '场景4 grant 串的形状是 "*<SID>:(OI)(CI)F"（OI/CI 是让整棵树跟着继承的关键，摘掉它只有根被收紧）' `
    ($fnBody -match '\*\$\{Sid\}:\(OI\)\(CI\)F')
Chk '场景4 5.1 宿主口径：函数里那句 EAP=Continue 在位（icacls 的报错写在 stderr）' `
    ($fnBody -match '\$ErrorActionPreference = "Continue"')

# ---------- 场景5：调用点（函数在但没人调＝产物上跟没写一样） ----------
$idxFn = $script:srcPs1.IndexOf('function Set-PrivateAcl')
$callsites = @([regex]::Matches($script:srcPs1, 'Set-PrivateAcl -Tree'))
Chk '场景5 定义在（位置取不到就是守卫自己崩，先问取不取得到）' ($idxFn -gt 0) "def=$idxFn"
Chk '场景5 两处调用点都在：夜间那一轮 + 初始化向导（口令是在向导里第一次落盘的）' `
    ($callsites.Count -ge 2) "实得 $($callsites.Count) 处"
$idxStart = $script:srcPs1.IndexOf('function Start-PartiverseBackup')
$lenMain = if ($idxStart -gt 0) { [Math]::Min(4000, $script:srcPs1.Length - $idxStart) } else { 0 }
$bodyMain = if ($idxStart -gt 0) { $script:srcPs1.Substring($idxStart, $lenMain) } else { '' }
$iNew = $bodyMain.IndexOf('New-Item -ItemType Directory -Force -Path $CONF_DIR')
$iPerms = $bodyMain.IndexOf('Set-PrivateAcl -Tree')
# 锚点取**语句**而不是 `secrets.env` 这个词：本函数自己的注释里就写着「读 secrets.env 之前」，
# 拿词当锚点会先撞上注释（10-02 第一版就是这样，把一条真在位的顺序断言跑成 FAIL）
$iSecrets = $bodyMain.IndexOf('Test-Path "$CONF_DIR\secrets.env"')
Chk '场景5 主函数里排在建目录之后（对不存在的树跑 icacls 等于每次都告警）' `
    ($iNew -ge 0 -and $iPerms -gt $iNew) "New-Item=$iNew perms=$iPerms"
Chk '场景5 主函数里排在读 secrets.env 之前（敞口最短那一段时间）' `
    ($iPerms -ge 0 -and $iSecrets -gt $iPerms) "perms=$iPerms secrets=$iSecrets"
$lenCall = if ($iPerms -gt 0) { [Math]::Min(240, $bodyMain.Length - $iPerms) } else { 0 }
$callTail = if ($iPerms -gt 0) { $bodyMain.Substring($iPerms, $lenCall) } else { '' }
Chk '场景5 清单里有第四棵树（默认仓库根的父目录：工具 bin 就住在 $BACKUP_BASE 之外）' `
    ($callTail -match 'USERPROFILE') '点名清单漏一项就是「age 子目录可遍历」那一课（§2 权限面）'
Chk '场景5 调用点包在 try/catch 里（旁路的异常不许带走本体）' `
    ($callTail -match '\[perms\]') '告警文本是 catch 那一条的证据'

# ---------- 场景6：真 icacls 那一支（只有 windows runner 走得到） ----------
# 比较口径全部落在 **SID** 上：Get-Acl 的 IdentityReference 在 Windows 上通常已经翻成账号名
# （`MACHINE\user`、`NT AUTHORITY\SYSTEM`），而 WindowsIdentity 给的是 SID，拿名字比 SID 会把
# 「自己」也算成外人——那是一条**只有 windows runner 才露头**的假失败（10-02 第一版就是这么写的）。
function Sid-Of($Ref) {
    # 已经是 SID 时**别**调 Translate（同类型自转会抛 InvalidCastException）
    if ($Ref -is [System.Security.Principal.SecurityIdentifier]) { return $Ref.Value }
    try { $Ref.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $Ref.Value }
}
function Ace-Sids([string]$Path) {
    @((Get-Acl -LiteralPath $Path).Access | ForEach-Object { Sid-Of $_.IdentityReference })
}
function Foreign-Sids([string]$Path, [string[]]$Allow) {
    @(Ace-Sids $Path | Where-Object { $Allow -notcontains $_ })
}

if ($script:isWin) {
    $self = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $usersSid = 'S-1-5-32-545'    # BUILTIN\Users：真机上 %APPDATA% 的默认继承里带着的那一条
    $allow = @($self, 'S-1-5-18', 'S-1-5-32-544')   # SYSTEM/Administrators 留着不算敞口：本来就能 take ownership，与 bash 侧 0700 同口径

    # 夹具**自己造出**要防的那个起点，而不是赌 runner 镜像的默认 DACL：给外层目录显式授给 Users，
    # 里面两棵树从它继承——被测函数面对的形状与真机上 secrets.env 的祖父目录一致。不铺这一层，
    # 「起点是空的」会让下面几条断言恒真（AGENTS §3：夹具必须与生产同形）。
    $seed = New-Tree 'seed'
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # 5.1 下 icacls 写 stderr 会变成终止性异常（§2 宿主口径）
    & icacls $seed '/grant' "*${usersSid}:(OI)(CI)(RX)" | Out-Null
    $seedRc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    if ($seedRc -ne 0) {
        Skip '场景6 真 icacls 那一支' "种子 icacls rc=$seedRc：铺不出「Users 也读得到」的起点，这一支没有证据（没有证据不等于通过）"
    } else {
        $real = Join-Path $seed 'real'
        New-Item -ItemType Directory -Force -Path $real | Out-Null
        $child = Join-Path $real 'sub'
        New-Item -ItemType Directory -Force -Path $child | Out-Null
        $secretFile = Join-Path $child 'secrets-like.txt'
        Set-Content -LiteralPath $secretFile -Value 'x'
        Chk '场景6 夹具真的造出了「同机别人也读得到」的起点（起点是空的＝下面几条恒真，测不到东西）' `
            (((Ace-Sids $real) -contains $usersSid) -and ((Ace-Sids $child) -contains $usersSid))

        $res = $null
        $threw = ''
        try { $res = & Set-PrivateAcl -Tree @($real) } catch { $threw = $_.Exception.Message }
        Chk '场景6 真 icacls 跑成不抛（抛了就是 5.1 宿主语义没兜住）' ($threw -eq '') "实得 threw=$threw"
        if ($res) {
            $fRoot = @(Foreign-Sids $real $allow) -join ','
            $fChild = @(Foreign-Sids $child $allow) -join ','
            Chk '场景6 根与子项都只剩许可名单里的账号（Users 那条继承得被断开）' `
                ($fRoot.Length -eq 0 -and $fChild.Length -eq 0) "实得 根=[$fRoot] 子项=[$fChild]"
            Chk '场景6 收紧之后根上仍有自己（把自己挡在外面＝下一轮备份直接失败）' `
                ((Ace-Sids $real) -contains $self)
            Chk '场景6 子项没被烤死：靠动态继承跟着变（这正是整棵树一次调用就归一的前提）' `
                ((Get-Acl -LiteralPath $child).AreAccessRulesProtected -eq $false)
            Chk '场景6 文件也跟着变（口令文件住在子项里，不是树根）' `
                (-not ((Ace-Sids $secretFile) -contains $usersSid))
            $writeOk = $true
            try { Add-Content -LiteralPath $secretFile -Value 'y' } catch { $writeOk = $false }
            Chk '场景6 自己仍然写得进去' $writeOk
        }
    }
} else {
    Skip '场景6 真 icacls 那一支' '本机是非 Windows：断开继承与动态继承这两件事只有 windows runner 能证'
}

if ($script:fail -gt 0) {
    Write-Host "=== PERMS-LOGIC-FAIL fail=$($script:fail) skipped=$($script:skipped.Count) ==="
    exit 1
}
Write-Host "=== PERMS-LOGIC-OK skipped=$($script:skipped.Count)（Skip 的理由逐条在上面，末行不许只报 OK 而不报未测） ==="
exit 0
