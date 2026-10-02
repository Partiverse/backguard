# probe_windows_ps51.ps1 —— 在 Windows PowerShell 5.1 那台宿主上跑一手事实探针
#
# 为什么这是一份**仓库文件**而不是 workflow 里的 run: 正文：
# GitHub Actions 把 `shell: powershell` 的 run 正文写成一份临时 .ps1 时**不带 BOM**，而
# Windows PowerShell 5.1 读没有 BOM 的文件按**当前 ANSI 代码页**解码（英文 runner = CP1252）。
# 中文注释的 UTF-8 三字节序列被 CP1252 拆成三个字符，其中 0x91-0x94 正好是弯引号
# ‘ ’ “ ” ——而 PowerShell 的语法分析器把弯引号**当字符串定界符**（不是普通字符），于是
# 一个字符串在下一行都没闭合的地方被打开，把后面的 `}` 全吃进去。真机症状就是一串
# `Missing closing '}' in statement block`，而且报错行号指向**离病灶最远**的那个块。
# 10-02 run 36991285809 的 windows job 就是这么死在「5.1 宿主探针」这一步上的：探针自己
# 带着中文注释，探针的存在意义（「产品 .ps1 在 5.1 下能不能载入」）因此一次都没测到。
# 结论口径：**这份文件里可以写中文（它带 BOM），step 正文里一个字都不能有**（ASCII-only）。
# 这条口径本身由下面的「事实 0」守着。
#
# 跑法：CI 的 windows job（`shell: powershell`）；本机验证只能靠容器里的 pwsh 7 ——
#   docker run --rm -v "$PWD":/repo:ro --entrypoint /bin/bash mcr.microsoft.com/powershell:lts \
#     -lc 'pwsh -NoProfile -File /repo/probe_windows_ps51.ps1'
# 它只能验「事实 0/1 的判定与 4 的 ISO 形状」，事实 3 的 stderr 结论在 7 上与 5.1 不同（这正是
# 这发探针要在真 5.1 上跑的理由），所以那一段只**上报**不判定。
param([string]$RepoRoot = '')
if (-not $RepoRoot) { $RepoRoot = $PSScriptRoot }
$ErrorActionPreference = 'Stop'   # 与被测产品顶部同一档，探的就是这一档下的行为

Write-Host "probe51: host=PS $($PSVersionTable.PSVersion) clr=$($PSVersionTable.CLRVersion) 64bit=$([Environment]::Is64BitProcess)"
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host "probe51-note: 当前不是 Windows PowerShell 5.1（实得 $($PSVersionTable.PSVersion)）——CI 那一步才是被测宿主，这里只验判定逻辑"
}

# ---- 事实 0：仓库里每个 .ps1 必须带 UTF-8 BOM ----
# 没有 BOM = 5.1 按 ANSI 解码 = 上面整段病灶。而且它**只在带中文时才炸**，所以「现在能跑」
# 不构成豁免：下一发往这个文件里加一句中文注释就把产品脚本点着了（backup.ps1 正是产品入口，
# 而 Task Scheduler 注册的命令行是 `powershell.exe -File backup.ps1`）。
$noBom = @()
$checked = 0
foreach ($f in Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter '*.ps1' -File |
               Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | Sort-Object FullName) {
    $checked++
    $head = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($head.Length -lt 3 -or $head[0] -ne 0xEF -or $head[1] -ne 0xBB -or $head[2] -ne 0xBF) {
        $noBom += $f.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
    }
}
Write-Host "probe51-bom: files=$checked withoutBom=$($noBom.Count)"
if ($noBom.Count -gt 0) {
    foreach ($n in $noBom) { Write-Host "  no BOM: $n" }
    Write-Host "::error::$($noBom.Count) 个 .ps1 没有 UTF-8 BOM——Windows PowerShell 5.1 会把里面的中文按 ANSI 解码，弯引号被当字符串定界符，脚本连载入都载入不了"
    exit 1
}

# ---- 事实 1：产品侧的 .ps1 在这台宿主的解析器下必须 0 语法错 ----
# pwsh 7 能载入不代表 5.1 能载入（7 里合法的语法面比 5.1 宽，编码默认值也不同）。这一发现在
# 扫**全部** .ps1：只点 backup.ps1 + semantic.ps1 的话，新增一份带中文的脚本照样溜过。
$parseFailed = 0
foreach ($f in Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter '*.ps1' -File |
               Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | Sort-Object FullName) {
    $rel = $f.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
    $tok = $null; $perr = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$perr)
    $n = @($perr).Count
    Write-Host "probe51-parse: $rel errors=$n"
    if ($n -gt 0) {
        $parseFailed++
        foreach ($e in (@($perr) | Select-Object -First 5)) {
            Write-Host "  line $($e.Extent.StartLineNumber) col $($e.Extent.StartColumnNumber): $($e.Message)"
        }
    }
}
if ($parseFailed -gt 0) {
    Write-Host "::error::$parseFailed 个 .ps1 在 Windows PowerShell 的解析器下报语法错——Task Scheduler 那台连脚本都载入不了"
    exit 1
}

# ---- 事实 2：ConvertFrom-Json 在这台宿主上交回什么类型 ----
# 7.2 → String、7.4+ → DateTime（§4.17 就是被这一发绊的），5.1 落在哪一档今天才有答案
$tp = @('[{"time":"2026-10-02T06:31:11.447503458+00:00"}]' | ConvertFrom-Json)[0].time
Write-Host "probe51-json: type=$($tp.GetType().Name) interp=`"$tp`""

# ---- 事实 3：$EAP=Stop 下，三种 stderr 形态会不会把 rc=0 的原生命令判成异常 ----
# 形 a = backup.ps1 `& restic @resticArgs 2>&1 | Tee-Object`（restic 的正常进度就写在 stderr）
# 形 b = `& rclone mkdir $dest 2>$null`
# 形 c = `… 2>&1 | Out-Null`
# 探针用 cmd.exe：写 stderr 且退出 0，与被测形状一致；每条都套 try/catch，因为在这台宿主上
# 「抛」本身就是被测结果，让它在 try 外面等于把答案变成 step 红。
# **只上报不判定**：要断言什么取决于它报回的答案（判定一旦写死，就是在替宿主猜答案）。
# **非 Windows 宿主整段跳过**：没有 cmd.exe 时换 /bin/echo 会把「没抛异常」报成结论，而它
# 根本没写过 stderr——那是一条伪装成答案的假 verdict（§3「断言自己是死的」的镜像：活的断言
# 拿到假数据）。本机容器只验 0/1/4 的判定逻辑，这一段属于真 5.1。
$onWindows = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
if (-not $onWindows) {
    Write-Host 'probe51-stderr: SKIPPED (non-Windows host; cmd.exe 形状在这里复现不了)'
} else {
$comspec = $env:ComSpec
$sink = Join-Path ([System.IO.Path]::GetTempPath()) ('probe51-a-' + [guid]::NewGuid().ToString('N') + '.log')
$resA = ''
try {
    & $comspec /c 'echo oops 1>&2' 2>&1 | Tee-Object -FilePath $sink -Append | Out-Null
    $resA = "no-throw rc=$LASTEXITCODE"
} catch { $resA = "THREW $($_.Exception.GetType().Name)" }
Remove-Item -LiteralPath $sink -Force -ErrorAction SilentlyContinue
$resB = ''
try {
    & $comspec /c 'echo oops 1>&2' 2>$null
    $resB = "no-throw rc=$LASTEXITCODE"
} catch { $resB = "THREW $($_.Exception.GetType().Name)" }
$resC = ''
try {
    & $comspec /c 'echo oops 1>&2' 2>&1 | Out-Null
    $resC = "no-throw rc=$LASTEXITCODE"
} catch { $resC = "THREW $($_.Exception.GetType().Name)" }
Write-Host "probe51-stderr: tee2>&1=$resA  redirect2null=$resB  pipeOutNull=$resC"
# 三条 verdict 缺一即红：空的含义是「探针自己被宿主挡在外面」，那比任何一条结论都糟——
# 它会伪装成绿（同一条理由见 §3「断言自己是死的」）
foreach ($r in @($resA, $resB, $resC)) {
    if ($r -notmatch '^(no-throw|THREW)') {
        Write-Host "::error::stderr 形态探针没拿到 verdict（实得 '$r'）——本步等于没跑"
        exit 1
    }
}
}

# ---- 事实 4：Format-IsoTime 在这台宿主上确实交出 ISO（§4.17 那条修复就是为它写的）----
# dot-source 产品脚本没有副作用，这一点由本 job 的保留策略守卫先证过（它也 dot-source）
. (Join-Path $RepoRoot (Join-Path 'semantic' 'semantic.ps1'))
$iso4 = '2026-10-02T06:31:11.447503458+00:00'
$dt4 = (Get-Date -Year 2026 -Month 10 -Day 2 -Hour 6 -Minute 31 -Second 11 -Millisecond 447).ToUniversalTime()
$s4 = Format-IsoTime $iso4
$t4 = Format-IsoTime $dt4
Write-Host "probe51-isotime: stringPass=$($s4 -ceq $iso4) dateTimeOut=$t4 bareToString=$($dt4.ToString())"
if ($s4 -cne $iso4) {
    Write-Host "::error::Format-IsoTime 没把带纳秒+偏移的 ISO 串原样交回（实得 $s4）——bg 那边照样读不动"
    exit 1
}
if ($t4 -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    Write-Host "::error::Format-IsoTime 在这台宿主上交回的不是 ISO 形状（实得 $t4）——§4.17 的修复没落地"
    exit 1
}

# ---- 事实 5：产品侧每一个原生命令调用点都必须在 EAP=Continue 的作用域里 ----
# 这一条是事实 3 的**结论落地**：5.1 宿主上 Stop 作用域里的原生命令只要写一行 stderr 就抛终止性
# 异常（上面实测三形全 THREW RemoteException），而备份引擎的正常输出偏偏写在 stderr。所以「产品
# 脚本在真机上能不能跑完一轮」等价于「每一个 `& restic` / `& rclone` 处在哪一档 EAP 里」。
# 为什么用解析器而不是正则扫文本：作用域这件事正则给不出答案——函数体、嵌套函数（semantic.ps1
# 的 Invoke-Bg 定义在 Invoke-SemanticLayer 里面）、`& { … }` 内联 scriptblock、多行 param 之后的
# 首句，位置全不一样；而「数不准」在这里不是精度问题，是**漏掉的那一处就是炸点**（本发 fix 之前
# 这条规矩只活在注释里：写着「Invoke-CloudVerify 首句必须 Continue」，同文件另外九处原生命令
# 一个都没登记，其中 Backup-ResticClass 的 `restic init … 2>&1 | Out-Null` 正是第二次起的每一轮
# 都会踩的那一颗）。
# 判定口径：调用点所在**最近的作用域**（函数体或 scriptblock 体）里，从作用域开头到该调用之前，
# 必须出现把 `$ErrorActionPreference` 赋成 Continue 的语句。只认「在这条调用之前」——写在调用
# 之后的赋值等于没写。`& 函数名` 不算原生命令（同文件里定义的函数名拿来排除）。
# rescue.ps1 也在清单内：它是逃生工具，跑现场最可能是 Windows PowerShell 5.1（系统自带那台），
# 而它每个函数都在调 restic / age ——漏掉这个文件等于「只在夜间备份上验过 Continue 规矩」。
# 守卫的接线断言在 test_rescue_e2e.ps1 末尾（把这行里的 'rescue.ps1' 摘掉那条就红）。
$eapFiles = @('backup.ps1', (Join-Path 'semantic' 'semantic.ps1'), 'rescue.ps1')
$eapViolations = @()
$eapCalls = 0
$eapVarCalls = 0
foreach ($rel in $eapFiles) {
    $full = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $full)) {
        Write-Host "::error::$rel 不在仓库里——这条规则等于没跑"; exit 1
    }
    $tokE = $null; $errE = $null
    $astE = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokE, [ref]$errE)
    $own = @($astE.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name })
    $cmds = @($astE.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    foreach ($c in $cmds) {
        $el = $c.CommandElements
        if ($el.Count -eq 0) { continue }
        $e0 = $el[0]
        $name = ''
        $fromVar = $false
        if ($e0 -is [System.Management.Automation.Language.VariableExpressionAst]) {
            # **不是** `$e0.UserPath`：7.4 的 VariableExpressionAst 上没有这个属性（实测
            # `PSObject.Properties.Name -contains 'UserPath'` = False），取到的是 $null，于是下面那句
            # `if (-not $name) { continue }` 把 `& $ResticBin` **一整类**调用静默跳过——10-02 加上
            # rescue.ps1 之后总数仍是 17，才发现这一形从没登记过（backup.ps1 13 处 + rescue.ps1 6 处）。
            # 正确取法是 `.VariablePath.UserPath`，它连作用域名一起给（`script:ResticBin`），
            # 所以比对「本文件定义的函数名」之前要把 `scope:` 前缀摘掉。
            $name = "$($e0.VariablePath.UserPath)"
            $fromVar = $true
            if ($name -match '^[A-Za-z]+:(.*)$') { $name = $matches[1] }
        } elseif ($e0 -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $name = $e0.Value }
        if (-not $name) { continue }
        # 外部程序 = 用 & 调的（& restic / & rclone / & $python / & $env:BG），或裸写的已知可执行名
        $isNative = $false
        if ($c.InvocationOperator -eq 'Ampersand') {
            if ($own -notcontains $name) { $isNative = $true }
        } elseif ($name -cmatch '^(restic|rclone|git|curl\.exe|winget|bcdedit|borg|age|python3?)$') {
            $isNative = $true
        }
        if (-not $isNative) { continue }
        $eapCalls++
        if ($fromVar) { $eapVarCalls++ }
        $scope = $c.Parent
        while ($scope -and -not ($scope -is [System.Management.Automation.Language.ScriptBlockAst])) {
            $scope = $scope.Parent
        }
        if (-not $scope) { $eapViolations += "$rel`:$($c.Extent.StartLineNumber) (无所属作用域) $name"; continue }
        $pre = $scope.Extent.Text.Substring(0, [Math]::Max(0, $c.Extent.StartOffset - $scope.Extent.StartOffset))
        if ($pre -notmatch '(?im)^\s*\$ErrorActionPreference\s*=\s*"?\s*Continue') {
            $eapViolations += "$rel`:$($c.Extent.StartLineNumber) $name"
        }
    }
}
Write-Host "probe51-eap: files=$($eapFiles.Count) nativeCalls=$($eapCalls) varForm=$($eapVarCalls) violations=$($eapViolations.Count)"
if ($eapViolations.Count -gt 0) {
    foreach ($v in $eapViolations) { Write-Host "  EAP-STOP: $v" }
    Write-Host "::error::$($eapViolations.Count) 处原生命令不在 EAP=Continue 的作用域里——5.1 宿主上它们写 stderr 就等于抛终止性异常，整轮备份在那里断掉（事实 3 实测三形全 THREW）"
    exit 1
}
if ($eapCalls -lt 10) {
    # 调用点数掉下去＝扫描本身坏了（改了判定式、换了作用域形状、或产品脚本里的引擎调用被摘了）。
    # 一条永远不会红的断言比没有断言更坏（§3「断言自己是死的」）
    Write-Host "::error::只扫到 $eapCalls 处原生命令（预期 >=10）——这条规则自己失效了"
    exit 1
}
if ($eapVarCalls -lt 5) {
    # `& $变量` 那一形整类掉下来 = 取名字的那一步又瞎了（7.4 上没有 `.UserPath`，10-02 就是被这个
    # 属性不存在坑掉，19 处调用静默不登记而总数照旧 17）。下限取 5：现存是 backup 13 + rescue 6。
    Write-Host "::error::只扫到 $eapVarCalls 处变量形的原生命令（预期 >=5）——取名字的那一步又失效了，整类调用没进守卫"
    exit 1
}

Write-Host "=== 5.1 宿主探针 OK：全部 .ps1 带 BOM 且语法 0 错、JSON 类型与三种 stderr 形态的结论已上报、原生命令调用点全在 Continue 作用域、Format-IsoTime 交回 ISO ==="
# 显式 exit 0：否则宿主退出码取最后一条原生命令的 rc（同 test_log_rotation_logic.ps1 那条）
exit 0
