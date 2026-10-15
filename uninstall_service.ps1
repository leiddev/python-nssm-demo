<#
.SYNOPSIS
    卸载由 install_service.ps1 注册的 Windows 服务。

.DESCRIPTION
    停止 → 删除服务。默认保留日志/数据目录，加 -PurgeFiles 才会一起删掉。
    需要管理员权限。

.EXAMPLE
    .\uninstall_service.ps1

.EXAMPLE
    .\uninstall_service.ps1 -ServiceName MyWorker -PurgeFiles
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ServiceName = 'PyDemoService',
    [string]$NssmExe = 'C:\Windows\nssm.exe',
    [string]$AppDir = $PSScriptRoot,

    # 同时删除 logs / data 目录
    [switch]$PurgeFiles
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------- #
# 调用原生 exe 的小助手。
# 为什么不能直接 `& nssm.exe ...`：本脚本设了 $ErrorActionPreference = 'Stop'，
# 而 Windows PowerShell 5.1 会把原生命令写到 **stderr** 的每一个字都变成
# 终止性错误（NativeCommandError），脚本会被直接中断。
# 所以调用期间临时降级为 Continue，退出码自己判断。
# （这个坑在 install_service.ps1 里踩到过：py -0p 的表头就是往 stderr 写的。
#   该文件里的 Invoke-Native 是完整版，还额外处理了内层双引号转义。）
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    # nssm 的非 ASCII 输出是 UTF-8 字节，而 PS 5.1 默认按 [Console]::OutputEncoding
    # （中文机器上 GBK/936）解码原生命令 stdout → 中文乱码。只在"解码"这层临时切换。
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
        $ErrorActionPreference = $savedEap
    }
    return [pscustomobject]@{ Output = @($output); ExitCode = $exitCode }
}

function Show-NativeOutput {
    param($Result)
    if ($Result.Output.Count) {
        Write-Host ("        " + ($Result.Output -join "`n        ")) -ForegroundColor DarkGray
    }
}

if (-not (Test-Path -LiteralPath $NssmExe)) {
    throw "找不到 nssm.exe：$NssmExe"
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Host "服务 $ServiceName 不存在，无需卸载。" -ForegroundColor Yellow
} else {
    # 1. 先停：NSSM 会向 Python 进程发 Ctrl+C，走的是脚本里的优雅退出逻辑
    if ($service.Status -ne 'Stopped') {
        Write-Host "停止服务 $ServiceName ……" -ForegroundColor Cyan
        Show-NativeOutput (Invoke-Native -FilePath $NssmExe -Arguments @('stop', $ServiceName))
        # 优雅退出最长可能要 AppStopMethodConsole 那么多时间，这里等足
        try {
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(40))
        } catch {
            Write-Warning "等待服务停止超时，继续删除。检查是否有残留进程：Get-Process python"
        }
    }

    # 2. 再删：结尾的 confirm 是必须的，
    #    否则 nssm 会弹出 GUI 确认框，在自动化脚本里会一直卡住
    Write-Host "删除服务 $ServiceName ……" -ForegroundColor Cyan
    Show-NativeOutput (Invoke-Native -FilePath $NssmExe -Arguments @('remove', $ServiceName, 'confirm'))
}

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    throw "服务 $ServiceName 仍然存在，删除失败。"
}
Write-Host "服务 $ServiceName 已删除。" -ForegroundColor Green

if ($PurgeFiles) {
    foreach ($name in @('logs', 'data')) {
        $path = Join-Path $AppDir $name
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
            Write-Host "已删除 $path" -ForegroundColor Yellow
        }
    }
}
