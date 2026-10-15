<#
.SYNOPSIS
    把 Python 脚本用 NSSM 注册成 Windows 服务。

.DESCRIPTION
    必须用**管理员**权限运行（注册/删除服务需要）。脚本会：
      1. 找到 python.exe（可 -PythonExe 显式指定）
      2. 清理同名旧服务（仅当 -Force）
      3. nssm install 注册服务
      4. 一次性写入全部服务参数
      5. nssm dump 打印最终配置，然后启动服务

    ★ 本脚本不含任何写死的项目名：要跑哪个脚本、带什么参数、日志放哪，
      全部由参数决定。五个"项目相关"的参数是：
        -AppDir         项目目录（默认本脚本所在目录）
        -EntryScript    入口脚本（默认 service_demo.py，可绝对/相对路径）
        -ScriptArguments 传给入口脚本的参数数组
        -LogDir         日志目录（默认 <AppDir>\logs）
        -DisplayName / -Description  服务显示名与描述
      三者优先级（决定 AppParameters 的最终内容）：
        1. -AppParameters  ——  原样使用，一个字符都不改（最自由）
        2. -ScriptArguments ——  自动拼成  -u "<入口脚本>" <你给的参数...>
        3. 都不给          ——  用本 demo 的默认参数
                               -u "<入口脚本>" --interval N --log-dir <logs> --data-dir <data>
      注意 -Interval 只在第 3 种情况下有用（它会变成 --interval 和 DEMO_INTERVAL）。

    ★★ 两种模式：默认是"Python 脚本模式"，给了 -Exe 就切到"通用 EXE 模式"。
      通用 EXE 模式（-Exe <路径>）下：
        - Application 直接就是那个 exe（不去探测 Python，也不加 -u）
        - 不注入任何 Python 专用环境变量（要用环境变量请用 -EnvironmentExtra）
        - -ScriptArguments 变成"传给该 exe 的命令行参数"
        - 其余照旧：日志、自动重启、优雅停止、启动失败自动诊断都一样
      这样 nssm 的用法（它本来就是个通用 exe 包装器）就都能用上了。
      注意：如果那个 exe **本身就是 Windows 服务程序**（用 SCM API 写的），
      不该用 NSSM，直接用 sc.exe create 注册即可。

.EXAMPLE
    # 最简单的用法：管理员 PowerShell 下直接执行（注册 demo 本身）
    .\install_service.ps1

.EXAMPLE
    # ★ 注册一个普通 exe（不是 Python）：换 -Exe 就行
    .\install_service.ps1 -ServiceName MyAgent `
        -AppDir 'C:\tools\myagent' `
        -Exe 'C:\tools\myagent\agent.exe' `
        -ScriptArguments @('--config', 'agent.ini', '--verbose') `
        -LogDir 'C:\tools\myagent\logs' `
        -DisplayName 'My Agent (MyAgent)' -Force

.EXAMPLE
    # 普通 exe + 自定义环境变量 + 更长的优雅停止时间（清理很慢的程序）
    .\install_service.ps1 -Exe 'C:\tools\worker\worker.exe' `
        -EnvironmentExtra @('WORKER_MODE=service', 'TZ=Asia/Shanghai') `
        -StopMethodConsole 30000

.EXAMPLE
    # ★ 换成别的项目：入口脚本、参数、日志目录全部由参数指定，不改脚本
    .\install_service.ps1 -ServiceName SensorMonitor `
        -AppDir 'C:\Project\sensor-monitor-telnet' `
        -EntryScript 'main.py' `
        -ScriptArguments @('--config', 'config.yaml', '--verbose') `
        -LogDir 'C:\Project\sensor-monitor-telnet\logs' `
        -DisplayName '传感器监控 (SensorMonitor)'

.EXAMPLE
    # 参数特别复杂、想自己完全掌控命令行时，直接给 -AppParameters
    .\install_service.ps1 -EntryScript 'main.py' `
        -AppParameters '-u "C:\my app\main.py" --interval 5 --log-dir "C:\my app\logs"'

.EXAMPLE
    # 用普通域账号运行服务（需要账号有"作为服务登录"权限）
    .\install_service.ps1 -Account 'CONTOSO\svc_worker'    # 会提示输入密码
    提示：交互输入密码无法用 nssm set 完成，请改用 NSSM GUI 或
          nssm set <服务名> ObjectName <账号> <密码>
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    # Windows 服务名（sc.exe / Get-Service 里看到的名字）
    [string]$ServiceName = 'PyDemoService',

    # ★ 通用 EXE 模式：要注册的 exe 路径（相对 -AppDir 或绝对路径）。
    # 给了它就不走 Python 逻辑：直接用这个 exe 当 Application。
    [string]$Exe,

    # python.exe 的完整路径；不填则自动探测（仅 Python 脚本模式使用）
    [string]$PythonExe,

    # 应用目录（工作目录），默认就是本脚本所在目录
    [string]$AppDir = $PSScriptRoot,

    # 入口脚本：相对 -AppDir 的路径，或绝对路径。想换成别的项目就改它
    # （仅 Python 脚本模式使用；与 -Exe 互斥）
    [string]$EntryScript = 'service_demo.py',

    # 传给程序的参数（数组，逐个元素传，不用自己拼引号）
    # 给了它就不再附加 demo 的 --interval/--log-dir/--data-dir
    [Alias('ProgramArguments', 'ExeArguments')]
    [string[]]$ScriptArguments,

    # 直接指定 AppParameters 原文（优先级最高，给了就完全按它来，参数名/顺序自定）
    [string]$AppParameters,

    # 额外写入的服务环境变量，形如 @('KEY=VALUE', 'K2=V2')
    # （Python 模式还会自动加 PYTHONUNBUFFERED / PYTHONIOENCODING）
    [string[]]$EnvironmentExtra,

    # 日志目录：NSSM 抓 stdout/stderr 就写这。默认 <AppDir>\logs，可给绝对路径
    [string]$LogDir = 'logs',

    # 不要日志文件：把程序的 stdout/stderr 丢到 NUL（不产生 stdout.log/stderr.log）。
    # ⚠️ 注意实现方式是设成 NUL，不是"不设置"——实测未配置 AppStdout/AppStderr 时
    #    NSSM 给程序接的是没人读的管道，程序写满缓冲就永久卡死。详见 README 坑 9。
    [Alias('NoLog', 'NoRedirect', 'NoLogFiles')]
    [switch]$DiscardOutput,

    # 服务显示名（默认 "Python 服务 (<服务名>)"）
    [string]$DisplayName,

    # 服务描述（默认按入口脚本/日志目录自动生成）
    [string]$Description,

    # nssm stop 时"先发一个 Ctrl+C（控制台停止信号）"等多久（毫秒）再升级为强杀。
    # 不填则：Python 模式 20000（等 Python 收尾），EXE 模式 3000（够普通程序反应）。
    # 程序收尾很慢就调大；GUI 程序不吃 Ctrl+C 就调小（NSSM 会接着尝试关窗口）。
    [int]$StopMethodConsole,

    # nssm.exe 路径
    [string]$NssmExe = 'C:\Windows\nssm.exe',

    # 传给 Python 脚本的心跳间隔（秒）。**仅在使用默认参数时生效**
    [double]$Interval = 5,

    # 启动类型：SERVICE_AUTO_START / SERVICE_DELAYED_AUTO_START / SERVICE_DEMAND_START
    [string]$StartType = 'SERVICE_AUTO_START',

    # 服务运行账号，默认 LocalSystem（无需密码）
    [string]$Account = 'LocalSystem',

    # 给 LocalSystem 授予应用目录权限（应用目录不在用户目录下时才需要）
    [switch]$GrantPermissions,

    # 覆盖已存在的同名服务
    [switch]$Force,

    # 只写配置，不启动服务
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------- #
# ★ 跨 PowerShell 版本的参数传递处理（踩过坑，务必保留）
#
# PowerShell 5.1 用"传统"方式把参数交给原生 exe：**只给含空格的参数套一层引号，
# 完全不处理参数内部的双引号**。于是像
#     -u "C:\my app\main.py" --log-dir "C:\my app\logs"
# 这样一个字符串，会被拆成 3 个参数传给 nssm：
#     ['-u C:\my', 'app\main.py --interval 5 --log-dir C:\my', 'app\logs']
# 注册出来的服务参数就是垃圾。PowerShell 7.2+ 的 Standard/Windows 模式没有这个问题。
#
# 实测（两条路径都给 exe 看 argv）：
#   PS 5.1.19041 + 原样传  → argc=3，被拆坏
#   PS 5.1.19041 + 手工转义 → argc=1，正确
#   PS 7.6 + 原样传        → argc=1，正确
#
# 处理办法：探测当前模式，传统模式下把内层 " 转义成 \"，其余情况原样传。
# --------------------------------------------------------------------------- #
$nativeArgMode = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
$script:LegacyArgPassing = ($null -eq $nativeArgMode) -or ($nativeArgMode -eq 'Legacy')

# --------------------------------------------------------------------------- #
# 小工具
# --------------------------------------------------------------------------- #

# ★ 调用原生 exe 的**唯一**入口。集中处理两个"只在 Windows PowerShell 5.1 上现形"的毛病：
#
#   毛病一（本次踩到）：本脚本开头设了 $ErrorActionPreference = 'Stop'。
#           5.1 里原生命令只要往 **stderr** 写一个字，就会被包装成 NativeCommandError
#           （终止性错误）**直接中断脚本**，连 `2>$null` 都救不了。
#           而很多程序天生就往 stderr 写东西 —— 例如 py.exe 的表头
#           "Installed Pythons found by C:\Windows\py.exe Launcher for Windows *"。
#           于是脚本在探测解释器那一步就挂了。
#           处理：调用期间把 EAP 临时降为 Continue，退出码用 $LASTEXITCODE 自己判断
#           （本来就要判断，等于零损失）。
#
#   毛病二：见文件开头关于"内层双引号转义"的说明。
#
#   PS 7 下 stderr 不会抛错、引号也会自动转义，所以这两个毛病都只在 5.1 上现形。
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    # 用 @() 包一层，保证 splat 时一定是数组（标量 splat 的行为容易踩坑）
    $nativeArgs = @(foreach ($arg in $Arguments) {
        if ($script:LegacyArgPassing) {
            # Windows PowerShell 5.1：自己把参数**内部**的双引号转义成 \"
            $arg -replace '"', '\"'
        } else {
            $arg
        }
    })

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    # nssm 的非 ASCII 输出（本地化错误文本、dump/get 出来的中文 DisplayName/Description）
    # 一律是 **UTF-8 字节**；而 PS 5.1 解码原生命令 stdout 用的是 [Console]::OutputEncoding，
    # 中文机器上默认是 GBK/936 —— 同一段字节被按 GBK 解就全是乱码。实测（提权 PS 5.1，CP936）：
    #     CP936 解 → OpenService(): 鎸囧畾鐨勬湇鍔℃湭瀹夎銆?
    #     UTF-8 解 → OpenService(): 指定的服务未安装。
    # 两次的原始字节逐字节相同 —— 所以只在**解码**这一层临时切一下，不改 nssm 的行为；
    # 本脚本自己 Write-Host 的中文走 WriteConsoleW，也不受影响。PS 7 本来就用 UTF-8，此处是空操作。
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

    # 统一转成字符串再返回，两个坑都在这里处理掉：
    #   1) 原生命令往 stderr 写字时 PowerShell 产出的是 ErrorRecord，
    #      而 ErrorRecord.ToString() 会带上 "System.Management.Automation.RemoteException"
    #      这类类型噪声 —— stderr 的**原文**在 .Exception.Message 里。
    #   2) PS 5.1 / PS 7 还会额外塞进来几个"消息为空"的 ErrorRecord，
    #      它们在拼接时会变成一串 RemoteException 噪声 —— 直接丢掉。
    # 转成字符串后，上层的 -join / -match 行为也可预期。
    $lines = @(foreach ($item in $output) {
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                $text = $item.Exception.Message
            } else {
                $text = "$item"
            }
            if (-not [string]::IsNullOrEmpty($text)) { $text }
        })

    return [pscustomobject]@{
        Output   = $lines
        ExitCode = $exitCode
    }
}

function Invoke-Nssm {
    param([string[]]$Arguments)

    $result = Invoke-Native -FilePath $NssmExe -Arguments $Arguments

    if ($result.ExitCode -ne 0) {
        throw ("nssm {0} 执行失败（exit {1}）：`n{2}" -f `
                ($Arguments -join ' '), $result.ExitCode, ($result.Output -join "`n"))
    }
    if ($result.Output.Count) {
        Write-Host ("        " + ($result.Output -join "`n        ")) -ForegroundColor DarkGray
    }
    return $result.Output
}

# --------------------------------------------------------------------------- #
# 启动失败时的自动排错
#
# 本机实测结论（把 4 种情况都复现过一遍）：
#   nssm start 返回的 "Unexpected status SERVICE_XXX" **只是表象**，
#   真正的报错在 AppStderr 指向的文件里。
#
#   SERVICE_PAUSED  → 程序被拉起来了，但立刻以非 0 退出码崩溃；
#                     NSSM 为了不无限重启触发节流(throttle)，把服务置为 Paused。
#                     服务**注册是成功的**，问题在 Python 程序本身。
#                     注意：Paused 之后 nssm start / nssm continue 都无效，
#                     必须先 nssm stop（实测 stop 在 Paused 上工作正常）。
#   SERVICE_STOPPED → 程序立刻退出，且退出码命中了 AppExit 里的 Exit 规则
#                     （本脚本配了 "0 Exit"），NSSM 于是把服务停掉。
# --------------------------------------------------------------------------- #
function Show-StartupFailure {
    param(
        [string]$ServiceName,
        [string]$LogDir,
        [int]$ExitCode,
        [string[]]$Output,
        # Python 模式才提示 import/解释器那几类原因；EXE 模式换成缺 DLL/缺配置那几类
        [switch]$PythonMode
    )

    Write-Host ""
    Write-Host "=============== 启动检查未通过，下面是排错信息 ===============" -ForegroundColor Red
    Write-Host "  nssm start 退出码：$ExitCode" -ForegroundColor Red
    foreach ($line in $Output) { Write-Host "  $line" -ForegroundColor Red }
    Write-Host ""

    # nssm status 实测（NSSM 2.24）：**永远 exit 0**，状态只体现在它打印的文本里。
    # 只有服务不存在时才非 0（exit 3 + "Can't open service!"）。
    # 所以必须解析文本，不能看退出码。
    $statusResult = Invoke-Native -FilePath $NssmExe -Arguments @('status', $ServiceName)
    $statusRaw = ($statusResult.Output -join ' ').Trim()
    $statusText = switch -Regex ($statusRaw) {
        'SERVICE_PAUSED' { 'PAUSED（已暂停）' }
        'SERVICE_RUNNING' { 'RUNNING（运行中）' }
        'SERVICE_START_PENDING' { 'START_PENDING（正在启动）' }
        'SERVICE_STOP_PENDING' { 'STOP_PENDING（正在停止）' }
        'SERVICE_STOPPED' { 'STOPPED（已停止）' }
        default { $statusRaw }
    }
    Write-Host "  状态快照：$statusText" -ForegroundColor Yellow
    # 实测：程序反复崩溃时 NSSM 会在 PAUSED / RUNNING 之间抖动，
    # 所以这个快照可能和刚才的报错对不上，以 nssm start 的报错为准。
    if ($Output -match 'SERVICE_PAUSED' -and $statusRaw -notmatch 'SERVICE_PAUSED') {
        Write-Host "  （程序反复崩溃时 NSSM 会在 PAUSED 和 RUNNING 之间来回抖动，" -ForegroundColor DarkGray
        Write-Host "    这个快照只是瞬时值 —— 以 nssm start 的报错为准）" -ForegroundColor DarkGray
    }

    if ($statusRaw -match 'SERVICE_START_PENDING' -and $Output -notmatch 'SERVICE_PAUSED') {
        Write-Host @"

  诊断：START_PENDING（等了 30 秒仍停在"正在启动"）
    程序一直没从 START_PENDING 进入 RUNNING，可能是：
      1. 启动特别慢（x86/GUI 程序，或要加载大量数据/驱动）；
      2. 卡在某处（等网络、等锁、等不存在的设备）；
      3. 启动过程中反复崩溃重启，NSSM 一直在节流。
    手工确认进程到底有没有被拉起来：
      & '$NssmExe' processes $ServiceName
      Get-Process                       # 找你的 exe 名
      Get-WinEvent -LogName Application -MaxEvents 50 |
        Where-Object { `$_.ProviderName -eq 'nssm' }
    注意：如果只是慢，再等一会儿它自己就 RUNNING 了 —— 这种 nssm start 的
          "Unexpected status SERVICE_START_PENDING" 属于**误报**，不是故障。
"@ -ForegroundColor Yellow
    } elseif ($Output -match 'SERVICE_PAUSED' -or $statusRaw -match 'SERVICE_PAUSED') {
        $why = if ($PythonMode) { '（通常是 Python 的 traceback）' } else { '（通常是程序自己打印的错误）' }
        Write-Host @"

  诊断：SERVICE_PAUSED
    服务注册是**成功**的，程序也被拉起来了，但它**立刻以非 0 退出码崩溃**。
    NSSM 为了不无限重启，触发节流并把服务置为 Paused。
    真正的原因在下面的 stderr.log 里$why。

    注意：Paused 状态下 nssm start / nssm continue 都无效（已实测），
          必须先执行：  nssm stop <服务名>
          修好问题后再 start。
"@ -ForegroundColor Yellow
    } elseif ($Output -match 'SERVICE_STOPPED' -or $statusRaw -match 'SERVICE_STOPPED') {
        $exitHint = if ($PythonMode) { '要么在启动阶段就走了 sys.exit(0)。' } else { '要么启动阶段就直接退出了。' }
        Write-Host @"

  诊断：SERVICE_STOPPED
    程序启动后立刻退出，且退出码命中了 AppExit 里的 Exit 规则
    （本脚本配了 "0 Exit"），NSSM 于是把服务停掉了。
    说明这个程序不是"常驻循环"的：要么跑完就退出了，
    $exitHint
"@ -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  NSSM 实际执行的命令行：" -ForegroundColor Cyan
    foreach ($key in 'Application', 'AppParameters', 'AppDirectory') {
        $value = (Invoke-Native -FilePath $NssmExe -Arguments @('get', $ServiceName, $key)).Output -join ' '
        Write-Host ("    {0,-14} = {1}" -f $key, $value)
    }

    Write-Host ""
    Write-Host "  日志文件尾部：" -ForegroundColor Cyan
    $anyLog = $false
    $logNames = if ($PythonMode) { @('stderr.log', 'stdout.log', 'service.log') } else { @('stderr.log', 'stdout.log') }
    foreach ($name in $logNames) {
        $path = Join-Path $LogDir $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $anyLog = $true
        $size = (Get-Item -LiteralPath $path).Length
        Write-Host ("    --- {0}（{1} 字节）---" -f $name, $size) -ForegroundColor DarkGray
        if ($size -eq 0) {
            Write-Host "        （空）" -ForegroundColor DarkGray
            continue
        }
        Get-Content -LiteralPath $path -Tail 30 -Encoding UTF8 |
            ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
    }
    if (-not $anyLog) {
        if ($DiscardOutput) {
            # 别让用户以为"没日志 = 没跑起来"——这次是主动丢掉输出的
            Write-Host "    （本次用了 -DiscardOutput：输出丢到 NUL，压根没有日志可看）" -ForegroundColor DarkGray
            Write-Host "     要抓这次启动报错，临时改成文件再复现一遍：" -ForegroundColor DarkGray
            Write-Host "       & '$NssmExe' set $ServiceName AppStdout '$LogDir\stdout.log'" -ForegroundColor DarkGray
            Write-Host "       & '$NssmExe' set $ServiceName AppStderr '$LogDir\stderr.log'" -ForegroundColor DarkGray
            Write-Host "       & '$NssmExe' stop $ServiceName; & '$NssmExe' start $ServiceName" -ForegroundColor DarkGray
        } else {
            Write-Host "    （日志目录里什么都没有，可能程序根本没跑起来）" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  常见原因（按概率排序）：" -ForegroundColor Cyan
    if ($PythonMode) {
        Write-Host "    1. 入口脚本路径/文件名不对  → stderr 里是 can't open file 'xxx'"
        Write-Host "    2. 缺依赖包：服务以 LocalSystem 运行，看不到你 pip install --user"
        Write-Host "       装在 %APPDATA%\Python 下的包 → stderr 里是 ModuleNotFoundError"
        Write-Host "    3. 脚本一启动就抛异常（import 报错、配置读不到、端口被占用……）"
        Write-Host "    4. 解释器与依赖对不上（例如 telnetlib 在 Python 3.13 已被删除）"
        Write-Host "    5. 相对路径失效：服务的当前目录是 AppDirectory，不是脚本所在目录"
    } else {
        Write-Host "    1. exe 路径不对  → stderr 里是「系统找不到指定的文件」"
        Write-Host "    2. 缺运行库/DLL（C++ Redistributable、.NET、VC runtime）"
        Write-Host "       → 退出码常为 0xC0000135 / 0xC000007B，事件日志里能看到"
        Write-Host "    3. 程序一启动就抛异常（配置读不到、端口被占用、连不上数据库……）"
        Write-Host "    4. 这类 exe 需要 GUI/桌面会话，而服务跑在 session 0，没有桌面"
        Write-Host "       （顺带一提：如果它本身就是 Windows 服务程序，别用 NSSM，用 sc create）"
        Write-Host "    5. 相对路径失效：服务的当前目录是 AppDirectory，不是 exe 所在目录"
    }

    Write-Host ""
    $reproLead = if ($PythonMode) {
        '用 NSSM 配的同一个解释器和参数，在前台原样跑一遍：'
    } else {
        '用 NSSM 配的同一个程序和参数，在前台原样跑一遍：'
    }
    Write-Host "  最快的定位办法：$reproLead" -ForegroundColor Cyan
    $app = (Invoke-Native -FilePath $NssmExe -Arguments @('get', $ServiceName, 'Application')).Output -join ''
    $par = (Invoke-Native -FilePath $NssmExe -Arguments @('get', $ServiceName, 'AppParameters')).Output -join ''
    Write-Host "    & '$app' $par"
    Write-Host "  （记得先 cd 到 AppDirectory，并且注意前台跑用的是你自己的账号，"
    Write-Host "     LocalSystem 才有的权限/环境差异不一定能复现）"
}

# 带空格的参数要加引号，否则 NSSM 会把路径拆成多个参数
function Quote-Arg {
    param([string]$Value)
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

function Resolve-PythonInterpreter {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "指定的 PythonExe 不存在：$Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $candidates = [System.Collections.Generic.List[string]]::new()

    # 1) py launcher 注册的解释器
    #    两个坑：
    #      a) py -0p 的表头 "Installed Pythons found by ..." 是往 **stderr** 写的，
    #         5.1 + EAP=Stop 下会直接中断脚本 —— 所以必须走 Invoke-Native。
    #      b) Microsoft Store 版本只输出**裸文件名**（python3.12.exe），不是完整路径；
    #         下面的正则要求"必须带盘符"，正好把这类条目自然排除。
    #         表头里虽然有个 C:\Windows\py.exe，但它不在行尾，`\s*$` 匹配不上，不会误判。
    $pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        $pyList = Invoke-Native -FilePath $pyLauncher.Source -Arguments @('-0p')
        if ($pyList.ExitCode -eq 0) {
            foreach ($line in $pyList.Output) {
                if ("$line" -match '([A-Za-z]:\\[^"]*?\.exe)\s*$') { $candidates.Add($Matches[1]) }
            }
        } else {
            Write-Warning "py -0p 执行失败（exit $($pyList.ExitCode)），跳过 py launcher 探测，改用 PATH 探测。"
        }
    }

    # 2) PATH 里的 python.exe
    foreach ($cmd in (Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        $candidates.Add($cmd.Source)
    }

    # Microsoft Store 版的 python.exe 是个应用别名，做服务容易踩权限/沙箱的坑，排除掉
    $usable = $candidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Where-Object { $_ -notmatch 'WindowsApps' } |
        Select-Object -Unique

    if (-not $usable) {
        throw @"
没有找到可用的 python.exe（已排除 Microsoft Store 版）。
请安装 python.org 的正式版本，然后用 -PythonExe 指定，例如：
    .\install_service.ps1 -PythonExe 'C:\Python312\python.exe'
"@
    }

    # 优先级：用户级安装 > 其他 > Visual Studio 自带的共享解释器
    # 注意 @(...) 不能省：单个结果时 PowerShell 会把它当字符串，
    # 再取 [0] 就变成"第一个字符"了（踩过：解释器路径变成 "C"）。
    return @($usable | Sort-Object -Property @{ Expression = {
                if ($_ -match 'Programs\\Python') { 1 }
                elseif ($_ -match 'Microsoft Visual Studio') { 5 }
                else { 3 }
            } })[0]
}

# --------------------------------------------------------------------------- #
# 1. 前置检查 → 决定"跑什么、怎么跑"
# --------------------------------------------------------------------------- #
if (-not (Test-Path -LiteralPath $NssmExe)) {
    throw "找不到 nssm.exe：$NssmExe。请用 -NssmExe 指定实际路径。"
}
if (-not (Test-Path -LiteralPath $AppDir)) {
    throw "应用目录不存在：$AppDir"
}

# ---- 模式判定：-Exe = 通用 EXE 模式；否则 = Python 脚本模式 --------------------
$useExe = -not [string]::IsNullOrWhiteSpace($Exe)
$pythonMode = -not $useExe

if ($useExe -and $PSBoundParameters.ContainsKey('EntryScript')) {
    throw '-Exe 与 -EntryScript 互斥：前者注册普通 exe，后者注册 Python 脚本，只能给一个。'
}
if ($useExe -and $PSBoundParameters.ContainsKey('PythonExe')) {
    Write-Warning '-Exe 模式下 -PythonExe 无意义，本次忽略。'
}

$AppDir = (Resolve-Path -LiteralPath $AppDir).Path

# ---- 程序路径：Python 模式两步走（解释器 + 脚本）；EXE 模式一步到位 -----------
if ($useExe) {
    $programPath = if ([System.IO.Path]::IsPathRooted($Exe)) { $Exe } else { Join-Path $AppDir $Exe }
    if (-not (Test-Path -LiteralPath $programPath -PathType Leaf)) {
        throw "找不到要注册的 exe：$programPath（相对路径基于 -AppDir '$AppDir'）。"
    }
    $programPath = (Resolve-Path -LiteralPath $programPath).Path
    $scriptPath = ''                 # EXE 模式没有脚本
    $ApplicationPath = $programPath
} else {
    # 入口脚本：绝对路径直接用，相对路径基于 -AppDir
    $scriptPath = if ([System.IO.Path]::IsPathRooted($EntryScript)) {
        $EntryScript
    } else {
        Join-Path $AppDir $EntryScript
    }
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "找不到入口脚本：$scriptPath。用 -EntryScript 指定（相对路径基于 -AppDir '$AppDir'）。"
    }
    $scriptPath = (Resolve-Path -LiteralPath $scriptPath).Path
    $programPath = $scriptPath
    # 只有 Python 模式才去探测解释器（EXE 模式别白跑一遍 py -0p）
    $ApplicationPath = Resolve-PythonInterpreter -Explicit $PythonExe
}

# ---- 日志目录：绝对路径直接用，相对路径基于 -AppDir ----------------------------
$logDir = if ([System.IO.Path]::IsPathRooted($LogDir)) { $LogDir } else { Join-Path $AppDir $LogDir }
$logDir = [System.IO.Path]::GetFullPath($logDir)

# ---- 停止时"发 Ctrl+C 后等多久"（毫秒）----------------------------------------
# Python 模式 20000（等解释器收尾）；普通 exe 3000（够一般程序反应，
# 免得 GUI 程序明明不吃 Ctrl+C 还要白等 20 秒才轮到"关窗口"那一步）。
# -StopMethodConsole 显式给值就以它为准。
if ($PSBoundParameters.ContainsKey('StopMethodConsole')) {
    if ($StopMethodConsole -le 0) { throw '-StopMethodConsole 要大于 0（单位毫秒）。' }
    $consoleStopMs = $StopMethodConsole
} else {
    $consoleStopMs = if ($pythonMode) { 20000 } else { 3000 }
}

# ---- 三种参数模式：决定 AppParameters 里到底放什么 -----------------------------
# 1) -AppParameters  原样使用（最自由）
# 2) -ScriptArguments 自动拼：Python 模式 = -u "<脚本>" <参数…>；EXE 模式 = <参数…>
# 3) 都不给          Python 模式 → demo 默认参数；EXE 模式 → 无参数
#    （demo 专属的 data\ 目录和 DEMO_INTERVAL 只在第 3 种情况出现）
$hasRawParameters = -not [string]::IsNullOrWhiteSpace($AppParameters)
$hasUserArguments = (-not $hasRawParameters) -and ($null -ne $ScriptArguments) -and ($ScriptArguments.Count -gt 0)
$usingDemoDefaults = $pythonMode -and (-not $hasRawParameters) -and (-not $hasUserArguments)

if ($hasRawParameters) {
    $finalAppParameters = $AppParameters
} else {
    # -u 是 Python 解释器的开关（不让 stdout/stderr 缓冲），普通 exe 不认识它，
    # 所以只在 Python 模式加。
    $paramParts = if ($pythonMode) { @('-u', (Quote-Arg $scriptPath)) } else { @() }
    if ($hasUserArguments) {
        # 含空格的参数自动补引号（已经写了自己那层引号的不重复包）
        $paramParts += @(foreach ($arg in $ScriptArguments) {
                if ($arg -match '\s' -and $arg -notmatch '^".*"$') { Quote-Arg $arg } else { $arg }
            })
    } elseif ($usingDemoDefaults) {
        $dataDir = Join-Path $AppDir 'data'
        $paramParts += @(
            '--interval', $Interval
            '--log-dir', (Quote-Arg $logDir)
            '--data-dir', (Quote-Arg $dataDir)
        )
    }
    $finalAppParameters = $paramParts -join ' '
}

# demo 专用目录只在"Python 模式 + 用默认参数"时才建，别的项目不该被塞一个空 data\
# -DiscardOutput 时压根不会有日志文件，别留下一堆空 logs\ 目录
if (-not $DiscardOutput) {
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
}
if ($usingDemoDefaults) {
    foreach ($dir in @((Join-Path $AppDir 'data'), (Join-Path $AppDir 'data\inbox'), (Join-Path $AppDir 'data\done'))) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
}

if (-not $DisplayName) {
    $DisplayName = if ($pythonMode) { "Python 服务 ($ServiceName)" } else { "服务 ($ServiceName)" }
}
if (-not $Description) {
    $Description = if ($hasRawParameters) {
        "由 NSSM 托管的程序。命令行：$finalAppParameters"
    } elseif ($pythonMode) {
        "由 NSSM 托管的 Python 程序。入口脚本：$scriptPath；日志：$logDir\service.log"
    } elseif ($DiscardOutput) {
        "由 NSSM 托管的程序：$programPath；输出已丢弃"
    } else {
        "由 NSSM 托管的程序：$programPath；日志：$logDir"
    }
}

if ($PSBoundParameters.ContainsKey('Interval') -and -not $usingDemoDefaults) {
    Write-Warning '-Interval 只在「Python 模式 + 用 demo 默认参数」时生效，本次忽略。'
}

Write-Host "== 安装前检查 ==" -ForegroundColor Cyan
Write-Host "  模式       : $(if ($pythonMode) { 'Python 脚本模式' } else { '通用 EXE 模式' })"
Write-Host "  服务名     : $ServiceName"
Write-Host "  显示名     : $DisplayName"
Write-Host "  应用目录   : $AppDir"
if ($pythonMode) {
    Write-Host "  入口脚本   : $scriptPath"
    Write-Host "  解释器     : $ApplicationPath"
} else {
    Write-Host "  可执行文件 : $programPath"
}
Write-Host "  命令行     : $ApplicationPath $(if ([string]::IsNullOrEmpty($finalAppParameters)) { '（无参数）' } else { $finalAppParameters })"
$argMode = if ($hasRawParameters) { '-AppParameters 原样使用' }
elseif ($hasUserArguments) { '-ScriptArguments 用户参数' }
elseif ($usingDemoDefaults) { 'demo 默认参数' }
else { '无参数' }
Write-Host "  参数来源   : $argMode" -ForegroundColor Yellow
Write-Host "  日志目录   : $(if ($DiscardOutput) { '（-DiscardOutput：输出丢弃到 NUL，不产生日志文件）' } else { $logDir })"
Write-Host "  服务账号   : $Account"
Write-Host ""

# --------------------------------------------------------------------------- #
# 2. 处理同名旧服务
# --------------------------------------------------------------------------- #
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    if (-not $Force) {
        if ($existing.Status -eq 'Paused') {
            Write-Warning "已存在的服务 $ServiceName 处于 Paused 状态 —— 通常意味着它的程序启动即崩溃被 NSSM 节流。"
            Write-Warning "Paused 状态下 nssm start / nssm continue 都无效，必须先： & '$NssmExe' stop $ServiceName"
        }
        throw "服务 $ServiceName 已存在（当前状态：$($existing.Status)）。先执行 .\uninstall_service.ps1 -ServiceName $ServiceName，或加 -Force 覆盖安装。"
    }
    Write-Host "服务 $ServiceName 已存在（当前状态：$($existing.Status)），-Force 生效，先停止并删除……" -ForegroundColor Yellow
    if ($existing.Status -ne 'Stopped') {
        # 实测：即便服务处于 Paused 状态，nssm stop 也能正常停下（exit 0 → Stopped），
        # 所以这里不用为 Paused 做特殊处理。
        Invoke-Nssm @('stop', $ServiceName) | Out-Null
        $existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    Invoke-Nssm @('remove', $ServiceName, 'confirm') | Out-Null
    Start-Sleep -Milliseconds 500
}

# --------------------------------------------------------------------------- #
# 3. 可选：授权服务账号访问应用目录
# --------------------------------------------------------------------------- #
if ($GrantPermissions) {
    Write-Host "给 $Account 授予 $AppDir 的完全控制权限……" -ForegroundColor Yellow
    # LocalSystem 的账号名要写成 NT AUTHORITY\SYSTEM
    $aclAccount = if ($Account -eq 'LocalSystem') { 'NT AUTHORITY\SYSTEM' } else { $Account }
    $aclResult = Invoke-Native -FilePath 'icacls.exe' -Arguments @(
        $AppDir, '/grant', "${aclAccount}:(OI)(CI)F", '/T', '/C', '/Q'
    )
    if ($aclResult.ExitCode -ne 0) {
        Write-Warning "icacls 返回 $($aclResult.ExitCode)，授权可能没成功：$($aclResult.Output -join ' | ')"
    }
}

# --------------------------------------------------------------------------- #
# 4. nssm install + nssm set
# --------------------------------------------------------------------------- #
# 注意：`nssm install <服务名>` 只给服务名、不给可执行文件时，
# NSSM 会弹出**配置 GUI 窗口**并一直阻塞等待操作 —— 在脚本里就是永久挂起。
# 所以这里必须把 Application 一起传进去（ARGV 形式），确保走命令行分支。
# 后面再用 nssm set 覆盖成最终参数，避免手工拼一长串参数的引号问题。
Write-Host "== 注册服务 ==" -ForegroundColor Cyan
# Python 模式顺手把 "-u <脚本>" 当初始参数传进去；EXE 模式的初始参数留空，
# 反正下面 $settings 会覆盖成最终值。
if ($pythonMode) {
    Invoke-Nssm @('install', $ServiceName, $ApplicationPath, '-u', $scriptPath) | Out-Null
} else {
    Invoke-Nssm @('install', $ServiceName, $ApplicationPath) | Out-Null
}

# 日志相关那几项单独算（哈希字面量里不能写 if）：
# -DiscardOutput → 输出丢 NUL；否则写文件并开启滚动。
$logSettings = [ordered]@{}
if ($DiscardOutput) {
    $logSettings['AppStdout'] = 'NUL'
    $logSettings['AppStderr'] = 'NUL'
    # 没有真实文件，滚动参数无意义 —— 不设，免得 dump 里出现误导性配置
} else {
    $logSettings['AppStdout']       = Join-Path $logDir 'stdout.log'
    $logSettings['AppStderr']       = Join-Path $logDir 'stderr.log'
    $logSettings['AppRotateFiles']  = 1        # 允许滚动
    $logSettings['AppRotateOnline'] = 1        # 服务运行时也能切分
    $logSettings['AppRotateBytes']  = 10485760 # 单文件 10MB
}

$settings = [ordered]@{
    # ---- 要跑什么 ----
    'Application'          = $ApplicationPath
    'AppParameters'        = $finalAppParameters
    'AppDirectory'         = $AppDir

    # ---- 服务外观 ----
    'DisplayName'          = $DisplayName
    'Description'          = $Description
    'Start'                = $StartType
    'ObjectName'           = $Account

    # ---- 日志兜底：NSSM 把子进程的 stdout/stderr 也接到文件并滚动 ----
    # 程序自己写的业务日志另算，这两个文件主要用来抓
    # "还没进到业务逻辑就挂了"的错（Python 的 import/语法错误、exe 的缺 DLL/缺配置）。
    #
    # -DiscardOutput 时改成 NUL（显式垃圾桶），**绝对不能"干脆不设置"**：
    # 实测（提权 PS 5.1，让程序往 stdout 狂写 84MB）——
    #   不设 AppStdout/AppStderr → 程序**永久卡死**：NSSM 给它的 stdout 是没人读的管道，
    #                              写满缓冲（4~64KB）就阻塞，进程一直挂着不退出；
    #   设成 NUL                  → 正常跑完、退出，不产生任何文件。✅
    # 所以"不要日志文件"的正解是 NUL，不是 reset。
    # （哈希字面量里不能写 if，所以先在下面算好 $logSettings，再合并进来）

    # ---- 停止行为：先发 Ctrl+C，给程序足够时间优雅退出 ----
    # Python 的 SIGINT 处理函数毫秒级返回，20 秒纯属保险；
    # 普通 exe 默认给 3 秒，收尾慢的用 -StopMethodConsole 调大。
    'AppStopMethodConsole' = $consoleStopMs

    # ---- 重启策略 ----
    # 非 0 退出（崩溃）→ 等 5 秒后自动拉起；退出码 0（正常收工）→ 不再拉。
    'AppRestartDelay'      = 5000

    # ---- 兜底强杀 ----
    'AppKillProcessTree'   = 1
}

# 把上面算好的日志设置并进来（顺序无所谓，反正只是逐项 nssm set）
foreach ($k in $logSettings.Keys) { $settings[$k] = $logSettings[$k] }

foreach ($key in $settings.Keys) {
    $value = [string]$settings[$key]
    if ([string]::IsNullOrEmpty($value)) {
        # 空值必须跳过，不能调 nssm set：
        # PowerShell 拼原生命令行时，空字符串参数会被**当成不存在的参数直接丢掉**，
        # 于是 nssm 收到的是 `set <服务名> <参数名>`（少一个值），它判定参数不全，
        # 打印整篇 usage 并 exit 1 —— 报错信息看起来像"命令用错了"，其实只是值为空。
        # 典型触发场景：EXE 模式且没给任何参数时，$finalAppParameters 就是空串。
        # 新装的服务这几项本来就是默认空值，不设即可。
        Write-Host "        （$key 为空，跳过设置，保持 NSSM 默认值）" -ForegroundColor DarkGray
        continue
    }
    Invoke-Nssm @('set', $ServiceName, $key, $value) | Out-Null
}

# AppExit 要写两条：先定义"其他退出码"的兜底行为，再单独覆盖 0。
# 注：nssm 对"设成默认值"的项会回一句
#     Reset parameter "xxx" for service "yyy" to its default.
# 这是正常的（比如 AppKillProcessTree=1 本来就是默认值），不是报错。
Invoke-Nssm @('set', $ServiceName, 'AppExit', 'Default', 'Restart') | Out-Null
Invoke-Nssm @('set', $ServiceName, 'AppExit', '0', 'Exit') | Out-Null

# 环境变量：一次写全，多次调用会互相覆盖
# PYTHONUNBUFFERED 让日志实时落盘；Python 3.7+ 默认 UTF-8，PYTHONIOENCODING 是给 3.6 及以下兜底。
# 这两个都是 Python 专用的，EXE 模式不注入；DEMO_INTERVAL 只有 demo 默认参数才用。
$extraEnv = @()
if ($pythonMode) { $extraEnv += @('PYTHONUNBUFFERED=1', 'PYTHONIOENCODING=utf-8') }
if ($usingDemoDefaults) { $extraEnv += "DEMO_INTERVAL=$Interval" }
if ($EnvironmentExtra) {
    foreach ($kv in $EnvironmentExtra) {
        if ($kv -notmatch '=') { throw "-EnvironmentExtra 的每一项都要是 KEY=VALUE 形式，收到：$kv" }
        $extraEnv += $kv
    }
}
if ($extraEnv.Count) {
    Invoke-Nssm (@('set', $ServiceName, 'AppEnvironmentExtra') + $extraEnv) | Out-Null
}

# --------------------------------------------------------------------------- #
# 5. 打印最终配置 + 启动
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "== 最终配置（nssm dump）==" -ForegroundColor Cyan
Invoke-Nssm @('dump', $ServiceName) | Out-Null

if (-not $NoStart) {
    Write-Host ""
    Write-Host "== 启动服务 ==" -ForegroundColor Cyan
    $startResult = Invoke-Native -FilePath $NssmExe -Arguments @('start', $ServiceName)

    # ⚠️ 不能只看 `nssm start` 的退出码：服务初始化期间处于 SERVICE_START_PENDING，
    # nssm 没等到 RUNNING 就直接返回 exit 1 +
    #   "Unexpected status SERVICE_START_PENDING in response to START control."
    # 而服务往往几秒后就自己进 RUNNING 了（实测 XEC.exe 这类 x86/GUI 程序要约 5 秒），
    # 这属于**误报**。所以这里自己轮询状态，等它稳定下来再下结论。
    #
    # 但只有 START_PENDING 才是"没等够"。如果 nssm start 报的是 SERVICE_PAUSED，
    # 那是程序启动即崩溃被节流 —— 此时服务的状态在 PAUSED/RUNNING 之间来回抖，
    # 轮询很可能刚好抓到 RUNNING，绝不能因此认为成功。
    $startMsg = ($startResult.Output -join ' ').Trim()
    $startSaidPending = ($startMsg -match 'SERVICE_START_PENDING')

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $pollSeconds = 30
    $statusRaw = ''
    while ($sw.Elapsed.TotalSeconds -lt $pollSeconds) {
        $probe = Invoke-Native -FilePath $NssmExe -Arguments @('status', $ServiceName)
        $statusRaw = ($probe.Output -join ' ').Trim()
        if ($statusRaw -match 'SERVICE_RUNNING|SERVICE_PAUSED|SERVICE_STOPPED') { break }
        Start-Sleep -Milliseconds 500      # 还在 START_PENDING/STOP_PENDING，继续等
    }
    $waited = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    # 判定：exit 0 → 成功；exit≠0 但只是 START_PENDING 没等够 → 看轮询结果；
    #       exit≠0 且是别的（PAUSED/STOPPED）→ 失败，无视瞬时快照。
    $looksGood = ($statusRaw -match 'SERVICE_RUNNING') -and
                 (($startResult.ExitCode -eq 0) -or $startSaidPending)

    if ($looksGood) {
        if ($startResult.ExitCode -ne 0) {
            Write-Host "  提示：nssm start 报了 START_PENDING（它没等够），服务随后已自行就绪。" -ForegroundColor DarkYellow
            Write-Host "        nssm start 原话：$startMsg" -ForegroundColor DarkGray
        } else {
            $startResult.Output | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
        }
        # 再等 3 秒复检：避免抓到"崩溃-重启循环"中途那一瞬间的 RUNNING
        Start-Sleep -Seconds 3
        $svc = Get-Service -Name $ServiceName
        if ($svc.Status -ne 'Running') {
            Show-StartupFailure -ServiceName $ServiceName -LogDir $logDir `
                -ExitCode 0 -Output @("刚才是 RUNNING，3 秒后变成了 $($svc.Status) —— 像是崩溃-重启循环") -PythonMode:$pythonMode
            throw "服务已注册，但反复重启（3 秒后状态：$($svc.Status)）。先看上面的日志尾部。"
        }
        Write-Host "  服务状态：RUNNING（等了 $waited 秒）" -ForegroundColor Green
    } else {
        # 真的起不来（PAUSED = 程序启动即崩溃并被节流；STOPPED = 压根没起来；
        # 超时仍 START_PENDING = 卡在初始化/太慢）—— 把真正的原因挖出来给用户看，
        # 而不是甩一句 "Unexpected status ..." 让人猜。
        Show-StartupFailure -ServiceName $ServiceName -LogDir $logDir `
            -ExitCode $startResult.ExitCode -Output $startResult.Output -PythonMode:$pythonMode
        throw "服务已注册，但启动失败（等了 $waited 秒，状态：$statusRaw）。修好上面的问题后执行：& '$NssmExe' stop $ServiceName; & '$NssmExe' start $ServiceName"
    }
}

Write-Host ""
Write-Host "完成。常用命令：" -ForegroundColor Green
Write-Host "  Get-Service $ServiceName"
Write-Host "  & '$NssmExe' status $ServiceName"
if ($DiscardOutput) {
    Write-Host "  # 本次是 -DiscardOutput：输出丢到 NUL，没有 stdout/stderr 日志可看"
    Write-Host "  # 要临时看输出，改成文件：& '$NssmExe' set $ServiceName AppStdout '$logDir\stdout.log'"
} else {
    Write-Host "  Get-Content '$logDir\stderr.log' -Wait -Tail 20    # $(if ($pythonMode) { '抓 import/语法错误' } else { '抓启动阶段报错' })"
}
if ($usingDemoDefaults) {
    Write-Host "  Get-Content '$logDir\service.log' -Wait -Tail 20   # demo 自己的结构化日志"
    Write-Host "  Get-Content '$(Join-Path $AppDir 'data\status.json')'"
}
Write-Host "  .\diagnose_service.ps1 -ServiceName $ServiceName    # 只读排错"
Write-Host "  & '$NssmExe' restart $ServiceName"
Write-Host "  .\uninstall_service.ps1 -ServiceName $ServiceName"
