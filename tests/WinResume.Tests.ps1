# WinResume.Tests.ps1 - Pester 5 tests for the pure logic in WinResume.psm1.
# Run on Windows: Invoke-Pester -Path ./tests
# Nothing here touches the live event log. All reboot decisions are tested
# against mocked event objects built with [pscustomobject].

BeforeAll {
    Import-Module "$PSScriptRoot/../src/WinResume.psm1" -Force

    # Helper functions live here too: in Pester 5, only one BeforeAll block
    # runs per level, and code written directly in a Describe body (or at
    # file scope outside BeforeAll) runs during discovery and is not visible
    # inside It blocks.
    function New-RestartEvent {
        param(
            [string]$Time,
            [string]$Process,
            [string]$Reason = '0x0',
            [string]$Type = 'restart'
        )
        return [pscustomobject]@{
            TimeCreated  = [datetime]$Time
            ProcessName  = $Process
            ReasonCode   = $Reason
            ShutdownType = $Type
        }
    }

    function New-UnexpectedEvent {
        param([string]$Time)
        return [pscustomobject]@{ TimeCreated = [datetime]$Time }
    }
}

Describe 'Get-WinResumeConfig' {
    It 'parses a valid task list' {
        $path = Join-Path $TestDrive 'tasks.json'
        Set-Content -LiteralPath $path -Value @'
{
  "version": 1,
  "tasks": [
    { "name": "a", "command": "C:\\Tools\\a.exe", "arguments": "--x", "workingDirectory": "C:\\Tools", "enabled": true },
    { "name": "b", "command": "C:\\Tools\\b.exe", "enabled": false }
  ]
}
'@
        $config = Get-WinResumeConfig -Path $path
        $config.Version | Should -Be 1
        $config.Tasks.Count | Should -Be 2
        $config.Tasks[0].Name | Should -Be 'a'
        $config.Tasks[0].Arguments | Should -Be '--x'
        $config.Tasks[1].WorkingDirectory | Should -Be ([string]$env:USERPROFILE)
        $config.Tasks[1].Enabled | Should -BeFalse
    }

    It 'throws when the file is missing' {
        { Get-WinResumeConfig -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw
    }

    It 'throws when the JSON is invalid' {
        $path = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $path -Value '{ this is not json'
        { Get-WinResumeConfig -Path $path } | Should -Throw
    }

    It 'throws on an unsupported version' {
        $path = Join-Path $TestDrive 'v2.json'
        Set-Content -LiteralPath $path -Value '{"version": 2, "tasks": []}'
        { Get-WinResumeConfig -Path $path } | Should -Throw
    }

    It 'throws when a task has no command' {
        $path = Join-Path $TestDrive 'nocmd.json'
        Set-Content -LiteralPath $path -Value '{"version": 1, "tasks": [{"name": "x", "enabled": true}]}'
        { Get-WinResumeConfig -Path $path } | Should -Throw
    }

    It 'throws when enabled is missing' {
        $path = Join-Path $TestDrive 'noenabled.json'
        Set-Content -LiteralPath $path -Value '{"version": 1, "tasks": [{"name": "x", "command": "C:\\x.exe"}]}'
        { Get-WinResumeConfig -Path $path } | Should -Throw
    }

    It 'accepts an empty task list' {
        $path = Join-Path $TestDrive 'empty.json'
        Set-Content -LiteralPath $path -Value '{"version": 1, "tasks": []}'
        $config = Get-WinResumeConfig -Path $path
        $config.Tasks.Count | Should -Be 0
    }
}

Describe 'Get-EnabledWinResumeTask' {
    It 'returns only enabled tasks' {
        $config = [pscustomobject]@{
            Tasks = @(
                [pscustomobject]@{ Name = 'on'; Enabled = $true },
                [pscustomobject]@{ Name = 'off'; Enabled = $false }
            )
        }
        $enabled = Get-EnabledWinResumeTask -Config $config
        $enabled.Count | Should -Be 1
        $enabled[0].Name | Should -Be 'on'
    }
}

Describe 'ConvertTo-RestartEvent' {
    It 'extracts fields from event properties' {
        $mock = [pscustomobject]@{
            TimeCreated = [datetime]'2026-11-14 03:12:00'
            Id          = 1074
            Properties  = @(
                [pscustomobject]@{ Value = 'C:\Windows\system32\wuauclt.exe (DESKTOP-1)' },
                [pscustomobject]@{ Value = 'DESKTOP-1' },
                [pscustomobject]@{ Value = 'Operating System: Recovery (Planned)' },
                [pscustomobject]@{ Value = '0x80020002' },
                [pscustomobject]@{ Value = 'restart' },
                [pscustomobject]@{ Value = '' },
                [pscustomobject]@{ Value = 'NT AUTHORITY\SYSTEM' }
            )
            Message     = 'unused when properties exist'
        }
        $restartEvent = ConvertTo-RestartEvent -Event $mock
        $restartEvent.ProcessName | Should -Be 'wuauclt.exe'
        $restartEvent.ReasonCode | Should -Be '0x80020002'
        $restartEvent.ShutdownType | Should -Be 'restart'
        $restartEvent.TimeCreated | Should -Be ([datetime]'2026-11-14 03:12:00')
    }

    It 'falls back to the message when properties are missing' {
        $mock = [pscustomobject]@{
            TimeCreated = [datetime]'2026-11-14 03:12:00'
            Id          = 1074
            Properties  = @()
            Message     = 'The process C:\Windows\System32\USOClient.exe (DESKTOP-1) has initiated the restart of computer DESKTOP-1 on behalf of user NT AUTHORITY\SYSTEM for the following reason: Operating System: Service pack (Planned) Reason Code: 0x80020010 Shutdown Type: restart Comment: '
        }
        $restartEvent = ConvertTo-RestartEvent -Event $mock
        $restartEvent.ProcessName | Should -Be 'usoclient.exe'
        $restartEvent.ReasonCode | Should -Be '0x80020010'
        $restartEvent.ShutdownType | Should -Be 'restart'
    }

    It 'lowercases the process name' {
        $mock = [pscustomobject]@{
            TimeCreated = [datetime]'2026-11-14 03:12:00'
            Id          = 1074
            Properties  = @(
                [pscustomobject]@{ Value = 'C:\Windows\System32\MoUsoCoreWorker.exe (DESKTOP-1)' },
                [pscustomobject]@{ Value = 'DESKTOP-1' },
                [pscustomobject]@{ Value = '' },
                [pscustomobject]@{ Value = '0x80020010' },
                [pscustomobject]@{ Value = 'restart' }
            )
            Message     = ''
        }
        $restartEvent = ConvertTo-RestartEvent -Event $mock
        $restartEvent.ProcessName | Should -Be 'mousocoreworker.exe'
    }
}

Describe 'Test-UpdateInitiatedReboot' {
    BeforeAll {
        $script:boot = [datetime]'2026-11-15 08:00:00'
    }

    It 'detects wuauclt.exe as an update reboot' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'wuauclt.exe' -Reason '0x80020002')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeTrue
        $result.Reason | Should -Be 'UpdateProcess'
    }

    It 'detects usoclient.exe as an update reboot' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'usoclient.exe' -Reason '0x80020010')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeTrue
    }

    It 'detects mousocoreworker.exe as an update reboot' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'mousocoreworker.exe' -Reason '0x80020010')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeTrue
    }

    It 'detects trustedinstaller.exe as an update reboot' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'trustedinstaller.exe' -Reason '0x80020010')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeTrue
    }

    It 'detects svchost.exe with reason 0x80020010 as an update reboot' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'svchost.exe' -Reason '0x80020010')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeTrue
        $result.Reason | Should -Be 'UpdateReasonCode'
    }

    It 'does not count svchost.exe with another reason code' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'svchost.exe' -Reason '0x0')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeFalse
        $result.Reason | Should -Be 'NonUpdateRestart'
    }

    It 'does not count a user restart (explorer.exe)' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'explorer.exe' -Reason '0x0')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeFalse
        $result.Reason | Should -Be 'NonUpdateRestart'
    }

    It 'does not count a user restart (winlogon.exe)' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'winlogon.exe' -Reason '0x0')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeFalse
    }

    It 'returns false when there is no restart event' {
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents @()
        $result.IsUpdateReboot | Should -BeFalse
        $result.Reason | Should -Be 'NoRestartEvent'
    }

    It 'vetoes when a newer unexpected shutdown follows the update restart' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'wuauclt.exe' -Reason '0x80020002')
        $unexpected = @(New-UnexpectedEvent -Time '2026-11-15 06:30:00')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events -UnexpectedEvents $unexpected
        $result.IsUpdateReboot | Should -BeFalse
        $result.Reason | Should -Be 'UnexpectedShutdownAfterRestart'
    }

    It 'does not veto when the unexpected shutdown is older than the restart' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'wuauclt.exe' -Reason '0x80020002')
        $unexpected = @(New-UnexpectedEvent -Time '2026-11-14 22:00:00')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events -UnexpectedEvents $unexpected
        $result.IsUpdateReboot | Should -BeTrue
    }

    It 'returns false when the restart was requested after this boot began' {
        $events = @(New-RestartEvent -Time '2026-11-15 09:00:00' -Process 'wuauclt.exe' -Reason '0x80020002')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeFalse
        $result.Reason | Should -Be 'RestartAfterBoot'
    }

    It 'returns false for a power off, even from an update process' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'wuauclt.exe' -Reason '0x80020002' -Type 'power off')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeFalse
        $result.Reason | Should -Be 'NotARestart'
    }

    It 'accepts the localized Chinese shutdown type' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'wuauclt.exe' -Reason '0x80020002' -Type '重新启动')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeTrue
    }

    It 'returns false for an unknown shutdown type' {
        $events = @(New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'wuauclt.exe' -Reason '0x80020002' -Type '')
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeFalse
        $result.Reason | Should -Be 'NotARestart'
    }

    It 'uses the newest restart event when several exist' {
        $events = @(
            (New-RestartEvent -Time '2026-11-14 03:00:00' -Process 'wuauclt.exe' -Reason '0x80020002'),
            (New-RestartEvent -Time '2026-11-15 03:12:00' -Process 'explorer.exe' -Reason '0x0')
        )
        $result = Test-UpdateInitiatedReboot -LastBootTime $script:boot -RestartEvents $events
        $result.IsUpdateReboot | Should -BeFalse
        $result.Reason | Should -Be 'NonUpdateRestart'
    }
}

Describe 'Start-WinResumeRun' {
    It 'starts every task and keeps going after a failed one' {
        $logPath = Join-Path $TestDrive 'run.log'
        # Platform-aware "good" command: the logic under test (continue
        # after a failure) is the same everywhere; only the executable
        # that is guaranteed to exist differs.
        if ($IsWindows) {
            $goodCommand = $env:ComSpec
            $goodArguments = '/c exit 0'
        }
        else {
            $goodCommand = '/bin/true'
            $goodArguments = ''
        }
        # Use a real filesystem path for the working directory: Start-Process
        # does not resolve PowerShell drive paths such as TestDrive:\.
        $goodDir = [System.IO.Path]::GetTempPath().TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        $tasks = @(
            [pscustomobject]@{ Name = 'good'; Command = $goodCommand; Arguments = $goodArguments; WorkingDirectory = $goodDir; Enabled = $true },
            [pscustomobject]@{ Name = 'missing-exe'; Command = 'C:\definitely\missing.exe'; Arguments = ''; WorkingDirectory = $goodDir; Enabled = $true },
            [pscustomobject]@{ Name = 'missing-dir'; Command = $goodCommand; Arguments = $goodArguments; WorkingDirectory = (Join-Path $goodDir 'definitely-missing-dir'); Enabled = $true },
            [pscustomobject]@{ Name = 'also-good'; Command = $goodCommand; Arguments = ''; WorkingDirectory = $goodDir; Enabled = $true }
        )
        $results = Start-WinResumeRun -Tasks $tasks -LogPath $logPath
        $results.Count | Should -Be 4
        ($results | Where-Object Name -eq 'good').Started | Should -BeTrue
        ($results | Where-Object Name -eq 'missing-dir').Started | Should -BeFalse
        ($results | Where-Object Name -eq 'also-good').Started | Should -BeTrue
        if ($IsWindows) {
            # On Windows, Start-Process throws for a missing executable.
            ($results | Where-Object Name -eq 'missing-exe').Started | Should -BeFalse
        }
        else {
            # On Linux, Start-Process hands unknown files to xdg-open and
            # reports success even when the target does not exist. The
            # Windows CI run covers the real failure path; this run still
            # proves the run continued past the bad task.
            ($results | Where-Object Name -eq 'missing-exe').Started | Should -BeTrue
        }
        $log = Get-Content -LiteralPath $logPath -Raw
        $log | Should -Match 'missing-exe'
        $log | Should -Match 'also-good'
    }
}

Describe 'Write-ResumeLog' {
    It 'appends a timestamped line' {
        $logPath = Join-Path $TestDrive 'app.log'
        Write-ResumeLog -LogPath $logPath -Message 'hello log'
        $content = Get-Content -LiteralPath $logPath -Raw
        $content | Should -Match 'hello log'
        $content | Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
    }
}

Describe 'Get-WinResumeState and Set-WinResumeState' {
    It 'round-trips the boot checkpoint' {
        $statePath = Join-Path $TestDrive 'state.json'
        Set-WinResumeState -Path $statePath -LastBootTime ([datetime]'2026-11-15 08:00:00') -LastDecision 'Resumed' -LastReason 'UpdateProcess'
        $state = Get-WinResumeState -Path $statePath
        $state.lastDecision | Should -Be 'Resumed'
        $state.lastReason | Should -Be 'UpdateProcess'
        # ConvertFrom-Json returns the ISO string as a DateTime on PowerShell
        # 7 and as a string on Windows PowerShell 5.1: compare as datetimes.
        ([datetime]$state.lastBootTime) | Should -Be ([datetime]'2026-11-15 08:00:00')
    }

    It 'returns null when the state file is missing' {
        $state = Get-WinResumeState -Path (Join-Path $TestDrive 'nope.json')
        $state | Should -BeNullOrEmpty
    }
}
