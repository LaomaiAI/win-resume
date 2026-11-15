#requires -Version 5.1
<#
.SYNOPSIS
    WinResume worker: resume preset tasks after a Windows Update-triggered reboot.
.DESCRIPTION
    Runs at user logon (registered by install.ps1). It checks the System event
    log to decide whether the last restart was initiated by Windows Update.
    Only an update-triggered restart resumes the enabled tasks in tasks.json.
    A normal boot or a manual restart does nothing except write a log line.
    Exit codes: 0 = done (including "not an update reboot" and "some tasks
    failed to start" - per-task failures are logged, never fatal), 1 = could
    not read the evidence (event log / boot time), 2 = bad task list.
#>
[CmdletBinding()]
param(
    [switch]$NoNotification,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\WinResume.psm1') -Force

$stateDir = Join-Path $env:LOCALAPPDATA 'WinResume'
if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}
$logPath = Join-Path $stateDir 'win-resume.log'
$statePath = Join-Path $stateDir 'state.json'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'tasks.json'
}

try {
    $config = Get-WinResumeConfig -Path $ConfigPath
}
catch {
    Write-ResumeLog -LogPath $logPath -Message "Bad task list, exiting. $($_.Exception.Message)"
    exit 2
}

try {
    $evidence = Get-RestartEvidence
}
catch {
    Write-ResumeLog -LogPath $logPath -Message "Could not read restart evidence, exiting without resuming. $($_.Exception.Message)"
    exit 1
}

# Idempotency guard: never resume twice for the same boot session. The
# checkpoint file is only a guard; the detection signal is the event log.
# Compare as datetimes: ConvertFrom-Json returns the stored ISO string as
# a DateTime on PowerShell 7 and as a string on Windows PowerShell 5.1.
$state = Get-WinResumeState -Path $statePath
if ($null -ne $state -and $null -ne $state.lastBootTime -and ([datetime]$state.lastBootTime) -eq $evidence.LastBootTime) {
    Write-ResumeLog -LogPath $logPath -Message "Boot $($evidence.LastBootTime.ToString('o')) already processed, exiting."
    exit 0
}

$decision = Test-UpdateInitiatedReboot -LastBootTime $evidence.LastBootTime `
    -RestartEvents $evidence.RestartEvents `
    -UnexpectedEvents $evidence.UnexpectedEvents

$evidenceText = ''
if ($null -ne $decision.Evidence) {
    $evidenceText = " Process=$($decision.Evidence.ProcessName) ReasonCode=$($decision.Evidence.ReasonCode) Time=$($decision.Evidence.TimeCreated)."
}
Write-ResumeLog -LogPath $logPath -Message "Decision: update reboot = $($decision.IsUpdateReboot) ($($decision.Reason)).$evidenceText"

if ($evidence.Corroboration.Count -gt 0) {
    $latestUpdate = $evidence.Corroboration | Sort-Object TimeCreated -Descending | Select-Object -First 1
    Write-ResumeLog -LogPath $logPath -Message "Corroboration: $($evidence.Corroboration.Count) Windows Update client event(s) found, latest is Event $($latestUpdate.Id) at $($latestUpdate.TimeCreated)."
}

if (-not $decision.IsUpdateReboot) {
    Set-WinResumeState -Path $statePath -LastBootTime $evidence.LastBootTime -LastDecision 'Skipped' -LastReason $decision.Reason
    exit 0
}

# @(): on Windows PowerShell 5.1 a function that outputs one object hands
# back a scalar, and .Count on a scalar is $null - so without the wrap,
# the "no enabled tasks" check below would never trigger.
$enabled = @(Get-EnabledWinResumeTask -Config $config)
if ($enabled.Count -eq 0) {
    Write-ResumeLog -LogPath $logPath -Message 'Update reboot detected, but no enabled tasks in tasks.json. Nothing to resume.'
    Set-WinResumeState -Path $statePath -LastBootTime $evidence.LastBootTime -LastDecision 'Resumed' -LastReason 'NoEnabledTasks'
    exit 0
}

Write-ResumeLog -LogPath $logPath -Message "Update reboot detected. Resuming $($enabled.Count) task(s)."
$results = @(Start-WinResumeRun -Tasks $enabled -LogPath $logPath)

$startedCount = @($results | Where-Object { $_.Started }).Count
$failedCount = $results.Count - $startedCount
Write-ResumeLog -LogPath $logPath -Message "Resume run finished. Started: $startedCount. Failed to start: $failedCount."

Set-WinResumeState -Path $statePath -LastBootTime $evidence.LastBootTime -LastDecision 'Resumed' -LastReason $decision.Reason

if (-not $NoNotification) {
    $body = "WinResume restarted $startedCount task(s) after a Windows Update reboot."
    if ($failedCount -gt 0) {
        $body += " $failedCount task(s) failed to start - see the log."
    }
    $shown = Show-WinResumeNotification -Title 'WinResume: tasks resumed' -Body $body
    Write-ResumeLog -LogPath $logPath -Message "Notification shown: $shown."
}

exit 0
