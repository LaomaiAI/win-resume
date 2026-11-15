# WinResume.psm1 - Core logic for the WinResume tool.
# Resume preset commands after a Windows Update-triggered reboot.
# PowerShell 5.1 compatible. No external modules, no network calls, no LLM.
#
# The functions are split into two groups:
#   - Pure functions, testable without live event logs: Get-WinResumeConfig,
#     Get-EnabledWinResumeTask, ConvertTo-RestartEvent,
#     Test-UpdateInitiatedReboot, Start-WinResumeRun, Write-ResumeLog,
#     Show-WinResumeNotification, Get-WinResumeState, Set-WinResumeState.
#   - Live functions, thin wrappers over Get-WinEvent / Get-CimInstance:
#     Get-RestartEvidence (and the internal Get-WinEventSafe helper).
#
# Detection rule (see NOTES.md for sources):
#   The last restart before this boot is an update reboot when the newest
#   System log Event ID 1074 (User32) was initiated by a Windows Update /
#   servicing component, or by svchost.exe with the planned update reason
#   code 0x80020010. A newer unexpected shutdown (Event 41 / 6008) vetoes
#   the decision: the last boot then followed a crash or power loss, not
#   the planned restart.

$script:UpdateProcesses = @(
    'wuauclt.exe',          # Legacy Windows Update client
    'usoclient.exe',        # Update Session Orchestrator client
    'mousocoreworker.exe',  # Update Session Orchestrator worker (MoUsoCoreWorker.exe)
    'trustedinstaller.exe'  # Windows Modules Installer (servicing)
)

$script:UpdateReasonCodes = @(
    '0x80020010'  # Operating System: Service pack (Planned)
)

$script:RestartShutdownTypes = @(
    'restart',      # en-US
    '重新启动'      # zh-CN
)

function Get-WinResumeConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Task list not found: $Path"
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Task list is not valid JSON: $Path. $($_.Exception.Message)"
    }

    if ($raw.version -ne 1) {
        throw "Unsupported task list version in: $Path. Expected version 1."
    }

    if (-not ($raw.PSObject.Properties.Name -contains 'tasks')) {
        throw "Task list has no 'tasks' array: $Path"
    }

    $tasks = @()
    foreach ($t in @($raw.tasks)) {
        if ([string]::IsNullOrWhiteSpace($t.name)) {
            throw "A task in $Path has no name."
        }
        if ([string]::IsNullOrWhiteSpace($t.command)) {
            throw "Task '$($t.name)' in $Path has no command."
        }
        if ($null -eq $t.enabled -or $t.enabled -isnot [bool]) {
            throw "Task '$($t.name)' in $Path must set enabled to true or false."
        }

        $workingDirectory = $t.workingDirectory
        if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
            $workingDirectory = $env:USERPROFILE
        }

        $arguments = $t.arguments
        if ($null -eq $arguments) {
            $arguments = ''
        }

        $tasks += [pscustomobject]@{
            Name             = [string]$t.name
            Command          = [string]$t.command
            Arguments        = [string]$arguments
            WorkingDirectory = [string]$workingDirectory
            Enabled          = [bool]$t.enabled
        }
    }

    return [pscustomobject]@{
        Version = 1
        Tasks   = $tasks
    }
}

function Get-EnabledWinResumeTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config
    )

    return @($Config.Tasks | Where-Object { $_.Enabled })
}

function ConvertTo-RestartEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Event
    )

    $processName = ''
    $reasonCode = ''
    $shutdownType = ''

    # Primary source: the structured event properties of Event ID 1074.
    # Properties[0] = requesting process path followed by the computer name
    # in parentheses. Properties[3] = reason code. Properties[4] = shutdown
    # type (restart / power off). These fields are not localized, except
    # that the shutdown type string can be localized on non-English systems.
    $props = $Event.Properties
    if ($null -ne $props -and $props.Count -ge 1 -and $null -ne $props[0].Value) {
        $m = [regex]::Match(
            [string]$props[0].Value,
            '([A-Za-z0-9_\-\.]+\.exe)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($m.Success) {
            $processName = $m.Groups[1].Value.ToLowerInvariant()
        }
    }
    if ($null -ne $props -and $props.Count -ge 4 -and $null -ne $props[3].Value) {
        $reasonCode = ([string]$props[3].Value).ToLowerInvariant()
    }
    if ($null -ne $props -and $props.Count -ge 5 -and $null -ne $props[4].Value) {
        $shutdownType = [string]$props[4].Value
    }

    # Fallback: parse the human-readable message when properties are missing.
    $message = ''
    if ($null -ne $Event.Message) {
        $message = [string]$Event.Message
    }
    if ([string]::IsNullOrWhiteSpace($processName) -and $message -ne '') {
        $m = [regex]::Match(
            $message,
            'process\s+(\S+\.exe)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($m.Success) {
            # Take the file name only. [System.IO.Path]::GetFileName does
            # not split on backslashes on non-Windows systems, so split
            # on both separators explicitly.
            $processName = (($m.Groups[1].Value -split '[\\/]')[-1]).ToLowerInvariant()
        }
    }
    if ([string]::IsNullOrWhiteSpace($reasonCode) -and $message -ne '') {
        $m = [regex]::Match($message, 'Reason Code:\s*(0x[0-9A-Fa-f]+)')
        if ($m.Success) {
            $reasonCode = $m.Groups[1].Value.ToLowerInvariant()
        }
    }
    if ([string]::IsNullOrWhiteSpace($shutdownType) -and $message -ne '') {
        # Match a known shutdown type directly. Capturing "to end of line"
        # would swallow the following Comment field when the message is
        # single-line, so only the known values are accepted here.
        $m = [regex]::Match(
            $message,
            'Shutdown Type:\s*(restart|power off|重新启动|关机)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($m.Success) {
            $shutdownType = $m.Groups[1].Value.Trim()
        }
    }

    return [pscustomobject]@{
        TimeCreated  = $Event.TimeCreated
        ProcessName  = $processName
        ReasonCode   = $reasonCode
        ShutdownType = $shutdownType
        RawMessage   = $message
    }
}

function Test-UpdateInitiatedReboot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$LastBootTime,

        [Parameter(Mandatory = $false)]
        [object[]]$RestartEvents = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$UnexpectedEvents = @()
    )

    $restarts = @($RestartEvents | Where-Object { $null -ne $_ -and $null -ne $_.TimeCreated })
    if ($restarts.Count -eq 0) {
        return [pscustomobject]@{
            IsUpdateReboot = $false
            Reason         = 'NoRestartEvent'
            Evidence       = $null
        }
    }

    $latest = $restarts | Sort-Object TimeCreated -Descending | Select-Object -First 1

    # A restart requested after this boot began cannot be the cause of it.
    if ($latest.TimeCreated -gt $LastBootTime) {
        return [pscustomobject]@{
            IsUpdateReboot = $false
            Reason         = 'RestartAfterBoot'
            Evidence       = $latest
        }
    }

    # A newer unexpected shutdown (crash / power loss) vetoes the decision:
    # the last boot followed the crash, not the planned restart.
    $unexpected = @($UnexpectedEvents | Where-Object {
        $null -ne $_ -and $null -ne $_.TimeCreated -and $_.TimeCreated -le $LastBootTime
    })
    if ($unexpected.Count -gt 0) {
        $latestUnexpected = $unexpected | Sort-Object TimeCreated -Descending | Select-Object -First 1
        if ($latestUnexpected.TimeCreated -gt $latest.TimeCreated) {
            return [pscustomobject]@{
                IsUpdateReboot = $false
                Reason         = 'UnexpectedShutdownAfterRestart'
                Evidence       = $latest
            }
        }
    }

    # Only a restart (not a power off) counts as a reboot to resume after.
    $shutdownType = ''
    if ($null -ne $latest.ShutdownType) {
        $shutdownType = ([string]$latest.ShutdownType).Trim()
    }
    $isRestart = $false
    foreach ($t in $script:RestartShutdownTypes) {
        if ($shutdownType -eq $t) {
            $isRestart = $true
        }
    }
    if (-not $isRestart) {
        return [pscustomobject]@{
            IsUpdateReboot = $false
            Reason         = 'NotARestart'
            Evidence       = $latest
        }
    }

    $process = ''
    if ($null -ne $latest.ProcessName) {
        $process = ([string]$latest.ProcessName).ToLowerInvariant()
    }
    if ($script:UpdateProcesses -contains $process) {
        return [pscustomobject]@{
            IsUpdateReboot = $true
            Reason         = 'UpdateProcess'
            Evidence       = $latest
        }
    }

    # svchost.exe hosts many services, so it only counts with the planned
    # update reason code.
    $reasonCode = ''
    if ($null -ne $latest.ReasonCode) {
        $reasonCode = ([string]$latest.ReasonCode).ToLowerInvariant()
    }
    if ($process -eq 'svchost.exe' -and $script:UpdateReasonCodes -contains $reasonCode) {
        return [pscustomobject]@{
            IsUpdateReboot = $true
            Reason         = 'UpdateReasonCode'
            Evidence       = $latest
        }
    }

    return [pscustomobject]@{
        IsUpdateReboot = $false
        Reason         = 'NonUpdateRestart'
        Evidence       = $latest
    }
}

function Get-WinEventSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$FilterHashtable,

        [Parameter(Mandatory = $true)]
        [int]$MaxEvents
    )

    # Get-WinEvent raises a terminating error only when we ask it to, and a
    # "no events found" result is a normal empty answer, not a failure. Tell
    # the two apart by the error id so a fresh machine (no 1074 yet) does
    # not look like a broken event log.
    $records = Get-WinEvent -FilterHashtable $FilterHashtable -MaxEvents $MaxEvents `
        -ErrorAction SilentlyContinue -ErrorVariable winErr
    if ($winErr) {
        $other = @($winErr | Where-Object {
            $_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*' -and
            $_.Exception.Message -notmatch 'No events were found'
        })
        if ($other.Count -gt 0) {
            throw $other[0].Exception
        }
    }

    return @($records)
}

function Get-RestartEvidence {
    [CmdletBinding()]
    param()

    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime

    $restarts = @()
    foreach ($record in (Get-WinEventSafe -FilterHashtable @{ LogName = 'System'; Id = 1074 } -MaxEvents 20)) {
        $restarts += ConvertTo-RestartEvent -Event $record
    }

    $unexpectedTimes = @()
    foreach ($record in (Get-WinEventSafe -FilterHashtable @{ LogName = 'System'; Id = 41, 6008 } -MaxEvents 20)) {
        $unexpectedTimes += [pscustomobject]@{ TimeCreated = $record.TimeCreated }
    }

    # Corroboration only: an update install (19) or a restart-required
    # notice (21) from the Windows Update client shortly before the 1074.
    # It is logged as evidence. It never gates the decision, because log
    # rotation can drop it and the 1074 record alone is the documented
    # statement of intent.
    $corroboration = @()
    try {
        $updateRecords = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-WindowsUpdateClient'
            Id           = 19, 21
        } -MaxEvents 10 -ErrorAction Stop
        foreach ($record in $updateRecords) {
            $corroboration += [pscustomobject]@{
                TimeCreated = $record.TimeCreated
                Id          = $record.Id
            }
        }
    }
    catch {
        Write-Verbose "Corroboration lookup failed (best effort only): $($_.Exception.Message)"
        $corroboration = @()
    }

    return [pscustomobject]@{
        LastBootTime     = $boot
        RestartEvents    = $restarts
        UnexpectedEvents = $unexpectedTimes
        Corroboration    = $corroboration
    }
}

function Start-WinResumeRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $results = @()
    foreach ($task in $Tasks) {
        $detail = ''
        $started = $false

        if (-not (Test-Path -LiteralPath $task.WorkingDirectory -PathType Container)) {
            $detail = "Working directory not found: $($task.WorkingDirectory)"
        }
        else {
            try {
                # -WindowStyle exists on Windows PowerShell only. It throws
                # on non-Windows PowerShell editions, so add it only there.
                # [Environment]::OSVersion works on 5.1 and 7.x alike.
                $startArgs = @{
                    FilePath         = $task.Command
                    WorkingDirectory = $task.WorkingDirectory
                    ErrorAction      = 'Stop'
                }
                if (-not [string]::IsNullOrWhiteSpace($task.Arguments)) {
                    $startArgs['ArgumentList'] = $task.Arguments
                }
                if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
                    $startArgs['WindowStyle'] = 'Normal'
                }
                Start-Process @startArgs | Out-Null
                $started = $true
                $detail = 'Process started.'
            }
            catch {
                $started = $false
                $detail = "Failed to start: $($_.Exception.Message)"
            }
        }

        $result = [pscustomobject]@{
            Name    = $task.Name
            Started = $started
            Detail  = $detail
        }
        $results += $result
        Write-ResumeLog -LogPath $LogPath -Message "Task '$($task.Name)': started=$started. $detail"
    }

    return $results
}

function Write-ResumeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        $dir = [System.IO.Path]::GetDirectoryName($LogPath)
        if ($dir -ne '' -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $LogPath -Value "[$stamp] $Message" -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not write to log $LogPath : $($_.Exception.Message)"
    }
}

function Show-WinResumeNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    # Primary channel: a Windows toast notification through the built-in
    # WinRT API. No modules to install. On some systems this silently does
    # nothing (no registered app id), so failure here is not fatal.
    $notified = $false
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02
        )
        $texts = $template.GetElementsByTagName('text')
        $texts.Item(0).AppendChild($template.CreateTextNode($Title)) | Out-Null
        $texts.Item(1).AppendChild($template.CreateTextNode($Body)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('WinResume')
        $notifier.Show($toast)
        $notified = $true
    }
    catch {
        Write-Verbose "Toast notification failed: $($_.Exception.Message)"
    }

    if (-not $notified) {
        # Fallback channel: a WScript.Shell popup that closes itself after
        # 8 seconds. Built into every Windows install, no modules needed.
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shell.Popup($Body, 8, $Title, 64) | Out-Null
            $notified = $true
        }
        catch {
            Write-Verbose "Popup notification failed: $($_.Exception.Message)"
        }
    }

    return $notified
}

function Get-WinResumeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Verbose "Could not read state file $Path : $($_.Exception.Message)"
        return $null
    }
}

function Set-WinResumeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [datetime]$LastBootTime,

        [Parameter(Mandatory = $true)]
        [string]$LastDecision,

        [Parameter(Mandatory = $true)]
        [string]$LastReason
    )

    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -ne '' -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $state = [pscustomobject]@{
        lastBootTime = $LastBootTime.ToString('o')
        lastDecision = $LastDecision
        lastReason   = $LastReason
        lastRunTime  = (Get-Date).ToString('o')
    }
    $state | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Path -Encoding UTF8
}

Export-ModuleMember -Function @(
    'Get-WinResumeConfig',
    'Get-EnabledWinResumeTask',
    'ConvertTo-RestartEvent',
    'Test-UpdateInitiatedReboot',
    'Get-RestartEvidence',
    'Start-WinResumeRun',
    'Write-ResumeLog',
    'Show-WinResumeNotification',
    'Get-WinResumeState',
    'Set-WinResumeState'
)
