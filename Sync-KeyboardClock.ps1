#Requires -Version 5.1
<#
    Sync-KeyboardClock.ps1
    Worker. Run by the scheduled task through run-hidden.vbs.

    Reads config.json (written by Install.ps1); if absent, auto-detects.
    Skips silently when the keyboard is not connected or the app is already open.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }

$logPath = Join-Path $PSScriptRoot 'sync.log'

$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch { $cfg = $null }
}

$vid = if ($cfg -and $cfg.vid) { [string]$cfg.vid } else { '258A' }
$exe = if ($cfg -and $cfg.exePath) { [string]$cfg.exePath } else { '' }

if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
    $app = Find-VendorApp -Vid $vid
    if (-not $app) {
        Write-CcLog $logPath "SKIP   vendor app not found (install the OEM driver first, VID_$vid)"
        exit 0
    }
    $exe = $app.Exe
}

if (-not (Test-VendorConnected -Vid $vid)) {
    Write-CcLog $logPath "SKIP   no VID_$vid device connected (dongle unplugged or keyboard asleep)"
    exit 0
}

$procName = [System.IO.Path]::GetFileNameWithoutExtension($exe)
if (@(Get-Process -Name $procName -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-CcLog $logPath "SKIP   $procName already running"
    exit 0
}

$result = Invoke-VendorSync -Exe $exe -WorkDir ([System.IO.Path]::GetDirectoryName($exe))
Write-CcLog $logPath $result

if ($result -like 'OK*') { exit 0 }
if ($result -like 'WARN*') { exit 5 }
exit 6
