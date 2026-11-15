#requires -Version 5.1
<#
.SYNOPSIS
    Install or uninstall WinResume (registers a scheduled task at logon).
.DESCRIPTION
    Install (default): registers a scheduled task named "WinResume" that runs
    resume.ps1 at user logon. The task runs as your own user account, with
    normal (non-elevated) rights, and only in your own logon session.
    Registering a scheduled task needs Administrator rights, so this script
    re-launches itself elevated when needed. It never disables Windows
    Update and never touches update settings: WinResume accepts the reboot
    and resumes your tasks afterwards.
    Uninstall: install.ps1 -Uninstall removes the scheduled task. State and
    log files under %LOCALAPPDATA%\WinResume are left in place.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$taskName = 'WinResume'
$scriptDir = $PSScriptRoot

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Uninstall) {
        $arguments += '-Uninstall'
    }
    Write-Host 'WinResume needs Administrator rights to register the scheduled task. Re-launching elevated...'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs
    exit 0
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "WinResume scheduled task '$taskName' removed."
    Write-Host 'State and log files were left in place under %LOCALAPPDATA%\WinResume.'
    exit 0
}

$tasksPath = Join-Path $scriptDir 'tasks.json'
$examplePath = Join-Path $scriptDir 'tasks.example.json'

if (-not (Test-Path -LiteralPath $tasksPath -PathType Leaf)) {
    Copy-Item -LiteralPath $examplePath -Destination $tasksPath
    Write-Host "Created $tasksPath from the example. Edit it before your next reboot."
}

Import-Module (Join-Path $scriptDir 'src\WinResume.psm1') -Force
try {
    $config = Get-WinResumeConfig -Path $tasksPath
}
catch {
    Write-Error "Your tasks.json is not valid, fix it and run install.ps1 again. $($_.Exception.Message)"
    exit 1
}
$enabledCount = @($config.Tasks | Where-Object { $_.Enabled }).Count
Write-Host "Task list OK: $($config.Tasks.Count) task(s), $enabledCount enabled."

$stateDir = Join-Path $env:LOCALAPPDATA 'WinResume'
if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$resumePath = Join-Path $scriptDir 'resume.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$resumePath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -User $env:USERNAME -RunLevel Limited `
    -Description 'WinResume: resume preset tasks after a Windows Update-triggered reboot.' -Force | Out-Null

$task = Get-ScheduledTask -TaskName $taskName
Write-Host ''
Write-Host "Installed. Scheduled task '$taskName' is $($task.State)."
Write-Host "  Runs at logon as: $env:USERNAME"
Write-Host "  Runs: $resumePath"
Write-Host "  Task list: $tasksPath"
Write-Host "  Log: $stateDir\win-resume.log"
Write-Host ''
Write-Host 'Next step: edit tasks.json and enable the tasks you want resumed.'
