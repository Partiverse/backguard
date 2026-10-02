# test_cloud_verify_logic.ps1 —— backup.ps1 的 A6 云端副本自证逻辑测试
#
# 怎么跑（本机无 pwsh，用 Linux 容器里的 pwsh 7）：
#   docker run --rm -v "$PWD":/repo:ro -v /tmp/rbin:/rbinst:ro --entrypoint /bin/bash \
#     mcr.microsoft.com/powershell:lts -lc 'PATH=/rbinst:$PATH pwsh -NoProfile -File /repo/test_cloud_verify_logic.ps1'
# **别把 rclone 挂到 /opt**：那个镜像的 pwsh 就装在 /opt 下，挂上去等于把 pwsh 藏了（10-02 实测
#   `exec: pwsh: executable file not found in $PATH`）。rclone 二进制按 uname 取 arm64/amd64。
# 在 Windows runner 上（CI 那一步）：pwsh -NoProfile -File test_cloud_verify_logic.ps1
#   ——runner 上没有 rclone，需要网盘的那几段会自己如实 Skip，不是假通过。
# 期望最后一行 CLOUD-VERIFY-LOGIC-OK；变异验证同 bash 侧规矩（见文末台账）。
#
# **为什么这里的「云端」是真的 rclone 而不是桩**：这一层的被测面就是「rclone 的实际输出
# 形状 + 实际退出码 + 实际比较依据」。桩只会返回脚本想要的那种形状，把「lsl 的字段顺序变了」
# 「copyto 读不到时 rc=3」「同尺寸不同内容时不带 -I 就静默跳过」这三类全遮掉——而它们恰好是
# 这份自证存在的全部理由（AGENTS §2「E2E 夹具要与生产同形」）。所以：
#   - 纯逻辑（清单解析、集合比较、目录取样、报告落笔）不需要 rclone，容器里就能全跑；
#   - 需要网盘的那几条把「云端」做成**本地目录**，用真 rclone 读写它，rclone 不在 PATH 时
#     整段如实 Skip（绝不报成通过）。
# 不覆盖的（10-02 容器实测，别再写成「已复刻」）：真实 WebDAV 的大小写不敏感与「比较只看
#   size」是**网盘**行为。本地目录当云端复现不了它——实测同尺寸、不同内容、且把目标 mtime 调成
#   更新 / 相同 / 更旧三种关系，不带 `-I` 的 `rclone copy` **全都照样覆盖**（本地↔本地能两端
#   各算一次哈希，比较依据根本不是 size）。所以 m7（摘掉 `-I`）与 m8（拿 `copy` 退出 0 当
#   「修好了」）在这里**行为面咬不住**，只有场景 10 的两条静态断言抓得到；行为面的证明在
#   bash 侧 `test_cloud_verify.sh`（rclone 桩在 `cat` 上撒谎，§3/§7 那两段）。
#
# 变异台账（摘 backup.ps1 的实现、这份必须报 FAIL；10-02 实测逐条标注，驱动见会话记录的
# /tmp/mut_ps1_verify.py——每条都先校验变异真的落上了工作树副本才跑）：
#   m1 `-replace '://'` 那步摘掉              → 场景2 归一化不符
#   m2 lsl 解析按空格切第 4 段起（改成 `(-split '\s+')[3]`）→ 场景3 带空格的路径被截断
#   m3 Compare 改成双向相等（云端多出也算缺）  → 场景4 假报缺失 + 场景8a「只增不减」那条变红
#   m4 Get-VerifyDirSample 返回原路径          → 场景5 直接露出文件名 + 场景8b 的隐私断言变红
#   m5 Get-LocalObjectMap 的 rescue-test.txt 排除摘掉 → 场景6 本地那份进了清单
#   m6 报告汇总行 checks 用写死的 0            → 场景7 计数对不上
#   m7 forcing 补传的 `-I` 摘掉              → 场景10 的**静态**断言（行为面在本地目录复现不了
#      「只看大小」那条跳过，见开头「不覆盖的」——这条是静态抓住，不是行为面，别把它当成
#      网盘语义已验证）
#   m8 「重新读回核对」改成「copy 退出 0 就算修好」 → 实测**行为面咬不住**：真 rclone 补传成功时
#      内容真的变了，独立复读照样一致。只有让 `copyto` 撒谎的桩能造（bash 侧 §7 就是这么测的），
#      所以这里靠场景10 那条静态断言：HEALED 之前必须有一次 `Get-VerifyCloudHash`
#   m9 隐私检查改读本地清单（而不是云端那份）    → 场景8c 假绿
#   m10 自证失败仍让整轮退 0（红线 §1.4）        → 场景10 「$verifyFailed -gt 0 分支体内必须给 RunRc=1」
#   m11 `FULLY COMPLETE` 移到自证判定之前        → 场景10 的 IndexOf 先后断言
#   m12 推送点不用共用 `Format-CloudDest`、自己再拼一遍 → 场景1 的计数断言（归一化只许一处）
#   m13 云端清单读不到时判 FAIL（把网盘抖动报成失败）→ 场景8d/8e/9 的 UNKNOWN 断言
#   已知**测不到**的一支：`Test-VerifyConfigHash` 里「强制补传之后云端 config 反而读不到了」
#   那条 UNKNOWN——要走到它得让第一次读成功、第二次读失败，真 rclone 在两次调用之间不会自己变
#   哑；只有让 `cat`/`copyto` 撒谎的桩能造（bash 侧 test_cloud_verify.sh 就是这么测的）。
#   在这里注册为「真实二进制测不到」，不假装覆盖。同理场景8h（补传后仍不一致 → FAIL）在 Linux
#   宿主上造不出「写不进去的云端文件」（rclone 非原地写 + root 无视只读位），它按探测结果如实 Skip。
param([string]$Repo = '')
if (-not $Repo) { $Repo = $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:fail = 0
function Chk([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "ok   - $name $detail" }
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
        throw "哨兵 # BEGIN-$Tag / # END-$Tag 在 backup.ps1 里没成对出现——生产改了标记，这份守卫必须先炸，不能安静地测一段旧代码"
    }
    $m.Groups[1].Value
}
. ([scriptblock]::Create((Slice 'VERIFY')))
Chk '切出了被测函数' ($null -ne (Get-Command Invoke-CloudVerify -ErrorAction SilentlyContinue) `
    -and $null -ne (Get-Command Test-VerifyPrefix -ErrorAction SilentlyContinue))

$srcPs1 = Get-Content -Raw (Join-Path $Repo 'backup.ps1')

# ---------- 工具：真 rclone + 种子文件 ----------
$script:hasRclone = $null -ne (Get-Command rclone -ErrorAction SilentlyContinue)
function RC([string[]]$RcloneArgs) {
    # 原生命令的 stderr 在 5.1 + EAP=Stop 下会变成终止性异常，这里按产品的同一口径局部降到
    # Continue——否则「网盘报错」这一档在守卫里炸成异常，而不是 UNKNOWN
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & rclone @RcloneArgs 2>$null
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $eap
    [pscustomobject]@{ Rc = $rc; Out = @($out) }
}
function Seed([string]$Dir, [string]$Name, [int]$Bytes) {
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
    $p = Join-Path $Dir $Name
    [System.IO.File]::WriteAllBytes($p, (New-Object byte[] $Bytes))
    return $p
}
function Reset-And([string]$Root) {
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
}

$T = Join-Path ([System.IO.Path]::GetTempPath()) ("bgcv-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $T | Out-Null

try {
# ---------- 1：目标地址只有一处拼法 ----------
# 推送与自证必须算出同一个地址；两处各写一遍归一化，就是「自证读了一个云端从没被写过的地址」
# 并判 FAIL 那一类（A2b 的「记哈希的抽样与 drill 的抽样必须共用一个函数」同条教训）。
Chk '场景1 Format-CloudDest 归一 remote:// ' `
    ((Format-CloudDest -Target 'remote://root' -SystemId 'dev' -Sub 'config') -eq 'remote:root/dev/config') `
    "实得 $((Format-CloudDest -Target 'remote://root' -SystemId 'dev' -Sub 'config'))"
Chk '场景1 Format-CloudDest 普通 remote: 子路径' `
    ((Format-CloudDest -Target 'Backguard:/bak' -SystemId 'dev' -Sub 'timeline') -eq 'Backguard:/bak/dev/timeline')
$destCalls = @([regex]::Matches($srcPs1, 'Format-CloudDest\s+-Target')).Count
Chk '场景1 推送与自证三处都走同一个拼法' ($destCalls -ge 3) "实得 $destCalls 处调用"
$inlineNorm = @([regex]::Matches($srcPs1, "-replace\s+[`"']://[`"']")).Count
Chk '场景1 归一化没有第二处实现' ($inlineNorm -le 1) "源码里 '://' 归一出现 $inlineNorm 次（只许 Format-CloudDest 内部那一处）"

# ---------- 2/3：lsl 输出的解析形状 ----------
$lsl = @(
    '    12 2026-10-02 17:48:48.174754104 a.txt',
    '     1 2026-10-02 17:48:48.175037186 sub/b.txt',
    '  1234 2026-10-02 09:00:00.000000000 2026/10/02/0234-tag/MANIFEST copy.txt',
    'Transferred:    1.5 KiB / 1.5 KiB, 100%, 0.000 KiB/s, ETA 0s',
    ''
)
$m2 = ConvertFrom-RcloneLsl -Lines $lsl
Chk '场景2 三行真 lsl 都进了清单' ($m2.Count -eq 3) "实得 $($m2.Count): $($m2.Keys -join ', ')"
Chk '场景3 路径里的空格没被当字段分隔' ($m2.ContainsKey('2026/10/02/0234-tag/MANIFEST copy.txt') `
    -and [long]$m2['2026/10/02/0234-tag/MANIFEST copy.txt'] -eq 1234)
Chk '场景3 非清单行（进度/空行）不算对象' (-not ($m2.Keys | Where-Object { $_ -match 'Transferred' }))

# ---------- 4：单向包含——云端多出来的是本地已裁的历史副本 ----------
$locMap = @{ 'a.txt' = 10; 'b/c.txt' = 20 }
$cldMap = @{ 'a.txt' = 10; 'b/c.txt' = 20; '2025/old/keepme.txt' = 5; 'extra.bin' = 9 }
$cmp = Compare-VerifyMaps -Local $locMap -Cloud $cldMap
Chk '场景4 云端多出两份不算失败' ($cmp.Missing.Count -eq 0 -and $cmp.Mismatch.Count -eq 0 -and $cmp.Extra -eq 2) `
    "missing=$($cmp.Missing.Count) mismatch=$($cmp.Mismatch.Count) extra=$($cmp.Extra)"
$cmp2 = Compare-VerifyMaps -Local @{ 'a.txt' = 10; 'x/y.txt' = 7 } -Cloud @{ 'a.txt' = 11 }
Chk '场景4 缺失与尺寸不符分开计数' ($cmp2.Missing.Count -eq 1 -and $cmp2.Mismatch.Count -eq 1 -and
    $cmp2.Missing -contains 'x/y.txt' -and $cmp2.Mismatch -contains 'a.txt') `
    "missing=$($cmp2.Missing -join ',') mismatch=$($cmp2.Mismatch -join ',')"

# ---------- 5：差异样本只到目录（红线 §1.1） ----------
$ds = Get-VerifyDirSample -Paths @('2026/10/02/0234-tag/MY-SECRET-NAME.txt', '2026/10/02/0234-tag/STORY.md',
    'a/b/c.bin', 'd/e/f.bin', 'topfile.txt')
Chk '场景5 样本只到目录且去重' ($ds -match '2026/10/02/0234-tag' -and $ds -notmatch 'MY-SECRET-NAME' `
    -and $ds -notmatch 'STORY\.md' -and $ds -notmatch 'c\.bin') "实得: $ds"
Chk '场景5 前 3 条之外的不进样本' ($ds -notmatch 'd/e') "实得: $ds"
Chk '场景5 根级文件不显示名字' ((Get-VerifyDirSample -Paths @('topfile.txt')) -eq '(root)')
Chk '场景5 空清单给出空串而不是报错' ((Get-VerifyDirSample -Paths @()) -eq '')

# ---------- 6/7：本地清单与报告落笔（不依赖 rclone） ----------
$loc6 = Join-Path $T 's6'
Reset-And $loc6
[void](Seed (Join-Path $loc6 '2026/10/02/0234-tag') 'MANIFEST.txt' 40)
[void](Seed (Join-Path $loc6 '2026/10/02/0234-tag') 'a name with spaces.txt' 7)
[void](Seed $loc6 'rescue-test.txt' 11)
[void](Seed $loc6 'rootfile' 3)
$m6 = Get-LocalObjectMap -Root $loc6
Chk '场景6 嵌套文件的相对路径用正斜杠（云端就是斜杠）' `
    ($m6.ContainsKey('2026/10/02/0234-tag/MANIFEST.txt')) "实得键: $($m6.Keys -join ' | ')"
Chk '场景6 带空格的路径整条留全' ($m6.ContainsKey('2026/10/02/0234-tag/a name with spaces.txt'))
Chk '场景6 rescue-test.txt 不进对平清单（只准留本地）' (-not $m6.ContainsKey('rescue-test.txt'))
Chk '场景6 尺寸取的是真实字节' ([long]$m6['rootfile'] -eq 3)
$m6b = Get-LocalObjectMap -Root "$loc6/"
Chk '场景6 根目录带尾分隔符时相对路径不偏移' ($m6b.ContainsKey('rootfile') -and -not $m6b.ContainsKey('/rootfile')) `
    "实得键: $($m6b.Keys -join ' | ')"

Reset-VerifyState
Format-VerifyNote PASS 'timeline @ t1' 'x'
Format-VerifyNote FAIL 'repo:files @ t1' 'y'
Format-VerifyNote UNKNOWN 'config:files @ t1' 'z'
Format-VerifyNote HEALED 'config:system @ t1' 'w'
Format-VerifyNote SKIP 'repo:config @ t1' 'v'
Chk '场景7 三档计数各记各的' ($script:VerifyFailed -eq 1 -and $script:VerifyUnknown -eq 1 -and $script:VerifyHealed -eq 1) `
    "FAIL=$script:VerifyFailed UNKNOWN=$script:VerifyUnknown HEALED=$script:VerifyHealed"
Chk '场景7 PASS/SKIP 不进任何失败计数' ($script:VerifyLines.Count -eq 5)
$rep7 = Join-Path $T 'report\CLOUD-VERIFY.txt'
[void](New-Item -ItemType Directory -Force -Path (Join-Path $T 'report'))
$ok7 = Write-VerifyReport -Path $rep7 -Lines $script:VerifyLines -Failed 1 -Unknown 1 -Healed 1 -Sha 'deadbee'
$body7 = Get-Content -Raw $rep7
Chk '场景7 报告汇总行的 checks 等于行数' ($body7 -match 'checks=5 FAIL=1 UNKNOWN=1 HEALED=1') `
    "实得: $((($body7 -split "`n" | Where-Object { $_ -match 'checks=' })) -join ';')"
Chk '场景7 报告带代码基' ($body7 -match '代码基: deadbee')
Chk '场景7 报告写成功返回真值' ([bool]$ok7)
$bad7 = Write-VerifyReport -Path (Join-Path ([System.IO.Path]::Combine($T, 'no-such-dir')) 'CLOUD-VERIFY.txt') `
    -Lines @('x')
Chk '场景7 落笔目录不存在时非致命（返回假值，不抛）' (-not [bool]$bad7)

# ---------- 8：真 rclone 对本地「云端」目录 ----------
if (-not $script:hasRclone) {
    Skip '场景8 对平/隐私/UNKNOWN/SKIP' 'PATH 里没有 rclone'
    Skip '场景8g 同尺寸不同内容 → forcing 补传 → HEALED' 'PATH 里没有 rclone'
    Skip '场景9 Invoke-CloudVerify 全链 + 原生 stderr 不炸' 'PATH 里没有 rclone'
} else {
    # 快照目录是日期形状。这里**故意不写字面量**：本会话的显示层会把斜杠分隔的日期路径渲染成
    # 连字符（`2026/10/02` 看着像 `2026-10-02`），照着输出抄就把夹具改成一个不存在的路径，
    # 而「本地没这棵树」恰好是 SKIP 分支——整段会安静地测不到东西。用片段拼，斜杠是真斜杠。
    $TagDir = '2026' + '/' + '10' + '/' + '02' + '/' + '0234-tag'

    # ---- 8a：全推上去 → PASS；云端多出的历史副本仍 PASS（红线 §1.4 只增不减） ----
    $l8 = Join-Path $T 's8\local'
    $c8 = Join-Path $T 's8\cloud'
    Reset-And $l8; Reset-And $c8
    [void](Seed (Join-Path $l8 $TagDir) 'MANIFEST.txt' 40)
    [void](Seed (Join-Path $l8 $TagDir) 'a name with spaces.txt' 7)
    # deep/ 里那份先双方都有，8b 再把**本地**这份改大：尺寸不符要的是「两端都在、尺寸不同」，
    # 只往本地加一个新对象那叫缺失——两种坏法在报告里是两个计数，夹具不能把它们混成一种。
    [void](Seed (Join-Path $l8 'deep') 'MY-SECRET-NAME.txt' 4)
    $cp = RC @('copy', $l8, $c8)
    Chk '场景8a 夹具推送成功' ($cp.Rc -eq 0) "rc=$($cp.Rc)"
    Reset-VerifyState
    Test-VerifyPrefix -Root $l8 -Dest $c8 -Label 'timeline @ t8' -Target 't8'
    Chk '场景8a 两端一致判 PASS 且不计失败' ($script:VerifyFailed -eq 0 -and $script:VerifyLines[0] -match '^PASS' `
        -and $script:VerifyLines[0] -notmatch 'FAIL') "实得: $($script:VerifyLines -join ' ;; ')"
    [void](Seed $c8 'pruned-history-copy.txt' 5)
    Reset-VerifyState
    Test-VerifyPrefix -Root $l8 -Dest $c8 -Label 'timeline @ t8' -Target 't8'
    Chk '场景8a 云端多出一份本地已裁的副本仍判 PASS' `
        ($script:VerifyFailed -eq 0 -and $script:VerifyLines[0] -match '^PASS' -and $script:VerifyLines[0] -match '另有 1 份') `
        "实得: $($script:VerifyLines -join ' ;; ')"

    # ---- 8b：云端少一份 + 另一份尺寸不符 → FAIL，样本只到目录、不带文件名 ----
    # 两边各坏一种、且各自落在**不同目录**：两个计数并成一条、或两个目录样本合成一个，这里当场
    # 看不出（bash 侧 test_cloud_verify.sh 第 6 段同一条口径）。
    $cp = RC @('copy', $l8, $c8)
    Chk '场景8b 先让两端真对齐（坏法是制造的，不是夹具自带的）' ($cp.Rc -eq 0) "rc=$($cp.Rc)"
    Remove-Item -LiteralPath (Join-Path $c8 (Join-Path $TagDir 'MANIFEST.txt')) -Force
    [void](Seed (Join-Path $l8 'deep') 'MY-SECRET-NAME.txt' 77)   # 本地改大、没推上去 → 尺寸不符
    Reset-VerifyState
    Test-VerifyPrefix -Root $l8 -Dest $c8 -Label 'timeline @ t8' -Target 't8'
    $line8b = $script:VerifyLines[0]
    Chk '场景8b 缺一份 + 尺寸不符一份 → FAIL' ($script:VerifyFailed -eq 1 -and $line8b -match '^FAIL') "实得: $line8b"
    Chk '场景8b 两个计数分开（缺 1 / 尺寸不符 1）' ($line8b -match '缺 1 个 / 尺寸不符 1 个') "实得: $line8b"
    Chk '场景8b 两个目录各自进各自的样本（并成一个就定位不到要补传哪棵子树）' `
        ($line8b -match ('缺失所在目录：{0}；尺寸不符所在目录：deep(?![^\s])' -f [regex]::Escape($TagDir))) "实得: $line8b"
    Chk '场景8b 差异样本只到目录，绝不带完整文件名' ($line8b -notmatch 'MY-SECRET-NAME' -and
        $line8b -notmatch 'MANIFEST\.txt') "实得: $line8b"
    Chk '场景8b 报告行不含本地绝对路径' ($line8b -notmatch [regex]::Escape($T)) "实得: $line8b"

    # ---- 8c：隐私红线——rescue-test.txt 只准留本地，云端出现就是违例 ----
    # 拆成两轮各测一件事：①只有本地有（正确形状）→ 隐私 PASS，且它不许进对平清单；
    # ②云端冒出一份（--exclude 挡不住的历史漏网）→ 隐私 FAIL。合成一轮的话，「隐私检查改成读
    # 本地清单」这个变异两条断言都救得了它——本地那份本来就在，读本地也会说「有」。
    $l8c = Join-Path $T 's8c\local'
    $c8c = Join-Path $T 's8c\cloud'
    Reset-And $l8c; Reset-And $c8c
    [void](Seed $l8c 'STORY.md' 6)
    [void](Seed $l8c 'rescue-test.txt' 8)
    [void](RC @('copy', $l8c, $c8c, '--exclude', 'rescue-test.txt'))
    Reset-VerifyState
    Test-VerifyPrefix -Root $l8c -Dest $c8c -Label 'timeline @ t8c' -Target 't8c' -Privacy
    $j8c1 = $script:VerifyLines -join "`n"
    Chk '场景8c 本地有、云端没有（正确形状）→ 隐私判 PASS' ($j8c1 -match '(?m)^PASS\s+privacy @ t8c') "实得: $j8c1"
    Chk '场景8c 本地那份没污染对平（同一条仍判 PASS、零失败）' `
        ($j8c1 -match '(?m)^PASS\s+timeline @ t8c' -and $script:VerifyFailed -eq 0) "实得: $j8c1"
    [void](Seed (Join-Path $c8c 'old-copy') 'rescue-test.txt' 8)
    Reset-VerifyState
    Test-VerifyPrefix -Root $l8c -Dest $c8c -Label 'timeline @ t8c' -Target 't8c' -Privacy
    $j8c = $script:VerifyLines -join "`n"
    Chk '场景8c 云端残留 rescue-test.txt → 隐私 FAIL' ($script:VerifyFailed -eq 1 -and
        $j8c -match '(?m)^FAIL\s+privacy @ t8c') "实得: $j8c"
    Chk '场景8c 云端那份算「多出来」但不算对平失败（只增不减）' ($j8c -match '(?m)^PASS\s+timeline @ t8c') `
        "实得: $j8c"

    # ---- 8d：网盘读不出 → UNKNOWN，不改失败计数 ----
    Reset-VerifyState
    Test-VerifyPrefix -Root $l8c -Dest 'nosuchremote:dev/timeline' -Label 'timeline @ t8d' -Target 't8d'
    Chk '场景8d 读不出记 UNKNOWN 且不判失败' ($script:VerifyUnknown -eq 1 -and $script:VerifyFailed -eq 0 `
        -and $script:VerifyLines[0] -match '^UNKNOWN') "实得: $($script:VerifyLines -join ' ;; ')"

    # ---- 8e：本地没有这棵树 → SKIP（该类别没备份，不能算云端缺副本） ----
    Reset-VerifyState
    Test-VerifyPrefix -Root ([System.IO.Path]::Combine($T, 'no-such-repo')) -Dest $c8c `
        -Label 'repo:system @ t8e' -Target 't8e'
    Chk '场景8e 本地没这棵树记 SKIP' ($script:VerifyLines[0] -match '^SKIP' -and $script:VerifyFailed -eq 0 `
        -and $script:VerifyUnknown -eq 0) "实得: $($script:VerifyLines -join ' ;; ')"

    # ---- 8f：仓库 config 两端一致 → PASS ----
    $repo8 = Join-Path $T 's8f\restic-files'
    $cld8 = Join-Path $T 's8f\cloud'
    Reset-And $repo8; Reset-And $cld8
    $cfg = Seed $repo8 'config' 64
    "local-new" | Set-Content -LiteralPath $cfg -NoNewline -Encoding ascii
    [void](Seed (Join-Path $repo8 'data') 'chunk' 12)
    [void](RC @('copy', $repo8, $cld8))
    Reset-VerifyState
    Test-VerifyConfigHash -Repo $repo8 -Dest $cld8 -Label 'config:files @ t8f'
    Chk '场景8f config 两端一致判 PASS' ($script:VerifyLines[0] -match '^PASS' -and $script:VerifyFailed -eq 0) `
        "实得: $($script:VerifyLines -join ' ;; ')"

    # ---- 8g：同尺寸、不同内容的陈旧 config → forcing 补传 → HEALED ----
    # 这一条测的是**自证链路的管道**：哈希不同 → 走补传 → 重新读回 → 才许写 HEALED，并且报告里
    # 留下陈旧那份的指纹。它**测不到**「只比大小所以静默跳过」那条网盘语义：本地目录两端都能算
    # 哈希，不带 `-I` 的 copy 照样覆盖（10-02 容器实测，目标 mtime 更新/相同/更旧三种都不跳过）。
    # 所以 m7/m8 由场景10 的静态断言守住，行为面的证明在 bash 侧的撒谎桩。
    $stale = Seed $cld8 'config' ([System.IO.File]::ReadAllBytes($cfg).Length)
    "cloud-OLD" | Set-Content -LiteralPath $stale -NoNewline -Encoding ascii
    # mtime 抄成与本地那份**完全相同**：让夹具的形状尽量等于真机那份（同尺寸 + 同 mtime，云端只是
    # 内容旧）。注意这一行**不决定**本机测不测得到 m7——本地后端比的是哈希，加了它照样不跳过。
    (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Item -LiteralPath $cfg).LastWriteTime
    $preHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stale).Hash
    $localHashPre = (Get-FileHash -Algorithm SHA256 -LiteralPath $cfg).Hash
    # 夹具形状自己也要断言：一旦「同尺寸」退化（上面两段文案长度不再相等），这一档就退化成
    # 尺寸不符，内容那一维等于没测——而 HEALED 那条照样绿。
    Chk '场景8g 夹具确实是同尺寸、不同内容' `
        (([long](Get-Item -LiteralPath $stale).Length -eq [long](Get-Item -LiteralPath $cfg).Length) -and ($preHash -ne $localHashPre)) `
        "云端 $((Get-Item -LiteralPath $stale).Length)B / 本地 $((Get-Item -LiteralPath $cfg).Length)B"
    Reset-VerifyState
    Test-VerifyConfigHash -Repo $repo8 -Dest $cld8 -Label 'config:files @ t8g'
    $line8g = $script:VerifyLines[0]
    Chk '场景8g 陈旧 config 被 forcing 补传修好 → HEALED' ($script:VerifyHealed -eq 1 -and $line8g -match '^HEALED') `
        "实得: $line8g"
    Chk '场景8g 报告里留下了陈旧那份的指纹' ($line8g -match '云端原是') "实得: $line8g"
    # HEALED 只能由**重新读回的内容**换来：夹具自己再读一遍云端，比对本地
    $verifyTmp = Join-Path $T 's8g-readback'
    $rb = RC @('copyto', (Join-Path $cld8 'config'), $verifyTmp)
    $postHash = ''
    if ($rb.Rc -eq 0) { $postHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $verifyTmp).Hash }
    Chk '场景8g 独立复读：云端内容此刻真等于本地（HEALED 不是嘴上说的）' `
        ($postHash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $cfg).Hash) `
        "复读 rc=$($rb.Rc) hash=$($postHash.Substring(0, [Math]::Min(12, $postHash.Length)))"
    Chk '场景8g 补传前云端确实是另一份内容（夹具自己先证明不一致存在过）' ($preHash -ne $postHash)

    # ---- 8h：补传后仍不一致 → FAIL（非致命层之外的真失败） ----
    # 让「补传」真的失败：把云端那个文件标只读。先探一刀——真跑通了说明这台宿主挡不住替换，
    # 那就如实 Skip，绝不留一条注定判错的断言（AGENTS §3：不许把测不到写成通过）。
    $stale2 = Join-Path $cld8 'config'
    [void](RC @('copy', $repo8, $cld8))          # 先让两端重新一致
    $ro = Get-Item -LiteralPath $stale2
    $ro.IsReadOnly = $true
    "local-XXX" | Set-Content -LiteralPath $cfg -NoNewline -Encoding ascii
    $probe = RC @('copy', $repo8, $cld8, '--include', 'config', '-I')
    if ($probe.Rc -eq 0) {
        Skip '场景8h 补传后仍不一致 → FAIL' "这台宿主没能造出「写不进去的云端文件」（探测 rc=0）"
        $ro.IsReadOnly = $false
    } else {
        $ro.IsReadOnly = $false
        Reset-VerifyState
        Test-VerifyConfigHash -Repo $repo8 -Dest $cld8 -Label 'config:files @ t8h'
        $line8h = $script:VerifyLines[0]
        Chk '场景8h 补传失败且内容仍不符 → FAIL（不是 HEALED 也不是 UNKNOWN）' `
            ($script:VerifyFailed -eq 1 -and $script:VerifyHealed -eq 0 -and $line8h -match '^FAIL') `
            "实得: $line8h"
        Chk '场景8h 报错写明补传退出码与两端哈希' ($line8h -match '强制补传 \(rc=\d+\) 后仍') "实得: $line8h"
    }

    # ---- 9：全链跑一次（含 rclone 写 stderr 那档不被宿主炸掉） ----
    # 调用点（Start-PartiverseBackup）顶部是 EAP=Stop；这里同形地在外层设 Stop，再进产品函数。
    $l9 = Join-Path $T 's9'
    Reset-And $l9
    [void](Seed (Join-Path $l9 'timeline') 'STORY.md' 5)
    [void](Seed (Join-Path $l9 'restic-files') 'config' 9)
    $v9 = $null
    try {
        $v9 = Invoke-CloudVerify -Targets @('nosuchremote:backguard-ci') -BackupBase $l9 `
            -RepoPairs @("files:$([System.IO.Path]::Combine($l9, 'restic-files'))") `
            -ReportPath ([System.IO.Path]::Combine($l9, 'timeline', 'CLOUD-VERIFY.txt')) `
            -SystemId 'ci-win' -Sha 'abc1234'
    } catch {
        Chk '场景9 网盘读不出时整条自证不许抛终止性异常' $false "抛了: $($_.Exception.Message)"
    }
    if ($v9) {
        Chk '场景9 远端读不出全记 UNKNOWN、零失败（时间轴 + 仓库对平 + config 三项）' `
            ($v9.Failed -eq 0 -and $v9.Unknown -eq 3) "Failed=$($v9.Failed) Unknown=$($v9.Unknown)"
        Chk '场景9 报告落在时间轴根级' (Test-Path -LiteralPath $v9.Report)
        $b9 = if (Test-Path -LiteralPath $v9.Report) { Get-Content -Raw $v9.Report } else { '' }
        # 汇总计数行值得单独断言：自证第一版在 bash 侧就是靠它暴露「三类仓库根本没进清单」
        $checks9 = if ($b9 -match 'checks=(\d+)') { [int]$matches[1] } else { -1 }
        Chk '场景9 报告 checks 等于 UNKNOWN 计数（没有漏登记的检查项）' ($checks9 -eq $v9.Unknown) `
            "checks=$checks9 Unknown=$($v9.Unknown)"
        Chk '场景9 RepoPairs 按第一个冒号切（仓库路径自带冒号也不能切错）' ($b9 -match 'repo:files @ ') `
            "实得: $($b9 -replace "`n", ' | ')"
    }
}

# ---------- 10：接线（静态）——逻辑对了没被调用等于没测 ----------
# 行为那一步（真跑一轮产品）在 windows job 里是独立一发；这里锁「调用点确实存在且口径对」。
$callSite = @([regex]::Matches($srcPs1, 'Invoke-CloudVerify -Targets')).Count
Chk '场景10 调用点恰好一处' ($callSite -eq 1) "实得 $callSite 处"
Chk '场景10 调用点带三重闸门（SKIP_WEBDAV / SEM_CLOUD_VERIFY / 有目标）' `
    ($srcPs1 -match '(?s)if \(\$env:SKIP_WEBDAV -ne "1" -and \$vsw -eq "1" -and \$targets\.Count -gt 0\)')
Chk '场景10 开关默认开且只认显式 1（与 backup.sh 的 == 1 同一条）' `
    ($srcPs1 -match '\$vsw = if \(\$env:SEM_CLOUD_VERIFY\)')
Chk '场景10 自证异常降为 warning（旁路不终止本体，§1.3）' `
    ($srcPs1 -match '(?s)catch \{\s*# 旁路没资格终止本体.*Write-Warning "\[verify\] 自证流程异常退出')
# 这条收紧到「同一个分支体内」：`.*` 在 (?s) 下会跨过整个文件，把 else 分支或后面别的
# RunRc=1 当成命中，摘掉这一发的那行照样绿——正是 §3 说的「断言自己是死的」。
Chk '场景10 自证失败必须让整轮非零（红线 §1.4）' `
    ($srcPs1 -match '(?s)if \(\$verifyFailed -gt 0\) \{\s*(?:#[^\r\n]*\r?\n\s*)*\$script:RunRc = 1\b')
$completeAfterVerify = $srcPs1.IndexOf('=== Backup FULLY COMPLETE ===') -gt $srcPs1.IndexOf('if ($verifyFailed -gt 0)')
Chk '场景10 FULLY COMPLETE 只在不一致为零时才打印（判据在打印之前）' ([bool]$completeAfterVerify)
Chk '场景10 报告路径是时间轴根级的 CLOUD-VERIFY.txt' `
    ($srcPs1 -match 'timeline\\CLOUD-VERIFY\.txt')
# —— 下面两条是 m7/m8 在这个宿主上**唯一**守得住的形式（行为面复现不了「只看大小」的跳过）：
# 静态锁住「补传必须 forcing」与「HEALED 前面必须有一次重新读回」。它们咬的是源码写法，不是
# 网盘语义——别把它们当成 A6 的网盘行为已经在这里验证过（那部分证明属于 bash 侧撒谎桩）。
Chk '场景10 补传命令 literally 带 -I 且只带上 config 那一个对象' `
    ($srcPs1 -match '(?m)^\s*& rclone copy -I\b[^\r\n]*--include\s+config')
Chk '场景10 HEALED 只能由补传后重新读回的内容换来（不许拿 copy 退出 0 当修好）' `
    ($srcPs1 -match '(?s)rclone copy -I.*?\$chash = Get-VerifyCloudHash.*?elseif \(\$chash -eq \$lhash\) \{\s*Format-VerifyNote HEALED')
} finally {
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) {
    Write-Host "=== CLOUD-VERIFY-LOGIC 失败 $script:fail 条（跳过 $($script:skipped.Count)）==="
    exit 1
}
Write-Host "=== CLOUD-VERIFY-LOGIC-OK skipped=$($script:skipped.Count) ==="
# 必须显式 exit 0：pwsh 在没有 exit 语句时把**最后一条原生命令的退出码**当宿主退出码，
# 而这里最后一条是 Remove-Item/Write-Host 之前的 rclone——它会替守卫决定成败（同
# test_log_rotation_logic.ps1 那条，CI 的 $LASTEXITCODE 直接读它）。
exit 0
