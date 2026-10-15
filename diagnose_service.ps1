<#
.SYNOPSIS
    只读诊断：NSSM 服务启动失败时，把真正的原因挖出来。

.DESCRIPTION
    本脚本**不修改任何东西**：只调用 nssm 的 status / get，以及读日志文件。
    所以可以直接在生产机上跑，不会覆盖服务已有的配置。

    专治这几类表象：
      nssm start 报 Unexpected status SERVICE_PAUSED in response to START control
      nssm start 报 Unexpected status SERVICE_STOPPED ...
      服务在服务管理器里显示 Paused / 一起来就秒退

    这些**都只是 NSSM 的表象**。NSSM 只负责把程序拉起来，
    真正的报错在 AppStderr 指向的那个文件里（通常是 Python 的 traceback，
    或者普通 exe 自己打印的错误）。

    Python 与普通 exe 自动识别：Application 是 python.exe 就按 Python 查
    （site-packages / telnetlib / import 错误…），否则按普通 exe 查
    （缺 DLL / 缺配置文件 / 目录权限 / 32-64 位不匹配…）。

    为什么不直接用 install_service.ps1 -Force 重装一遍？
    诊断不该改配置：重装会把 NSSM 里"实际存着的配置"换成"你这次命令行写的配置"，
    漏掉一个参数就把现场破坏了。先诊断、后修，顺序别反。
    （install_service.ps1 本身已支持 -EntryScript / -ScriptArguments /
      -AppParameters 完全自定义，真要重装时也不需要改脚本。）

.EXAMPLE
    .\diagnose_service.ps1 -ServiceName Btxc-sensor-monitor-telnet

.EXAMPLE
    # nssm.exe 不在默认位置时显式指定
    .\diagnose_service.ps1 -ServiceName MySvc -NssmExe 'D:\tools\nssm.exe'
#>
[CmdletBinding()]
param(
    # Windows 服务名（sc.exe / Get-Service 里看到的名字）
    [Parameter(Mandatory = $true)][string]$ServiceName,

    # nssm.exe 路径；不填则先找默认位置，再找 PATH
    [string]$NssmExe,

    # 每个日志文件打印多少行
    [int]$TailLines = 40
)

# 不要用 Stop：本脚本全程在调原生命令，见下面的 Invoke-Native 说明。
$ErrorActionPreference = 'Continue'

# --------------------------------------------------------------------------- #
# 调原生命令的唯一入口（和 install_service.ps1 里那份是同一套逻辑）
#
#   坑一：Windows PowerShell 5.1 下，原生命令往 stderr 写一个字，
#         配合 $ErrorActionPreference='Stop' 就会变成**中断性错误**
#         （报 NativeCommandError），2>$null 也挡不住。
#         nssm 在服务不存在时正好就是往 stderr 写 Can't open service!
#         所以必须临时把 EAP 降到 Continue。
#   坑二：5.1 的旧参数传递不会转义参数**内部**的双引号，
#         AppParameters 这种带引号的字符串会被拆开。PS 7 已修好。
# --------------------------------------------------------------------------- #
$nativeArgMode = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
$script:LegacyArgPassing = ($null -eq $nativeArgMode) -or ($nativeArgMode -eq 'Legacy')

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $nativeArgs = @(foreach ($arg in $Arguments) {
            if ($script:LegacyArgPassing) { $arg -replace '"', '\"' } else { $arg }
        })

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    # nssm 的非 ASCII 输出一律是 UTF-8 字节，而 PS 5.1 默认按 [Console]::OutputEncoding
    # （中文机器上是 GBK/936）解码原生命令 stdout → 中文全乱码
    # （本脚本要打印的 DisplayName / Description 正是中文）。
    # 只临时改"解码"这一层；实测改前改后 nssm 写出的字节完全一致。
    $savedOutEnc = $null
    $changedOutEnc = $false
    try {
        $savedOutEnc = [Console]::OutputEncoding
        if ($savedOutEnc.CodePage -ne 65001) {
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $changedOutEnc = $true
        }
    } catch { $changedOutEnc = $false }

    try {
        $output = & $FilePath @nativeArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        if ($changedOutEnc) { try { [Console]::OutputEncoding = $savedOutEnc } catch { } }
        $ErrorActionPreference = $savedEap
    }

    # ErrorRecord.ToString() 会带上 System.Management.Automation.RemoteException
    # 这种类型噪声，stderr 原文在 .Exception.Message 里；空消息的 ErrorRecord 直接丢。
    $lines = @(foreach ($item in $output) {
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                $text = $item.Exception.Message
            } else {
                $text = "$item"
            }
            if (-not [string]::IsNullOrEmpty($text)) { $text }
        })

    return [pscustomobject]@{ Output = $lines; ExitCode = $exitCode }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('--- ' + $Title + ' ') -ForegroundColor Cyan -NoNewline
    Write-Host ('-' * [Math]::Max(0, 60 - $Title.Length)) -ForegroundColor Cyan
}

function Write-Item {
    param(
        [string]$Key,
        [string]$Value,
        [string]$Color = 'Gray'
    )
    Write-Host ('  {0,-22} {1}' -f $Key, $Value) -ForegroundColor $Color
}

# 读日志尾部。日志可能是 UTF-8（Python 默认）也可能是 GBK（老代码），
# 先按 UTF-8 解，出现替换字符 U+FFFD 就改用 936(GBK) 重解。
#
# 注意：服务**正在运行**时，NSSM 会一直占着 AppStdout/AppStderr 的句柄，
# 这时 [System.IO.File]::ReadAllBytes 会抛
#   IOException: The process cannot access the file because it is being used by another process
# 所以必须显式用 FileShare.ReadWrite 打开。
function Get-LogTail {
    param([string]$Path, [int]$Lines)

    $bytes = $null
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = [int]$fs.Length
        if ($len -le 0) { return @() }
        $buffer = New-Object byte[] $len
        $read = $fs.Read($buffer, 0, $len)
        if ($read -le 0) { return @() }
        $bytes = if ($read -eq $len) { $buffer } else { [byte[]]$buffer[0..($read - 1)] }
    } catch {
        Write-Host "      （读不了这个文件：$($_.Exception.Message)）" -ForegroundColor Yellow
        return @()
    } finally {
        if ($fs) { $fs.Dispose() }
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Contains([char]0xFFFD)) {
        try { $text = [System.Text.Encoding]::GetEncoding(936).GetString($bytes) } catch { }
    }

    $all = @($text -split "`r?`n")
    # 去掉尾部的空行（注意 Count 为 1 时不能用 [0..-1]，那会死循环）
    while ($all.Count -gt 0 -and [string]::IsNullOrWhiteSpace($all[$all.Count - 1])) {
        if ($all.Count -le 1) { $all = @(); break }
        $all = @($all[0..($all.Count - 2)])
    }
    if ($all.Count -eq 0) { return @() }
    if ($all.Count -gt $Lines) { return @($all[($all.Count - $Lines)..($all.Count - 1)]) }
    return $all
}

# --------------------------------------------------------------------------- #
# 0. 前置检查：nssm.exe 在哪、服务存不存在
# --------------------------------------------------------------------------- #
Write-Host ''
Write-Host "===== NSSM 服务诊断：$ServiceName =====" -ForegroundColor White
Write-Host ('主机：{0}    用户：{1}' -f $env:COMPUTERNAME, $env:USERNAME) -ForegroundColor DarkGray

if (-not $NssmExe) {
    $candidates = @('C:\Windows\nssm.exe', (Join-Path $PSScriptRoot 'nssm.exe'), (Join-Path $PSScriptRoot 'tools\nssm.exe'))
    $NssmExe = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $NssmExe) {
        $cmd = Get-Command 'nssm.exe' -ErrorAction SilentlyContinue
        if ($cmd) { $NssmExe = $cmd.Source }
    }
}
if (-not $NssmExe -or -not (Test-Path -LiteralPath $NssmExe)) {
    Write-Host '找不到 nssm.exe，请用 -NssmExe 指定完整路径。' -ForegroundColor Red
    exit 2
}
Write-Item 'nssm.exe' $NssmExe

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host ''
    Write-Host "  × 没有名为 $ServiceName 的服务。" -ForegroundColor Red
    Write-Host '    可能是：注册时服务名写错了，或者已经被 uninstall 删掉。' -ForegroundColor Yellow
    Write-Host '    当前机器上由 NSSM 托管的服务（ImagePath 含 nssm）：' -ForegroundColor DarkGray
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -match 'nssm' } |
        ForEach-Object { Write-Host ('      {0}  [{1}]  {2}' -f $_.Name, $_.State, $_.PathName) -ForegroundColor DarkGray }
    exit 1
}

# --------------------------------------------------------------------------- #
# 1. 服务本体状态
# --------------------------------------------------------------------------- #
Write-Section '1. 服务状态（来源：SCM，不是 nssm 的本地化文本）'

$cim = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $ServiceName) -ErrorAction SilentlyContinue
Write-Item 'Get-Service' "$($svc.Status) / 启动类型 $($svc.StartType)"
if ($cim) {
    Write-Item 'StartName(账号)' $cim.StartName
    if ($cim.ProcessId) { Write-Item 'ProcessId' ([string]$cim.ProcessId) } else { Write-Item 'ProcessId' '（没有进程在跑）' }
    $exitColor = if ($cim.ExitCode -ne 0) { 'Yellow' } else { 'Gray' }
    Write-Item 'ExitCode' ([string]$cim.ExitCode) -Color $exitColor
    Write-Item 'ImagePath' $cim.PathName
}

# 重要：nssm status **永远 exit 0**，状态只体现在它打印的那行文本里。
# （NSSM 2.24 实测：服务存在 → exit 0 + SERVICE_XXX；
#   服务不存在 → exit 3 + "Can't open service!" / "OpenService(): ..."）
# 所以必须解析文本，不能看退出码。
$st = Invoke-Native -FilePath $NssmExe -Arguments @('status', $ServiceName)
$stRaw = ($st.Output -join ' ').Trim()
$isPaused = $stRaw -match 'PAUSED'

$stText = switch -Regex ($stRaw) {
    'SERVICE_PAUSED' { 'PAUSED（已暂停 ← 就是它）' }
    'SERVICE_RUNNING' { 'RUNNING（运行中）' }
    'SERVICE_START_PENDING' { 'START_PENDING（正在启动）' }
    'SERVICE_STOP_PENDING' { 'STOP_PENDING（正在停止）' }
    'SERVICE_STOPPED' { 'STOPPED（已停止）' }
    "Can't open service" { '打不开服务（多半是权限不足，试试以管理员身份运行）' }
    default { $stRaw }
}
$stColor = if ($isPaused -or ($stRaw -match 'STOPPED|Cannot open|Can''t open')) { 'Yellow' } else { 'Gray' }
Write-Item 'nssm status' $stText -Color $stColor

if ($isPaused) {
    Write-Host ''
    Write-Host '  PAUSED 的含义：程序被拉起来了，但**立刻以非 0 退出码崩溃**，' -ForegroundColor Yellow
    Write-Host '  NSSM 为了防止无限重启触发节流，把服务置为 Paused。服务注册是成功的。' -ForegroundColor Yellow
    Write-Host '  PAUSED 下 nssm start / nssm continue 都无效（已实测），只能先 stop：' -ForegroundColor Yellow
    Write-Host "      & '$NssmExe' stop $ServiceName" -ForegroundColor White
    Write-Host '  这条 stop 需要**管理员**权限，否则会报 Can''t open service!。' -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------- #
# 2. NSSM 实际怎么拉起程序（这是排查的地图）
# --------------------------------------------------------------------------- #
Write-Section '2. NSSM 配置（nssm get）'

$keys = @(
    'Application', 'AppParameters', 'AppDirectory',
    'AppStdout', 'AppStderr',
    'ObjectName', 'AppStopMethodConsole', 'AppRestartDelay', 'AppThrottle',
    'AppKillProcessTree'
)
$cfg = @{}
foreach ($key in $keys) {
    $r = Invoke-Native -FilePath $NssmExe -Arguments @('get', $ServiceName, $key)
    $val = ($r.Output -join ' ').Trim()
    $cfg[$key] = $val
    if ($val -match "Can't open service") { $val = '（服务不存在或无权访问）' }
    if ([string]::IsNullOrEmpty($val)) { $val = '（未设置）' }
    Write-Item $key $val
}

# AppExit 必须带子参数，直接 get AppExit 会报错（Parameter "AppExit" requires a subparameter!）
foreach ($sub in 'Default', '0') {
    $r = Invoke-Native -FilePath $NssmExe -Arguments @('get', $ServiceName, 'AppExit', $sub)
    $val = ($r.Output -join ' ').Trim()
    if ([string]::IsNullOrEmpty($val)) { $val = '（未设置）' }
    if ($sub -eq '0') { $cfg['AppExit0'] = $val }
    Write-Item "AppExit $sub" $val
}

# 环境变量单独取，可能很长，换行展示
$envr = Invoke-Native -FilePath $NssmExe -Arguments @('get', $ServiceName, 'AppEnvironmentExtra')
if ($envr.Output.Count) {
    Write-Host '  AppEnvironmentExtra:' -ForegroundColor Gray
    foreach ($line in $envr.Output) { Write-Host "        $line" -ForegroundColor DarkGray }
}

# --------------------------------------------------------------------------- #
# 3. 配置自检：路径都在不在
# --------------------------------------------------------------------------- #
Write-Section '3. 路径自检'

$app = $cfg['Application']
$dir = $cfg['AppDirectory']
$appVer = ''
$entryFull = ''
# 是不是 Python 解释器？决定后面要不要查 site-packages / telnetlib / import 那套。
# NSSM 只管起进程，Application 是 python.exe 还是别的 exe 完全是两码事。
$isPython = $app -match '(?i)pythonw?\.exe$|(?i)[\\/]python(\d+(\.\d+)?)?\.exe$'

if ($app -and $app -ne '（未设置）') {
    if (Test-Path -LiteralPath $app) {
        if ($isPython) {
            $ver = (Invoke-Native -FilePath $app -Arguments @('--version')).Output -join ' '
            $appVer = $ver
            Write-Item 'Application 存在' "是    $ver"
        } else {
            $fi = Get-Item -LiteralPath $app
            Write-Item 'Application 存在' ("是    {0}  {1:N0} 字节  修改于 {2:yyyy-MM-dd}" -f $fi.Name, $fi.Length, $fi.LastWriteTime)
        }
    } else {
        $what = if ($isPython) { '解释器' } else { 'exe' }
        Write-Item 'Application 存在' "否 ← $what 路径失效，服务必然起不来" -Color Red
    }
}
if ($dir) {
    if (Test-Path -LiteralPath $dir) {
        Write-Item 'AppDirectory 存在' '是'
    } else {
        Write-Item 'AppDirectory 存在' '否 ← 工作目录不存在，进程会在启动阶段就死' -Color Red
    }
}

# AppParameters 里第一个 .py 就是入口脚本，检查它存不存在（只有 Python 模式才谈得上）
$pars = $cfg['AppParameters']
if ($pars) {
    $m = [regex]::Match($pars, '"([^"]*\.py)"|(\S+\.py)')
    if ($m.Success) {
        $entry = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        $entryFull = if ([System.IO.Path]::IsPathRooted($entry)) { $entry } else { Join-Path $dir $entry }
        if (Test-Path -LiteralPath $entryFull) {
            Write-Item '入口脚本' $entryFull
        } else {
            Write-Item '入口脚本' "$entryFull ← 文件不存在" -Color Red
        }
    } elseif (-not $isPython) {
        # 非 Python 时，AppParameters 里的第一个非选项值常常是配置文件/子命令，
        # 顺手看看它在不在（这是 exe 起不来最常见的原因之一）
        $mm = [regex]::Match($pars, '"([^"]+\.(ini|conf|cfg|json|yaml|yml|toml|xml|txt|dat))"|(\S+\.(ini|conf|cfg|json|yaml|yml|toml|xml|txt|dat))')
        if ($mm.Success) {
            $cf = if ($mm.Groups[1].Success) { $mm.Groups[1].Value } else { $mm.Groups[3].Value }
            $cfFull = if ([System.IO.Path]::IsPathRooted($cf)) { $cf } else { Join-Path $dir $cf }
            if (Test-Path -LiteralPath $cfFull) {
                Write-Item '配置文件' $cfFull
            } else {
                Write-Item '配置文件' "$cfFull ← 文件不存在（exe 可能因此启动即退出）" -Color Red
            }
        }
    }
}

# 入口脚本有没有 import telnetlib —— 3.13 起标准库已删除它。
# 本脚本服务的项目就是 telnet 类监控，所以这条专门查。
if ($entryFull -and (Test-Path -LiteralPath $entryFull)) {
    $src = Get-Content -LiteralPath $entryFull -Raw -ErrorAction SilentlyContinue
    if ($src -match 'import\s+telnetlib|from\s+telnetlib') {
        $minor = -1
        if ($appVer -match '(\d+)\.(\d+)\.') { $minor = [int]$Matches[2] }
        if ($minor -ge 13) {
            Write-Item 'telnetlib 检查' "入口脚本 import telnetlib，而解释器是 $appVer" -Color Red
            Write-Host '      ← 3.13 起标准库删除了 telnetlib，运行必然 ModuleNotFoundError。' -ForegroundColor Red
            Write-Host '        解法：a) 换 3.12 及以下解释器  b) pip install telnetlib-py 或改用 socket/paramiko' -ForegroundColor Yellow
        } else {
            Write-Item 'telnetlib 检查' "用到了 telnetlib，但解释器是 $appVer（还带这个模块）"
        }
    }
}

# 依赖包到底装在哪 —— Python 最常见的坑
if ($isPython -and $app -and (Test-Path -LiteralPath $app) -and $dir -and (Test-Path -LiteralPath $dir)) {
    Write-Host ''
    Write-Host "  site-packages 位置（服务以 $($cfg['ObjectName']) 运行时用得着）：" -ForegroundColor DarkGray
    $sp = Invoke-Native -FilePath $app -Arguments @('-c', 'import site,sys;print(sys.prefix);[print(p) for p in site.getsitepackages() if p != sys.prefix and __import__("os").path.isdir(p)]')
    foreach ($line in (@($sp.Output) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)) {
        Write-Host "        $line" -ForegroundColor DarkGray
    }
    if ($cfg['ObjectName'] -and $cfg['ObjectName'] -notmatch 'LocalSystem') {
        Write-Host "  注意：服务账号是 $($cfg['ObjectName'])，不是当前用户。" -ForegroundColor Yellow
    } else {
        Write-Host '  注意：服务账号是 LocalSystem。你 pip install --user 装的包在' -ForegroundColor Yellow
        Write-Host '        %APPDATA%\Python\PythonXX\site-packages，LocalSystem 看不到。' -ForegroundColor Yellow
    }
} elseif (-not $isPython -and $app -and (Test-Path -LiteralPath $app)) {
    # 普通 exe：要查的是运行时依赖和目录权限，不是 site-packages
    Write-Host ''
    Write-Host "  这是普通 exe（不是 Python）。服务以 $($cfg['ObjectName']) 运行时，请确认：" -ForegroundColor DarkGray
    Write-Host "    · 它和它依赖的 DLL / 配置文件在同一目录或系统路径下" -ForegroundColor DarkGray
    Write-Host ("    · 它对 '{0}' 有读权限（日志目录还要写权限），可用 icacls 核对" -f $dir) -ForegroundColor DarkGray
    $dlls = @(Get-ChildItem -LiteralPath (Split-Path $app -Parent) -Filter '*.dll' -ErrorAction SilentlyContinue)
    Write-Host ("    · 该目录下有 {0} 个 DLL（缺一个就可能起不来）" -f $dlls.Count) -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------- #
# 4. 真正的报错：日志尾部
# --------------------------------------------------------------------------- #
Write-Section '4. 日志尾部（真正的报错在这里）'

$tailText = ''
$anyLog = $false
$logPaths = @()
foreach ($key in 'AppStderr', 'AppStdout') {
    if ($cfg[$key] -and $cfg[$key] -ne '（未设置）') { $logPaths += $cfg[$key] }
}
if ($dir) {
    $logPaths += (Join-Path $dir 'logs\service.log')
    $logPaths += (Join-Path $dir 'service.log')
}

foreach ($path in ($logPaths | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $anyLog = $true
    $size = (Get-Item -LiteralPath $path).Length
    Write-Host ''
    Write-Host ('  --- {0}  ({1} 字节) ---' -f $path, $size) -ForegroundColor DarkGray
    $tail = Get-LogTail -Path $path -Lines $TailLines
    if ($tail.Count -eq 0) {
        Write-Host '      （空 —— 可能是程序没跑起来，也可能是它被重定向后不 flush；见第 5 节）' -ForegroundColor DarkGray
        continue
    }
    foreach ($line in $tail) {
        $color = 'DarkGray'
        if ($line -match 'Traceback|Error|error:|Exception|No module named|not found|denied') { $color = 'Red' }
        Write-Host "      $line" -ForegroundColor $color
    }
    # 同一段 traceback 重复出现 = NSSM 已经把程序重启过这么多次
    $restarts = ($tail | Where-Object { $_ -match '^Traceback' }).Count
    if ($restarts -ge 2) {
        Write-Host "      ↑ 这段 traceback 重复了 $restarts 次：NSSM 已经反复重启 $restarts 次，" -ForegroundColor Yellow
        Write-Host '        直到触发 AppThrottle 节流才把服务置为 Paused。' -ForegroundColor Yellow
    }
    if ($path -eq $cfg['AppStderr'] -or $path -eq $cfg['AppStdout']) {
        $tailText += ($tail -join "`n") + "`n"
    }
}

if (-not $anyLog) {
    Write-Host ''
    Write-Host '  日志文件一个都不存在。' -ForegroundColor Yellow
    Write-Host '  含义：NSSM 还没把子进程的 stdout/stderr 落盘 —— 即程序根本没被执行（路径错），' -ForegroundColor Yellow
    Write-Host '        或者 AppStdout/AppStderr 指向了写不进去的目录。' -ForegroundColor Yellow
}

# --------------------------------------------------------------------------- #
# 5. 对症下药
# --------------------------------------------------------------------------- #
Write-Section '5. 结论'

if ($stRaw -match 'SERVICE_RUNNING') {
    Write-Host '  服务当前是 RUNNING —— 它至少能起来、并且活着。' -ForegroundColor Green
    if ($tailText -match 'Traceback') {
        Write-Host '  若上面的日志里有 traceback，那是早期失败启动留下的；服务现在在跑。' -ForegroundColor DarkGray
    }
    Write-Host ''
}

$account = $cfg['ObjectName']

# 普通 exe 专有的两类线索：缺运行库、以及"它本来就是服务程序"的误用
# 线索来自两处：SCM 记的退出码，和程序/事件日志里打印的十六进制码。
if (-not $isPython) {
    $cimEx = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $ServiceName) -ErrorAction SilentlyContinue
    $exitCode = if ($cimEx) { [int64]$cimEx.ExitCode } else { 0 }
    if ($exitCode -in -1073741515, 3221225781 -or $tailText -match '(?i)0xc0000135') {
        Write-Host '  命中：缺 DLL / 运行库（0xC0000135 STATUS_DLL_NOT_FOUND）。' -ForegroundColor Red
        Write-Host '  装对应的 VC++ Redistributable / .NET Framework，或把缺失的 DLL 放到 exe 同目录。' -ForegroundColor White
    } elseif ($exitCode -in -1073741701, 3221225595 -or $tailText -match '(?i)0xc000007b') {
        Write-Host '  命中：32/64 位不匹配（0xC000007B STATUS_INVALID_IMAGE_FORMAT）。' -ForegroundColor Red
        Write-Host '  用与 exe 位数一致的运行库（x64 程序装 x64 Redistributable）。' -ForegroundColor White
    }
}

if ($tailText -match "ModuleNotFoundError: No module named '?([A-Za-z_][\w.]*)") {
    $mod = $Matches[1]
    Write-Host "  命中：缺依赖包 —— No module named $mod" -ForegroundColor Red
    Write-Host "  服务是以 $account 运行的，看不到你当前用户装的包。解法二选一：" -ForegroundColor Yellow
    Write-Host "    a) 用服务的那个解释器给**所有用户**装：& '$app' -m pip install $mod" -ForegroundColor White
    Write-Host '    b) 在项目里建 venv，把 NSSM 的 Application 改成 venv\Scripts\python.exe' -ForegroundColor White
    Write-Host '  另：telnetlib 在 Python 3.13 里被**删掉**了（最后存在于 3.12）。' -ForegroundColor Yellow
    Write-Host '      若代码还 import telnetlib 而解释器是 3.13+，报的就是这个错。' -ForegroundColor Yellow
}
elseif ($tailText -match 'SyntaxError|IndentationError') {
    Write-Host '  命中：入口脚本有语法错误 —— 解释器连 import 都没走完。' -ForegroundColor Red
    Write-Host "  用服务的那个解释器直接编译检查：& '$app' -m py_compile <脚本路径>" -ForegroundColor White
}
elseif ($tailText -match 'denied|PermissionError|Access is denied') {
    Write-Host "  命中：权限不足 —— $account 读不到/写不了某个路径。" -ForegroundColor Red
    Write-Host '  用 icacls 给应用目录授权，或改用有权限的服务账号。' -ForegroundColor White
}
elseif ($tailText -match "can't open file|No such file or directory|系统找不到|not recognized") {
    Write-Host '  命中：文件路径不对 —— Application / AppParameters / AppDirectory 有一个写错了。' -ForegroundColor Red
}
elseif ($tailText -match 'Address already in use|WinError 10048|端口被占用|only one usage of each socket') {
    Write-Host '  命中：端口被占用 —— 常见于前台跑着一个、服务又拉起一个。' -ForegroundColor Red
    Write-Host '  netstat -ano | findstr :<端口>  找到占用进程。' -ForegroundColor White
}
elseif ($tailText -match 'Traceback') {
    Write-Host '  有 traceback，但不在上面的常见模式里 —— 直接看第 4 节的最后几行。' -ForegroundColor Red
}
elseif ($tailText.Trim().Length -eq 0) {
    if ($stRaw -match 'SERVICE_RUNNING') {
        Write-Host '  服务在跑，但 stdout/stderr 两个日志都是空的 —— 这很常见，不代表有问题：' -ForegroundColor Green
        Write-Host '    · 很多程序被重定向后不会及时 flush（要等缓冲区满或进程退出才落盘）' -ForegroundColor DarkGray
        Write-Host '    · 也有的程序直接往控制台写、不走标准输出，NSSM 抓不到' -ForegroundColor DarkGray
        Write-Host '    要确认它真在干活：看它自己的日志文件 / netstat 看它监听的端口 / 看内存变化。' -ForegroundColor DarkGray
    } else {
        Write-Host '  日志是空的，程序像是没被执行到。' -ForegroundColor Yellow
        Write-Host '  服务起来后 NSSM 会重试（AppRestartDelay），可以先等 10 秒再看。' -ForegroundColor DarkGray
        Write-Host '  注意：很多程序被重定向后不 flush（要等缓冲满或退出），' -ForegroundColor DarkGray
        Write-Host '        所以"日志空"不等于"没跑"；结合第 1 节状态和第 3 节路径自检一起判断。' -ForegroundColor DarkGray
    }
}
elseif ($stRaw -match 'SERVICE_RUNNING') {
    Write-Host '  没发现异常：服务在跑，日志也干净，收工。' -ForegroundColor Green
}
else {
    Write-Host '  日志里没有明确的异常 —— 可能是程序正常跑完了就退出。' -ForegroundColor Yellow
    Write-Host '  常驻程序不该自己退出；检查入口脚本是不是收到参数后就 return / exit 了。' -ForegroundColor DarkGray
}

$reproLead = if ($isPython) {
    '用 NSSM 配的同一个解释器和参数，在前台原样跑一遍：'
} else {
    '用 NSSM 配的同一个程序和参数，在前台原样跑一遍：'
}
Write-Host ''
Write-Host "  最快的验证手段：$reproLead" -ForegroundColor Cyan
Write-Host "    cd '$dir'" -ForegroundColor White
Write-Host ('    & ''{0}'' {1}' -f $app, $pars) -ForegroundColor White
Write-Host '  （前台跑用的是**你自己的账号**，所以权限/环境差异不一定能复现；' -ForegroundColor DarkGray
Write-Host '    能复现的，报错一定和 stderr.log 里的一致。）' -ForegroundColor DarkGray

Write-Host ''
Write-Host '  修好之后的收尾命令（stop/start 需要管理员权限，否则报 Can''t open service!）：' -ForegroundColor Cyan
Write-Host "    & '$NssmExe' stop    $ServiceName" -ForegroundColor White
Write-Host "    & '$NssmExe' start   $ServiceName" -ForegroundColor White
Write-Host "    & '$NssmExe' status  $ServiceName" -ForegroundColor White
Write-Host "    Get-Content '$($cfg['AppStderr'])' -Wait -Tail 20" -ForegroundColor White
Write-Host ''
Write-Host '  提示：nssm status 永远返回 exit 0（服务不存在才返回 3），' -ForegroundColor DarkGray
Write-Host '        判断状态只能看它打印的 SERVICE_XXX 文本。' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  （本脚本只读，没有改动任何配置。）' -ForegroundColor DarkGray
