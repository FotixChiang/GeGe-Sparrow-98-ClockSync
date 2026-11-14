#Requires -Version 5.1
<#
    Install.ps1
    Detects the board + OEM app, writes config.json, registers one daily task,
    then optionally does a test run.

    Usage:
      Install.ps1                 detect, register daily 04:00, test once
      Install.ps1 -At 03:30       different time
      Install.ps1 -DetectOnly     only print what was found, change nothing
      Install.ps1 -NoTest         do not run immediately
      Install.ps1 -Uninstall      remove task + config
#>
[CmdletBinding()]
param(
    [string]$At = '04:00',
    [string]$Vid = '258A',
    [string]$ExePath = '',
    [switch]$DetectOnly,
    [switch]$NoTest,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$taskName  = 'Keyboard Screen Clock Sync'
$root      = $PSScriptRoot
$vbs       = Join-Path $root 'run-hidden.vbs'
$configPath = Join-Path $root 'config.json'
$logPath   = Join-Path $root 'sync.log'

if ($Uninstall) {
    schtasks.exe /Delete /TN "$taskName" /F 2>&1 | Out-Null
    Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
    Write-Host "Removed task '$taskName' and config.json. Log kept at $logPath"
    return
}

Write-Host ''
Write-Host '=== Keyboard Screen Clock Sync / setup ===' -ForegroundColor Cyan
Write-Host ''

# ---- 1. device ---------------------------------------------------------------
$devices = @(Get-VendorDevice -Vid $Vid)
if ($devices.Count -gt 0) {
    $pids = ($devices | Select-Object -ExpandProperty Pid -Unique) -join ', '
    $prod = ($devices | Select-Object -ExpandProperty Product -Unique | Where-Object { $_ }) -join ', '
    Write-Host ("[1/3] device : VID_{0}  PID {1}  {2}" -f $Vid, $pids, $prod) -ForegroundColor Green
    $pidMain = $devices[0].Pid
} else {
    Write-Host ("[1/3] device : no VID_{0} device present right now" -f $Vid) -ForegroundColor Yellow
    Write-Host '      plug the keyboard in (or wake it) and re-run if detection fails below'
    $pidMain = ''
}

# ---- 2. vendor app -----------------------------------------------------------
if ($ExePath) {
    $app = [pscustomobject]@{
        Exe = $ExePath
        Dir = [System.IO.Path]::GetDirectoryName($ExePath)
        PidList = ''
        Model = ''
        TimeOnOpen = $false
    }
} else {
    $app = Find-VendorApp -Vid $Vid -TargetPid $pidMain
}

if (-not $app) {
    Write-Host '[2/3] app    : NOT FOUND' -ForegroundColor Red
    Write-Host '      The OEM driver for this keyboard is not installed (or lives somewhere unusual).'
    Write-Host '      Install the vendor app that shows "GeGe / RK / Sparrow" style UI first,'
    Write-Host '      then run this again. Use -ExePath <path> to point at it manually.'
    exit 1
}

Write-Host ("[2/3] app    : {0}" -f $app.Exe) -ForegroundColor Green
if ($app.Model) {
    if ($pidMain -and $app.ModelPid -and $app.ModelPid -ne $pidMain) {
        Write-Host ("      model hint : Dev\{0}  (device PID {1} is not listed under Dev\, closest match used)" -f $app.Model, $pidMain)
    } else {
        Write-Host ("      model  : Dev\{0}" -f $app.Model)
    }
}
if ($app.PidList) {
    Write-Host ("      PIDs   : {0}" -f $app.PidList)
}
if ($app.TimeOnOpen) {
    Write-Host '      time-on-open : enabled (app pushes host time when it opens the device)' -ForegroundColor Green
} else {
    Write-Host '      time-on-open : NOT found in KB.ini for this model' -ForegroundColor Yellow
    Write-Host '      the app may not set the clock merely by opening; test the result after install'
}

if ($DetectOnly) {
    Write-Host ''
    Write-Host 'Detect-only mode: nothing was changed.'
    return
}

# ---- 3. register -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $vbs)) { throw "missing $vbs" }

$cfg = [ordered]@{
    vid       = $Vid
    pid       = $pidMain
    exePath   = $app.Exe
    model     = $app.Model
    timeOnOpen = [bool]$app.TimeOnOpen
    createdAt = (Get-Date -Format 's')
}
$cfg | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

$user = "$env:USERDOMAIN\$env:USERNAME"
$t = [datetime]::ParseExact($At, 'HH:mm', $null)
$start = (Get-Date).Date.AddHours($t.Hour).AddMinutes($t.Minute)
if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }
$boundary = $start.ToString('yyyy-MM-ddTHH:mm:ss')

$xml = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Daily silent time sync for a keyboard with a clock screen (runs on a private desktop).</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>{3}</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>{0}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT3M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>"{1}"</Arguments>
      <WorkingDirectory>{2}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
'@ -f $user, $vbs, $root, $boundary

$xmlPath = Join-Path $root 'task.xml'
Set-Content -LiteralPath $xmlPath -Value $xml -Encoding Unicode

$out = schtasks.exe /Create /TN "$taskName" /XML "$xmlPath" /F 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host '[3/3] task   : FAILED' -ForegroundColor Red
    Write-Host ($out -join "`n")
    Write-Host '      Try running install.cmd from a normal (non-sandboxed) command prompt.'
    exit 1
}
Write-Host ("[3/3] task   : registered, daily at {0}" -f $At) -ForegroundColor Green

if (-not $NoTest) {
    Write-Host ''
    Write-Host 'test run (the keyboard clock should update; nothing should appear on screen)...'
    schtasks.exe /Run /TN "$taskName" 2>&1 | Out-Null
    Start-Sleep -Seconds 16
    Write-Host ''
    Write-Host '--- sync.log ---'
    Get-Content -LiteralPath $logPath -Tail 3 -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Done. Log: $logPath"
Write-Host "Stop : schtasks /Delete /TN `"$taskName`" /F"
Write-Host ''
