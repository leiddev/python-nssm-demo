# Python + NSSM 注册 Windows 服务（可复用模板）

把普通 Python 脚本用 [NSSM](https://nssm.cc/usage) 托管成 Windows 服务。
**不需要 pywin32 / win32serviceutil**，脚本本身就是一个普通的控制台程序。

> 也可以托管**任意普通 exe**（不是 Python 的）：`install_service.ps1 -Exe <路径>`，
> 见 [2.1 节](#21-如果目标不是-python而是一个普通-exe)。

本目录是已经**在本机实测跑通**的最小示例，可以直接拷走去改。

---

## 1. 目录结构

```
python-nssm-demo\
├─ service_demo.py            # 示例服务程序（唯一的业务代码）
├─ install_service.ps1        # 注册服务（需管理员）
├─ uninstall_service.ps1      # 卸载服务（需管理员）
├─ diagnose_service.ps1       # 只读排错（**不需要管理员**）：启动失败时挖出真因
├─ tests\
│  └─ test_graceful_stop.py   # 自测"优雅停止"（不需要管理员）
├─ logs\                      # 运行时生成
│  ├─ service.log             #   Python 自己的结构化日志（主要看这个）
│  ├─ stdout.log / stderr.log #   NSSM 兜底捕获，正常应为空
└─ data\                      # 运行时生成
   ├─ status.json             #   心跳状态，用来确认服务活着
   └─ inbox\ / done\          #   示例业务：投递 .txt 任务文件
```

---

## 2. 快速开始

```powershell
cd C:\Users\Leidi\source\repos\python-nssm-demo

# ① 先在前台跑一遍（不用管理员），确认脚本本身没问题
python -u service_demo.py --once
python -u service_demo.py --interval 2      # Ctrl+C 退出

# ② 自测优雅停止（不用管理员）
python tests\test_graceful_stop.py

# ③ 注册成服务（**管理员** PowerShell；会弹 UAC）
.\install_service.ps1

# ④ 查看
Get-Service PyDemoService
Get-Content .\logs\service.log -Wait -Tail 20
Get-Content .\data\status.json

# ⑤ 卸载
.\uninstall_service.ps1
```

安装脚本支持的常用参数：

```powershell
.\install_service.ps1 -ServiceName MyWorker `
                      -PythonExe 'C:\Python312\python.exe' `
                      -Interval 10 `
                      -StartType SERVICE_AUTO_START `
                      -Account LocalSystem `
                      -GrantPermissions `
                      -Force
```

### 2.1 如果目标不是 Python，而是一个普通 exe

加一个 `-Exe` 就切到「通用 EXE 模式」——NSSM 本来就是个通用 exe 包装器，
换成 exe 反而更简单，因为不用再管解释器：

```powershell
.\install_service.ps1 -ServiceName MyAgent `
    -Exe 'C:\tools\myagent\agent.exe' `
    -AppDir 'C:\tools\myagent' `
    -ScriptArguments @('--config', 'agent.ini', '--verbose') `
    -LogDir 'C:\tools\myagent\logs' -Force
```

| | Python 脚本模式（默认） | 通用 EXE 模式（给了 `-Exe`） |
|---|---|---|
| `Application` | 自动探测到的 `python.exe` | 你给的 exe（相对 `-AppDir` 或绝对路径） |
| `AppParameters` | `-u "<脚本>" <参数…>` | `<参数…>`，**不加 `-u`** |
| 环境变量 | 自动注入 `PYTHONUNBUFFERED` / `PYTHONIOENCODING` | 只注入 `-EnvironmentExtra` 给的 |
| `AppStopMethodConsole` | 20000 ms（等 Python 收尾） | 3000 ms（`-StopMethodConsole` 可改） |
| 默认显示名 | `Python 服务 (<服务名>)` | `服务 (<服务名>)` |
| 失败诊断里列的"常见原因" | import / 依赖包 / 解释器 | 缺 DLL、缺配置、session 0 无桌面 |

实测（`ping.exe` 当服务，两种模式都验过）：
- `nssm stop` **75 ms** 就到 Stopped —— NSSM 的 Ctrl+C 对普通控制台 exe 一样有效；
- `-Exe` 与 `-EntryScript` 同时给会直接报错；exe 路径不存在也会明确报错且不创建服务；
- 相对路径的 `-Exe`、含空格的目录、`-StopMethodConsole` 自定义值全部生效。

**三个必须知道的注意点：**

1. ⚠️ **`stdout.log` / `stderr.log` 可能一直是 0 字节，这不代表程序没跑。**
   NSSM 只能抓到「程序自己 flush 出来的」输出。实测 `ping.exe -t` 作为服务一直在跑，
   但 `stdout.log` 始终是 0 字节（被重定向后不 flush）。
   所以判断"活着没有"请用 `nssm status` / `Get-Service` / `netstat`，日志优先看程序自己的。
2. **如果那个 exe 本身就是 Windows 服务程序**（用 SCM API 写的，有 `ServiceMain` /
   `StartServiceCtrlDispatcher`），**不要套 NSSM**，直接 `sc.exe create` 注册它。
   NSSM 是给"不知道自己是个服务"的普通控制台程序用的。
3. **优雅停止依然是程序的责任**：`AppStopMethodConsole` 超时后，NSSM 会依次升级为
   关窗口 → 杀线程 → `TerminateProcess`（`AppKillProcessTree=1`）。
   想让它优雅收尾，程序得处理 Ctrl+C 或响应 `WM_CLOSE`。

---

## 3. 核心：Python 侧要满足的 5 条约定

NSSM 只是"把控制台程序拉起来 + 管生命周期"，所以**能不能优雅启停完全取决于 Python 脚本**。

| # | 约定 | 不这么做会怎样 |
|---|------|----------------|
| 1 | **常驻循环**，不主动退出 | 服务反复重启 |
| 2 | 注册 `SIGINT`(Ctrl+C) / `SIGBREAK`(Ctrl+Break) 处理函数，置标志位让主循环自己收尾 | 停止服务时被 `TerminateProcess` 强杀，数据/日志可能损坏 |
| 3 | **退出码有语义**：0 = 正常收工，非 0 = 崩溃 | 无法区分"正常结束"和"崩溃重启" |
| 4 | 日志**自己写文件**，不要只靠 `print` | stdout 重定向到文件时 Python 会缓冲，日志长时间不落盘 |
| 5 | 用 `python.exe` 启动，**绝不要用 `pythonw.exe`** | 没有控制台就收不到 Ctrl+C，只能被强杀 |

第 2 条的实现（`service_demo.py` 里的做法）：

```python
stop_event = threading.Event()          # 主循环和信号处理函数之间的桥梁

def install_stop_handlers():
    def _handle(signum, _frame):
        log.warning("收到停止信号 %s", signum)
        stop_event.set()                # 只做最轻量的操作
    for name in ("SIGINT", "SIGBREAK", "SIGTERM"):
        sig = getattr(signal, name, None)
        if sig is not None:
            signal.signal(sig, _handle)

# 主循环：用 Event.wait 代替 time.sleep，收到信号能立刻醒来
while not stop_event.is_set():
    do_work()
    stop_event.wait(interval)
# 出了循环再做收尾：关连接、flush、提交事务……
```

第 4 条的两种做法（本项目两种都用）：Python 内写 `logging.handlers.RotatingFileHandler`；
同时启动参数带 `-u`、环境变量带 `PYTHONUNBUFFERED=1`，让 NSSM 兜底捕获的 stdout 也是实时的。

---

## 4. NSSM 侧的关键配置

`install_service.ps1` 写入的完整参数（可用 `nssm dump PyDemoService` 复查）：

| 参数 | 值 | 说明 |
|------|-----|------|
| `Application` | `...\python.exe` | **必须绝对路径**；用虚拟环境就指向 `venv\Scripts\python.exe` |
| `AppParameters` | `-u <脚本> --interval 5 ...` | 全部参数用**绝对路径** |
| `AppDirectory` | 项目目录 | 不设的话工作目录会是 `C:\Windows\System32` |
| `Start` | `SERVICE_AUTO_START` | 开机自启；依赖网络/数据库可用 `SERVICE_DELAYED_AUTO_START` |
| `ObjectName` | `LocalSystem` | 默认本地系统账号，无需密码 |
| `AppStdout` / `AppStderr` | `logs\stdout.log` / `stderr.log` | 兜底抓解释器级错误（import 失败、语法错误） |
| `AppRotateFiles` / `AppRotateOnline` / `AppRotateBytes` | `1` / `1` / `10485760` | 日志滚动，服务运行时也能切分 |
| **`AppStopMethodConsole`** | `20000` | **最关键**：停止服务时先发 Ctrl+C，给 Python 20 秒优雅退出；超时才强杀 |
| `AppRestartDelay` | `5000` | 崩溃后等 5 秒再拉起，别疯狂重启 |
| `AppExit Default Restart` | | 兜底：非 0 退出 → 自动重启 |
| `AppExit 0 Exit` | | 覆盖：退出码 0 → 认为正常收工，不重启 |
| `AppEnvironmentExtra` | `PYTHONUNBUFFERED=1` / `PYTHONIOENCODING=utf-8` | 环境变量 |
| `AppKillProcessTree` | `1` | 停止时连子进程一起收（默认值） |

> `AppStopMethodConsole` 的超时**一定要大于** Python 收尾需要的最长时间，
> 否则会被强杀。反过来，Python 的收尾也别拖太久，超时被强杀就白做了。

---

## 5. 实测验证结果

本机（Windows，`C:\Windows\nssm.exe`，Python 3.9）跑通的结果：

```
注册         : Service "PyDemoService" installed successfully!
配置          : 全部 nssm set 成功，nssm dump 可复查
启动          : Service 状态 = Running；python.exe 子进程正常心跳
心跳          : data\status.json 每 5 秒更新，logs\service.log 正常滚动
停止          : nssm stop → 日志出现：
                [WARNING] 收到停止信号 SIGINT(2)，开始优雅退出
                [INFO   ] 进入收尾流程，最多等待 5.0s……
                [INFO   ] 服务已停止 | 共运行 9 轮 | 存活 46s | 退出码 0
               → 进程是"自己退出"的，不是被强杀；退出码 0
重启          : nssm start 成功，新 pid 生效
兜底日志      : logs\stdout.log / stderr.log 均为 0 字节（符合设计）
```

**结论：NSSM 的 Ctrl+C 能送达以 LocalSystem 运行、位于 session 0 的 Python 进程**，
所以"信号 + Event 标志位"这套优雅退出方案在服务场景下是成立的。

另外，**完整安装流程已在 Windows PowerShell 5.1 上端到端验证通过**
（`install_service.ps1 -Force`：停止旧服务 → 删除 → 注册 → 写参数 → 启动）：

| 检查项 | 结果 |
|--------|------|
| `nssm get <服务名> AppParameters` | `-u C:\...\service_demo.py --interval 5 --log-dir ... --data-dir ...` 完整单行，**未被拆坏** |
| `AppExit Default` / `AppExit 0` | `Restart` / `Exit` |
| `AppStopMethodConsole` | `20000` |
| CIM `DisplayName` | `Python 服务 (PyDemoService)` 中文正确（`-DisplayName` 可自定义） |
| 服务状态 | `Running` / `Auto`，Python 子进程正常心跳 |

> 注意：`nssm dump` / `nssm get` 的输出经 PowerShell 管道后，中文在 5.1 下会显示成乱码
> （见坑 2），**那只是显示问题**；要核实真实值请用
> `Get-CimInstance Win32_Service -Filter "Name='<服务名>'"`。

---

## 6. 踩坑清单

### 坑 1：`nssm install <服务名>` 不给可执行文件 → 弹出 GUI 并永久阻塞 ⚠️

```powershell
nssm install PyDemoService              # ❌ 弹出 "NSSM service installer" 窗口
                                        #    脚本永远卡在这一行，服务也没建成功
nssm install PyDemoService C:\py\python.exe -u C:\app\main.py   # ✅ 走命令行分支
```

脚本里必须把 **Application 一起传进去**，NSSM 才走命令行分支。
同理 `nssm remove <服务名>` 必须带 `confirm`，否则也弹 GUI 确认框：

```powershell
nssm remove MyService confirm           # ✅ 结尾的 confirm 不能省
```

### 坑 2：`nssm dump` 输出的中文看起来是乱码

`nssm dump` / `nssm get` 的内容被 PowerShell 捕获后，中文会显示成 `鐢?NSSM 鎵樼鐨?`。
**根因已实测确认**：

- nssm 的非 ASCII 输出**一律是 UTF-8 字节** ——
  `cmd /c "nssm dump 服务名 > out.bin"` 拿到的原始字节是 `E7 94 A8 ...`，按 UTF-8 解就是正确的 `用...`；
- 而 **Windows PowerShell 5.1 解码原生命令 stdout 用的是 `[Console]::OutputEncoding`**，
  中文机器上默认是 **GBK/936** → 同一段字节被按 GBK 解，全成乱码。

同一个 `nssm status 不存在的服务`，实测对照：

| 解码方式 | 结果 |
|---------|------|
| CP936（PS 5.1 默认） | `OpenService(): 鎸囧畾鐨勬湇鍔℃湭瀹夎銆?` |
| UTF-8 | `OpenService(): 指定的服务未安装。` ✅ |

**注册表里存的值从头到尾都是对的**，坏的只是显示层：

```powershell
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\PyDemoService').DisplayName
# → Python 服务 (PyDemoService)      ← 正常
Get-CimInstance Win32_Service -Filter "Name='PyDemoService'" | Select DisplayName, Description
```

**本项目三个脚本已自动处理**：`Invoke-Native` 会在调用 nssm 时把 `[Console]::OutputEncoding`
临时切成 UTF-8，调用完还原。实测切前切后 **nssm 写出的字节逐字节相同**（只是解码层变了），
也不影响脚本自己 `Write-Host` 的中文（PS 走 `WriteConsoleW`）；PS 7 本来就是 UTF-8，此处是空操作。
自己写代码读 `nssm dump`/`nssm get` 的中文时，照做即可。

> 反方向的环境坑：如果控制台代码页是 **65001** 而不是 936，实测 nssm 会把非 ASCII 直接输出成
> `?`（信息在源头就丢了，任何解码都救不回来）。遇到这种环境请直接读注册表，别读 nssm 的输出。

服务名建议用纯 ASCII，中文只放 DisplayName。

**同一个坑的另一面**：`nssm dump` 会把 `AppExit` 打印成**两行一样的** `AppExit Default Restart`，
让人误以为 `nssm set <名> AppExit 0 Exit` 没生效。其实生效了 ——
`dump` 的显示有 bug，**注册表和 `nssm get` 才是真的**：

```powershell
nssm get MyService AppExit 0        # → Exit      （干净退出时停服务，不重启）
nssm get MyService AppExit Default  # → Restart   （其他退出码：重启）
```

**通用原则**：`nssm dump` 只用来快速浏览，**核对配置一律用 `nssm get` 或注册表**。

### 坑 3：PowerShell 里 `($array)[0]` 单元素退化成字符串

`($oneItemArray)[0]` 没问题，但**单个字符串**取 `[0]` 会得到第一个**字符**：

```powershell
$exe = Get-Something | Select-Object -First 1
$exe[0]          # ❌ 得到 "C"（路径的第一个字符！）
@($exe)[0]       # ✅
```

### 坑 4：Windows PowerShell 5.1 读无 BOM 的 .ps1 会中文乱码 → 语法报错 ⚠️

**症状**：脚本里的中文变成 `鏈嶅姟`、`宸插垹闄ゃ€?`，并报

```
表达式或语句中包含意外的标记“}”。
语句块或类型定义中缺少右“}”。
```

看起来像括号写错了，其实**根本不是语法问题**，是编码问题。

**原因**：`powershell.exe`（5.1）读 `.ps1` 时，**没有 BOM 就按系统 ANSI 代码页（中文系统是 GBK）解码**。
UTF-8 里 `。` 是 `E3 80 82`，按 GBK 解成 `E3 80`→`銆`，剩下的 `82` 会和**后面的引号 `"`(0x22)**
拼成一个合法的 GBK 双字节字符，于是**收尾引号被吃掉**，字符串没闭合，后面的 `}` 全部错位。

对比：`pwsh`（PowerShell 7）默认按 UTF-8 读，所以同一个文件在 PS7 下完全正常，
**PS5.1 下才炸** —— 这个不对称非常容易让人误判。

**修复**：把 `.ps1` 存成 **UTF-8 with BOM**（本项目的两个脚本已经是）。

```powershell
# 给已有脚本补 BOM
$enc = New-Object System.Text.UTF8Encoding($true)   # $true = 写 BOM
foreach ($f in 'install_service.ps1','uninstall_service.ps1') {
    $p = Resolve-Path $f
    $text = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($p, $text, $enc)
}
# 确认前 3 字节是 EF BB BF
[System.IO.File]::ReadAllBytes($p)[0..2] -join ' '
```

**验证方式**（一定要用 5.1 自己验证，别用 PS7）：

```powershell
# 语法检查
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  '$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\uninstall_service.ps1),[ref]$null,[ref]$e);if($e){$e|%{$_.Message}}else{"PARSE OK"}'

# 中文解码检查
powershell.exe -NoProfile -Command "Select-String -Path .\uninstall_service.ps1 -Pattern '已删除' -Encoding UTF8"
```

**另一条路**：`.ps1` 里干脆只写 ASCII（提示信息用英文），就完全绕开这类问题。
两者选一个，**不要混**：带中文就必须有 BOM。

> 顺便：`service_demo.py` 不受影响 —— Python 3 默认按 UTF-8 读源码，不需要 BOM。

### 坑 5：PowerShell 5.1 传参给 nssm 会把「带引号的参数字符串」拆坏 ⚠️

**症状**：注册出来的服务能启动，但 Python 收到一堆乱七八糟的参数；
或者 `nssm get <服务名> AppParameters` 看到的字符串不完整。
**只在应用目录/日志目录路径含空格时触发**（比如 `C:\Program Files\...`、`C:\my app\`）。

**根因**：PS 5.1 用"传统"方式把参数交给原生 exe —— *只给含空格的参数套一层引号，
完全不处理参数内部的双引号*。于是 `AppParameters` 这个**本身含双引号**的字符串被拆散。

实测（让 exe 把自己的 argv 打出来）：

```
输入: -u "C:\my app\service_demo.py" --interval 5 --log-dir "C:\my app\logs"

PS 5.1 原样传   → argc = 3   ❌ ['-u C:\my', 'app\service_demo.py --interval 5 --log-dir C:\my', 'app\logs']
PS 5.1 手工转义 → argc = 1   ✅ ['-u "C:\my app\service_demo.py" --interval 5 --log-dir "C:\my app\logs"']
PS 7   原样传   → argc = 1   ✅ 同上
```

**处理办法**（`install_service.ps1` 已内置，集中做在 `Invoke-Nssm` 里）：
探测 `$PSNativeCommandArgumentPassing`，只有传统模式下才把内层 `"` 转义成 `\"`：

```powershell
$nativeArgMode = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly `
                               -ErrorAction SilentlyContinue
$script:LegacyArgPassing = ($null -eq $nativeArgMode) -or ($nativeArgMode -eq 'Legacy')

# 调用原生 exe 前
$nativeArgs = @(foreach ($arg in $Arguments) {
    if ($script:LegacyArgPassing) { $arg -replace '"', '\"' } else { $arg }
})
& $NssmExe @nativeArgs
```

`\"` 无论 PowerShell 有没有给参数套外层引号，`CommandLineToArgvW` 都会还原成一个 `"`，
所以这个转义对"不需要转义"的情况也是安全的。

**验证方式**（不需要管理员，也不用真装服务）：用 AST 把脚本里真实的 `Invoke-Nssm`
抽出来，让 `python.exe` 当桩替代 nssm，打印子进程看到的 argv：

```powershell
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$fn  = $ast.Find({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Nssm'
}, $false)
$NssmExe = 'C:\...\python.exe'     # 桩
Invoke-Expression $fn.Extent.Text
Invoke-Nssm @('C:\argv_dump.py', '-u "C:\my app\service_demo.py" --interval 5')
```

**顺带**：`Invoke-Nssm` 里的 splat 用 `@(...)` 包成数组，避免标量 splat 的行为差异。

### 坑 6：`$ErrorActionPreference='Stop'` + 原生命令写 stderr → 脚本无端中断 ⚠️

**症状**：脚本跑到某一步突然中断，报 `NativeCommandError`，内容却是某个程序的**正常输出**。
本机实测（PS 5.1）：

```
py.exe : Installed Pythons found by C:\Windows\py.exe Launcher for Windows *
所在位置 ...\install_service.ps1:131 字符: 28
+         foreach ($line in (& $pyLauncher.Source -0p 2>$null)) {
+                            ~~~~~~~~~~~~~~~~~~~~~~~~
    + FullyQualifiedErrorId : NativeCommandError
```

看着像 `py -0p` 出错，其实它**完全成功**，只是往 **stderr** 写了那行表头而已。

**根因**：Windows PowerShell 5.1 会把原生命令写到 stderr 的**每一个字**
包装成 `NativeCommandError`；当 `$ErrorActionPreference = 'Stop'` 时它是**终止性**错误，
脚本立刻中断 —— **而且 `2>$null` 也救不了**（重定向发生在错误记录产生之后）。
PS 7 下 stderr 不会抛错，所以这个坑同样**只在 5.1 上现形**。

顺带澄清：`py -0p` 的输出是**混流**的 —— 表头 `Installed Pythons found by ...` 走 **stderr**，
解释器路径走 **stdout**。所以用 `Select-String` 管道抓它很容易抓空。

**处理办法**：调用原生 exe 时把 EAP 临时降级，退出码自己判（本来就要判）。
关键是**收口到一个统一入口**，别让脚本里到处散落 `& exe`：

```powershell
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments = @())
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'      # ← 关键一行

    # nssm 的非 ASCII 输出是 UTF-8，而 5.1 按 [Console]::OutputEncoding（中文机上是 GBK）
    # 解码原生命令 stdout → 乱码。只在"解码"这层临时切成 UTF-8，用完还原。
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
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        if ($changedOutEnc) { try { [Console]::OutputEncoding = $savedOutEnc } catch { } }
        $ErrorActionPreference = $savedEap   # 用完还给调用方
    }
    return [pscustomobject]@{ Output = @($output); ExitCode = $exitCode }
}
```

**验证方式**：不用真跑脚本（它有 `#Requires -RunAsAdministrator`），
把脚本里**真实的函数**用 AST 抽出来，在 5.1 + `EAP='Stop'` 下直接调用：

```powershell
$ErrorActionPreference = 'Stop'                  # 复现报错环境
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$fns = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst }, $true)
foreach ($name in 'Invoke-Native', 'Resolve-PythonInterpreter') {
    Invoke-Expression ($fns | Where-Object Name -eq $name | Select-Object -First 1).Extent.Text
}
Resolve-PythonInterpreter -Explicit $null        # 应返回路径而不是抛错
```

**附带发现**：`py -0p` 对 Microsoft Store 版本只输出**裸文件名**（`python3.12.exe`），
不是完整路径。所以"排除 Store 版解释器"靠"是否带盘符"判断就够了。

### 坑 7：`nssm start` 报 `Unexpected status SERVICE_PAUSED` —— 其实是程序启动即崩溃 ⚠️

**症状**：

```
nssm start MyService 执行失败（exit 1）：
MyService: Unexpected status SERVICE_PAUSED in response to START control.
```

看着像 NSSM 或服务配置的问题，**其实是 Python 程序的事**。

**真相**（本机把 4 种情况都复现过）：

| 场景 | `nssm start` 结果 | 服务最终状态 | 真正的原因在哪 |
|------|------------------|--------------|----------------|
| 入口脚本启动即崩溃 `sys.exit(1)` | `SERVICE_PAUSED`，exit 1 | **Paused** | `stderr.log` 里是程序自己的 traceback |
| 入口脚本文件不存在 | `SERVICE_PAUSED`，exit 1 | **Paused** | `stderr.log`：`can't open file 'xxx'` |
| 脚本立刻正常退出 `sys.exit(0)` | `SERVICE_STOPPED`，exit 1 | Stopped | 无报错（`AppExit 0 Exit` 生效，NSSM 主动停了服务） |
| 健康脚本 | 成功 | Running | — |

结论：**`SERVICE_PAUSED` = 服务注册是成功的、程序也被拉起来了，但它立刻以非 0 退出码崩溃**，
NSSM 为了不无限重启触发**节流(throttle)**并把服务置为 Paused。
真正的报错**不在 NSSM 里，而在程序的 stderr 里**。

**Paused 状态怎么救（均实测）**：

| 操作 | 结果 |
|------|------|
| `nssm start` | 失败，exit 1，`服务的实例已在运行中。` |
| `nssm continue` | 失败，exit 1，`Unexpected status SERVICE_PAUSED in response to CONTINUE control.` |
| **`nssm stop`** | 成功，exit 0，立刻到 Stopped |
| `nssm remove <名> confirm` | 成功，干净删除（需先 stop） |

> `stop` / `start` / `continue` 都需要**管理员**权限。用普通权限跑会得到
> `Can't open service! OpenService(): 拒绝访问。` —— 这不是服务不存在，
> 别被它带偏。（`nssm get` / `nssm status` 只读，普通权限就能用。）

> ⚠️ **`nssm status` 的退出码不可信**：NSSM 2.24 实测它**永远 exit 0**，
> 状态只体现在它打印的那行文本里（`SERVICE_PAUSED` / `SERVICE_RUNNING` / …）。
> 只有服务**不存在**时才非 0（exit 3 + `Can't open service!`）。
> 所以判断状态**必须解析文本**，网上流传的 `0=RUNNING 1=PAUSED 2=…` 映射是错的。

> 不要用 `taskkill` 或"删除服务"去绕过 Paused：那种状态下服务进程还活着，
> `DeleteService` 只会把它标记成"待删除"，服务名被占住直到进程退出。
> 正解永远是先 `nssm stop`。

**标准排错四步**：

```powershell
# 1) 先停下（Paused 下 start / continue 都无效）
nssm stop <服务名>

# 2) 先问 NSSM 日志到底写在哪 —— logs 是相对 AppDirectory 的，别靠猜
nssm get <服务名> AppDirectory
nssm get <服务名> AppStdout
nssm get <服务名> AppStderr

# 3) 看真正的报错（traceback 在这里）
Get-Content <上一步 AppStderr 的值> -Tail 50
Get-Content <上一步 AppStdout 的值> -Tail 50

# 4) 看 NSSM 到底执行了什么，然后原样在前台跑一遍
nssm get <服务名> Application
nssm get <服务名> AppParameters
```

**最常见的三个原因**：

1. 入口脚本路径 / 文件名写错 → `can't open file 'xxx'`
2. **缺依赖包**：服务以 LocalSystem 运行，**看不到**你用 `pip install --user`
   装在 `%APPDATA%\Python\...` 下的包 → `ModuleNotFoundError`。
   典型例子：`telnetlib` 在 **Python 3.13 中已被移除**（3.12 及以前才有）。
   解决：把依赖装到系统级或项目 venv，并让 `Application` 指向那个解释器。
3. 脚本一启动就抛异常（import 报错、配置文件读不到、端口被占用……）

**本项目已内置自动排错**：`nssm start` 失败时，安装脚本会**自动**打印
状态快照、NSSM 实际的 `Application`/`AppParameters`/`AppDirectory`、
`stderr.log` / `stdout.log` / `service.log` 的尾部、以及常见原因清单和一键复现命令，
不再只甩一句 `SERVICE_PAUSED` 让人猜。

**已经注册好的服务，用只读诊断脚本**（不需要管理员，不会改配置）：

```powershell
.\diagnose_service.ps1 -ServiceName Btxc-sensor-monitor-telnet
```

它做的事情比手工四步更全：状态快照 + 完整 `nssm get` + 路径自检
（解释器/工作目录/入口脚本是否存在）+ `telnetlib` 在 3.13 已删除的专项检查
+ 日志尾部并对关键词自动下结论（`ModuleNotFoundError` / `SyntaxError` /
`PermissionError` / 端口占用…）+ 一键复现命令。

> 为什么还要单独一个诊断脚本，而不是直接 `install_service.ps1 -Force` 重装一遍？
> 一是诊断本来就不该改配置（只读最安全，生产机上也能随手跑）；
> 二是重装会把"NSSM 里实际存着的配置"换成"你这次命令行写的配置"，
> 万一漏了某个参数，就把现场破坏了。**先诊断、后修，顺序不要反。**
> （当然，真要重装时 `install_service.ps1` 现在已经支持 `-EntryScript` /
> `-ScriptArguments` / `-AppParameters` 完全自定义，见第 7 节。）

> 读日志的小坑：服务**正在运行**时 NSSM 一直占着 `AppStdout`/`AppStderr` 的句柄，
> 此时 `[System.IO.File]::ReadAllBytes()` 会抛
> `IOException: ... being used by another process`。
> `diagnose_service.ps1` 内部用 `FileShare.ReadWrite` 打开，所以运行中也读得到；
> 你自己写脚本时注意这一点（`Get-Content -Tail` 也是共享读，可以用）。

#### 同一个报错的"另一半"：`SERVICE_START_PENDING` 是**误报**，不是故障 ⚠️

```
nssm start MyService 执行失败（exit 1）：
MyService: Unexpected status SERVICE_START_PENDING in response to START control.
```

**文字格式和 `SERVICE_PAUSED` 一模一样，含义却相反**：服务正在启动、还没起完，`nssm start` 没等够就返回了。
实测（x86 Debug 版 GUI 程序，约 5 秒才进 RUNNING）：

| 检查 | 结果 |
|------|------|
| `nssm start` 退出码 | 1（报了上面那句） |
| 紧接着 `nssm status` | **`SERVICE_RUNNING`** |
| 进程 | 一直在跑（创建时间就是 START 的时刻） |
| 事件日志 `ProviderName=nssm` | Id 1008「Started … for service …」，**没有任何重启/崩溃事件** |

判定方法：**过几秒再查一次状态**，顺便看事件日志有没有 1014 系列的重启记录。

```powershell
& 'C:\Windows\nssm.exe' status MyService      # 多半已经是 SERVICE_RUNNING
Get-WinEvent -LogName Application -MaxEvents 50 | Where-Object { $_.ProviderName -eq 'nssm' }
```

> **写自动化脚本时最容易踩的一点**：不能只看 `nssm start` 的退出码。
> `install_service.ps1` 早期版本因此把好服务判成失败，现在改为**自己轮询状态**（最多 30 秒，
> 遇到 RUNNING/PAUSED/STOPPED 就停）。但豁免条件必须写严：
> **只有报的是 `START_PENDING` 才允许把"轮询到 RUNNING"当作成功**。
> 因为报 `SERVICE_PAUSED`（真崩溃）时，服务状态会在 PAUSED/RUNNING 之间来回抖，
> 轮询很可能刚好抓到 RUNNING —— 那就把坏服务判成好的了。

> 为什么慢？**与位数、与是不是 GUI 都无关**：实测 32 位的 `SysWOW64\ping.exe`、
> 64 位 GUI 的 `notepad.exe`、`ping.exe -t` 全都是 `nssm start` exit 0、0 秒进 RUNNING。
> 所以是该程序**自身初始化慢**（Debug 版 + 大量 DLL + 杀软扫描之类），重跑也是同样表现。

### 坑 9：不想要日志文件？把输出设成 `NUL`，**千万别 reset** ⚠️

实测（提权 PS 5.1，让程序往 stdout 狂写约 84 MB，末尾写一个 marker 文件）：

| `AppStdout` / `AppStderr` | 结果 |
|--------------------------|------|
| **不设置**（`nssm reset MyService AppStdout`） | ❌ **程序永久卡死**：NSSM 给它的 stdout 是个**没人读的管道**，写满缓冲（4~64KB）就阻塞，进程一直挂着不退出。实测 70 秒还没跑完（同样命令在另外两种配置下 30 秒就跑完） |
| **`NUL`** | ✅ 正常跑完并退出，不产生任何文件 |
| 普通文件路径 | ✅ 正常写入 |

所以"不要日志"的正解是**显式设成 NUL**：

```powershell
& 'C:\Windows\nssm.exe' set MyService AppStdout NUL
& 'C:\Windows\nssm.exe' set MyService AppStderr NUL
# 没有真实文件时滚动参数没意义，可顺手清掉（不必须）
& 'C:\Windows\nssm.exe' reset MyService AppRotateFiles
& 'C:\Windows\nssm.exe' reset MyService AppRotateOnline
& 'C:\Windows\nssm.exe' reset MyService AppRotateBytes
```

安装脚本一步到位（同时跳过创建 `logs\` 目录、不设 AppRotate*）：

```powershell
.\install_service.ps1 -ServiceName MyService -Exe ..\app.exe -DiscardOutput
```

> "不设 AppStdout 就没人管它的输出"这个直觉是**错的**，这正是本坑的价值所在。
> 如果程序一个字都不往 stdout/stderr 写（安静的 GUI 程序），reset 确实也不会出事；
> 但只要 Debug 输出/警告/崩溃回溯攒够 64KB 就会**静默卡死**，且现场看不出任何异常。
> 用 `NUL` 就没有这个问题。

### 坑 8：其他常见问题

| 现象 | 原因 / 处理 |
|------|-------------|
| `nssm start` 报 `SERVICE_PAUSED` | 程序启动即崩溃被 NSSM 节流，见坑 7；先 `nssm stop` |
| `nssm start` 报"服务的实例已在运行中" | 服务处于 Paused/Running，先 `nssm stop` |
| `nssm continue` 报 `SERVICE_PAUSED` | 同上，Paused 下 continue 也没用，只能 `stop` |
| `nssm stop/start` 报 `Can't open service!` | 不是服务不存在，是**权限不足**（普通权限跑 SCM 操作），用管理员重跑；只读的 `status`/`get` 不受影响 |
| 脚本里 `nssm status` 判断不出状态 | NSSM 2.24 的 `status` **永远 exit 0**，只能解析输出文本 `SERVICE_XXX` |
| `nssm dump` 里看不出 `AppExit 0 Exit` | dump 把 `AppExit` 打印成两行 `AppExit Default Restart`（显示 bug），用 `nssm get <名> AppExit 0` 核对 |
| `nssm set` 报**一大篇 usage** + `exit 1` | 传进去的值是**空字符串**！空参数在拼原生命令行时被整个丢掉，nssm 收到的就少一个值（`set <名> <参数>`），判定参数不全 → 打印 usage。安装脚本已自动跳过空值（典型触发：EXE 模式没给任何参数 → `AppParameters` 为空） |
| `nssm set` 输出 `Reset parameter "xxx" to its default.` | **不是失败**：nssm 发现你设的值恰好**等于默认值**时就这么说（如 `ObjectName LocalSystem`、`AppKillProcessTree 1`、`AppExit Default Restart`），值是对的，用 `nssm get`/注册表核对 |
| `nssm start` 报 `Unexpected status SERVICE_START_PENDING in response to START control.` | **多半是误报**：服务还在启动、nssm 没等够就返回了。几秒后 `nssm status` 往往已经是 `SERVICE_RUNNING`（实测 XEC.exe 约 5 秒）。它和 `SERVICE_PAUSED`（真崩溃）的文字格式一模一样，只能靠 `nssm status` 复检 / 事件日志 Id 1008 区分。安装脚本已改为轮询状态，不再据此误报 |
| `nssm start` 报 `Unexpected status SERVICE_PAUSED in response to START control.` | **这是真的起不来**：程序被拉起后立刻以非 0 退出码崩溃，NSSM 节流把它置为 Paused。真正原因在 `AppStderr` 里 |
| `nssm dump` 里 `AppEnvironmentExtra` 显示成 `:K=V` / `+K=V` | dump 的显示语法：`:` 表示覆盖、`+` 表示追加。不是坏值 |
| `nssm dump` 把 `"` `&` `>` `\` 显示成 `^"` `^&` `^>` `^\` | dump 为了输出「可直接粘进 cmd 的命令行」而做的**转义显示**。实测 `nssm get` 和注册表里都是干净的原值，别被吓到 |
| `nssm get` 报 `Parameter "xxx" is only valid for services managed by NSSM!` | 这个服务不是 NSSM 装的（或用 `sc.exe create` 建的） |
| 脚本中途报 `NativeCommandError` 中断 | EAP=Stop + 原生命令写 stderr，见坑 6 |
| 服务启动后立即停止 | 看 `logs\stdout.log` / `stderr.log`，通常是 import 失败或解释器路径写错 |
| 日志一直不落盘 | 忘了 `-u` 或 `PYTHONUNBUFFERED=1` |
| 停止服务要等很久 / 总是被强杀 | 没注册信号处理；或 `AppStopMethodConsole` 小于收尾耗时 |
| 相对路径读不到文件 | 没设 `AppDirectory` |
| LocalSystem 读写不了应用目录 | 应用放 `C:\ProgramData\xxx` 或 `C:\Services\xxx`，或用 `-GrantPermissions` 授权 |
| 依赖用户态环境（映射网络驱动器、桌面、%USERPROFILE% 下的配置） | 服务跑在 session 0，没有桌面，也没有该用户的环境变量 |
| 崩溃后疯狂重启刷日志 | 加大 `AppRestartDelay`，并让脚本自身记录致命错误后**退出码非 0** 交给 NSSM 处理 |

---

## 7. 迁移到其他项目的清单

1. **拷 4 个文件**：`install_service.ps1`、`uninstall_service.ps1`、`diagnose_service.ps1`、
   `tests\test_graceful_stop.py`。
2. **不用改脚本**：项目相关的东西全部由参数决定，命令行里写就行。
   `install_service.ps1` 的参数表：

   | 参数 | 默认值 | 说明 |
   |------|--------|------|
   | `-ServiceName` | `PyDemoService` | 服务名（纯 ASCII） |
   | `-Exe` | 空 | **注册普通 exe**（非 Python）：相对 `-AppDir` 或绝对路径；给了它就切到「通用 EXE 模式」，与 `-EntryScript` 互斥 |
   | `-EntryScript` | `service_demo.py` | **入口脚本**，相对 `-AppDir` 或绝对路径（仅 Python 模式） |
   | `-ScriptArguments` | 空 | 传给程序/脚本的参数数组，逐个元素传，不用自己拼引号（别名 `-ProgramArguments`） |
   | `-AppParameters` | 空 | **直接给 AppParameters 原文**，优先级最高，一个字符都不改 |
   | `-AppDir` | `$PSScriptRoot` | 工作目录（`AppDirectory`） |
   | `-LogDir` | `logs`（相对 `-AppDir`） | stdout/stderr 落盘目录，可绝对路径 |
   | `-DiscardOutput` | 关 | **不要日志文件**：把 stdout/stderr 丢到 `NUL`（别名 `-NoLog`）。⚠️ 实现是设成 `NUL` 而不是不设置 —— 见坑 9 |
   | `-DisplayName` | `Python 服务 (<服务名>)` / `服务 (<服务名>)` | 服务管理器里显示的名字 |
   | `-Description` | 自动生成 | 服务描述 |
   | `-EnvironmentExtra` | 空 | 额外环境变量，如 `@('MODE=service')`（Python 模式还会自动加 `PYTHONUNBUFFERED` 等） |
   | `-PythonExe` | 自动探测 | `python.exe` 全路径；用虚拟环境就指到 `venv\Scripts\python.exe`（仅 Python 模式） |
   | `-StopMethodConsole` | `20000` / `3000` | 发 Ctrl+C 后等多久（毫秒）再升级强杀；Python / EXE 模式默认值不同 |
   | `-Interval` | `5` | **仅在 Python 模式 + 用默认参数时生效**，会变成 `--interval` + `DEMO_INTERVAL` |
   | `-NssmExe` | `C:\Windows\nssm.exe` | nssm 位置 |
   | `-StartType` | `SERVICE_AUTO_START` | 也可 `SERVICE_DELAYED_AUTO_START` / `SERVICE_DEMAND_START` |
   | `-Account` | `LocalSystem` | 改别的账号要自己给密码权限 |
   | `-GrantPermissions` | 关 | 给服务账号授应用目录权限 |
   | `-Force` | 关 | 覆盖同名旧服务 |
   | `-NoStart` | 关 | 只注册，不启动 |

   `AppParameters` 的三种来源（从上往下优先级递减）：
   1. `-AppParameters` —— 原样使用，**最自由**；
   2. `-ScriptArguments` —— Python 模式自动拼成 `-u "<入口脚本>" <你的参数…>`，
      EXE 模式就是 `<你的参数…>`（**不加 `-u`**，那是 Python 解释器的开关）；
   3. 都不给 —— Python 模式用 demo 默认参数
      `-u "<入口脚本>" --interval N --log-dir <logs> --data-dir <data>`
      （只有这种情况才建 `data\` 目录、才写 `DEMO_INTERVAL`）；EXE 模式 = 无参数。

   ```powershell
   # 例 1：把本项目换成"传感器监控"项目，一个字符都不用改脚本
   .\install_service.ps1 -ServiceName SensorMonitor `
       -AppDir 'C:\Project\sensor-monitor-telnet' `
       -EntryScript 'main.py' `
       -ScriptArguments @('--config', 'config.yaml', '--verbose') `
       -LogDir 'C:\Project\sensor-monitor-telnet\logs' `
       -DisplayName '传感器监控 (SensorMonitor)' -Force

   # 例 2：换成普通 exe（详见 2.1 节）
   .\install_service.ps1 -ServiceName MyAgent -Exe 'C:\tools\agent.exe' `
       -ScriptArguments @('--config', 'agent.ini') -Force
   ```

   > ⚠️ 唯一**不要动**的是 `Invoke-Native`：它负责三个 5.1 专属的坑
   > （参数内层引号转义、EAP=Stop 时 stderr 中断、原生命令 UTF-8 输出被按 GBK 解码成乱码），
   > 并且是脚本里**唯一**允许直接调用原生 exe 的地方。自己要加别的 exe 调用
   > （如 robocopy、git），也一律走 `Invoke-Native`。
3. **按第 3 节的 5 条约定改造你的 Python 脚本**：
   - 套上 `while not stop_event.is_set()` 循环 + 信号处理 + `Event.wait`；
   - 把收尾逻辑放到循环之后；
   - 主函数 `return 0`（正常）/ `return 1`（异常），`sys.exit(main())`；
   - 日志改写成 `RotatingFileHandler` 写文件，不要只 print。
4. **先用 `python -u xxx.py` 前台跑通**，再跑 `tests\test_graceful_stop.py`。
5. **管理员 PowerShell 执行 `.\install_service.ps1`**，然后 `nssm dump <服务名>` 复查配置。
   启动失败时安装脚本会自动打印诊断；也可以随时单独跑
   `.\diagnose_service.ps1 -ServiceName <服务名>`（只读，不需管理员）。
6. **验收**：`Get-Service` 为 Running → 看 `logs\service.log` 有日志 → `nssm stop` 后
   日志里必须有"收到停止信号 + 收尾完成 + 退出码 0"（说明是优雅退出而非强杀）。

> **小技巧**：`nssm dump <服务名>` 的输出本身就是一份可重放的重装脚本。
> 把它存成 `install_<服务名>.cmd` 提交到仓库，就是服务的"配置即代码"，比读文档可靠。
>
> **进阶**：服务用 `ObjectName` 换成普通域账号时需要密码，
> `nssm set <服务名> ObjectName <账号> <密码>`，且该账号需要"作为服务登录"权限。
>
> **抄走时注意**：`.ps1` 拷到新项目后，确认仍是 **UTF-8 with BOM**（见坑 4）。
> VS Code 右下角选 "UTF-8 with BOM"；很多编辑器"另存为 UTF-8"会**悄悄去掉 BOM**，
> 于是脚本只在 PS 5.1 上炸。可用上面那行 `ReadAllBytes(...)[0..2]` 自查。

---

## 8. 常用命令速查

```powershell
# 状态
Get-Service PyDemoService                                 # PowerShell 原生
nssm status PyDemoService                                 # 退出码 0=RUNNING 4=STOPPED

# 启停
nssm start PyDemoService
nssm stop PyDemoService
nssm restart PyDemoService

# 状态卡在 Paused（程序启动即崩溃被节流，见坑 7）
#   start / continue 都无效，只有 stop 管用
nssm stop PyDemoService

# 改配置（改完要 restart 才生效，部分参数需要）
nssm set PyDemoService AppParameters "-u C:\app\main.py --interval 10"
nssm set PyDemoService AppStopMethodConsole 30000
nssm get PyDemoService AppParameters
nssm get PyDemoService AppExit 0
nssm dump PyDemoService                                   # 导出全部配置

# 图形界面改配置
nssm edit PyDemoService

# 排障
Get-Content .\logs\service.log -Tail 50 -Wait
Get-Content .\logs\stdout.log, .\logs\stderr.log
Get-Process python | Select Id, StartTime
Get-WinEvent -LogName System -MaxEvents 50 |
    Where-Object { $_.ProviderName -like '*Service Control Manager*' } | Format-List
```
