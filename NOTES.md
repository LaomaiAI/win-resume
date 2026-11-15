# WinResume - design notes

## The problem and the evidence

Developers run overnight AI agent tasks on Windows. Windows Update force-reboots the machine and the task dies. Evidence: V2EX hot thread https://v2ex.com/t/1257008 (2026-11-14). The author set up an overnight agent task, woke up to a forced update reboot and the login screen. Dozens of replies describe the same loss, including one that states the requirement directly: a startup item that detects an update reboot and restarts the unfinished task.

All existing answers are prevention: WUB (one-click update blocker), Group Policy, LTSC, switching OS. Prevention is unreliable: Home edition has no Group Policy, and registry changes get quietly reverted by patches. Nothing resumes after the reboot. That is the gap this tool fills.

## The new thing, in one sentence

Accept the reboot, checkpoint the task list, and auto-resume it after boot - instead of trying to prevent the reboot.

## Reboot detection: what signal, and why

### Primary signal: System log Event ID 1074 (User32)

Microsoft's own support article "Troubleshoot unexpected reboots using system event logs" states the rules this tool implements:

- A normal reboot is Event ID 1074 followed by Event ID 13 and Event ID 6009.
- An unexpected reboot is denoted by Event ID 41 and Event ID 6008.
- Event ID 1074 records "the process <Process Name> has initiated the restart of computer <Computer Name> on behalf of user <Domain User> for the following reason: <Reason>. Reason Code: <Hex Code>. Shutdown Type: <Type>."
- "In many cases, the process name helps determine what potentially called for the reboot."

So 1074 is the documented record of restart intent: who asked, on whose behalf, with which reason code. The decision function reads the newest 1074 before the current boot and checks the initiating process.

Sources:
- https://github.com/MicrosoftDocs/SupportArticles-docs/blob/main/support/windows-server/performance/troubleshoot-unexpected-reboots-system-event-logs.md

### Which processes count as "Windows Update"

These are the components that only do update / servicing work, so a 1074 from any of them is an update-initiated restart:

- wuauclt.exe - the legacy Windows Update client. Microsoft's Azure troubleshooting guide quotes a 1074 with "The process C:\Windows\system32\wuauclt.exe ... has initiated the restart ... Reason Code: 0x80020002".
  Source: https://github.com/azure/service-fabric-troubleshooting-guides/blob/HEAD/Cluster/Why%20did%20my%20node%20Reboot.md
- USOClient.exe - the Update Session Orchestrator client. It "will finally [do the] scanning, downloading and installing updates plus restarting the system if needed" and "replaced the older wuauclt.exe in newer Windows versions".
  Source: https://blog.matrixpost.net/mastering-windows-updates-microsoft-updates-part-1/
- MoUsoCoreWorker.exe - the Update Session Orchestrator worker that executes the orchestrator's work. Listed alongside TrustedInstaller.exe as a source of "Windows Update and servicing restarts".
  Sources: https://www.evtxparser.com/en/events/system/1074 and https://www.endpointweekly.com/blog/update-session-orchestrator-uso-wuauclt-detectnow-dead.html
- TrustedInstaller.exe - Windows Modules Installer (servicing). A 1074 records "WindowsUpdateAgent or TrustedInstaller" as the restart initiator.
  Source: https://blog.matrixpost.net/mastering-windows-updates-microsoft-updates-part-1/

svchost.exe is treated differently: it hosts many services, so it only counts together with reason code 0x80020010 ("Operating System: Service pack (Planned)"). That combination is documented as "a scheduled reboot triggered by Windows Update after successfully applying the update".
Source: https://blog.matrixpost.net/mastering-windows-updates-microsoft-updates-part-1/

Deliberately NOT included: TiWorker.exe. It is a servicing worker, but no source found during research names it as a 1074 initiator, so v1 leaves it out rather than guessing. If a real-world 1074 from TiWorker.exe shows up, it can be added with evidence.

### The veto: Event ID 41 / 6008

Per the same Microsoft article, an unexpected reboot "usually isn't [preceded by] an Event ID 1074 log entry" and is denoted by 41 and 6008. The decision function therefore vetoes when the newest unexpected-shutdown event (41 / 6008) is newer than the newest 1074: the last boot followed a crash or power loss, not the planned restart. Resuming a half-finished agent task after a crash is a different promise, and v1 does not make it.

### Corroboration only: WindowsUpdateClient Events 19 / 21

The System log also carries Microsoft-Windows-WindowsUpdateClient events: 19 = "Installation Successful: Windows successfully installed the following update" and 21 = "Restart Required: To complete the installation of the following updates, the computer must be restarted". These are logged as supporting evidence when present. They never gate the decision, because log rotation can drop them and the 1074 record alone is the documented statement of intent.

### Investigated and rejected: an UpdateOrchestrator event channel

The brief listed "UpdateOrchestrator reboot events" as a candidate signal. Research showed there is no such Event Viewer channel: the Update Session Orchestrator writes ETW traces to UpdateSessionOrchestration.etl files, not to a browsable event log, and the events people quote (26, 41) come from the Windows Update agent (wuaueng.dll) in the Microsoft-Windows-WindowsUpdateClient/Operational channel. Parsing binary ETL files at logon would be heavy and fragile for v1, so the tool uses the 1074 + 19/21 combination instead. The UpdateOrchestrator scheduled task (\Microsoft\Windows\UpdateOrchestrator\Reboot) is what triggers the reboot; the 1074 is what proves it happened.
Source: https://www.endpointweekly.com/blog/update-session-orchestrator-uso-wuauclt-detectnow-dead.html

### The checkpoint file is a guard, not a signal

state.json under %LOCALAPPDATA%\WinResume records the last processed boot time and decision. Its only job is idempotency: never resume twice for the same boot session (for example, if the logon trigger fires again after a logoff/logon). Detection is purely event-log based. If the state file is deleted, the next logon re-reads the event log and decides again from scratch.

### Localization caveat

The 1074 shutdown-type field is localized on non-English systems (the process path and the hex reason code are not). v1 accepts "restart" and the Chinese "重新启动". Anything else, including an empty value, means "not a restart" and no resume. The rule is deliberately conservative: better to skip once than to resume wrongly.

## Resume semantics

- Fire and forget: v1 starts each enabled command with Start-Process and records whether the process started. It does not wait for exit and does not check exit codes. Resumed agent tasks run for hours; waiting for them would block the logon task.
- Fail-stop per task, never for the whole run: a task that fails to start (bad path, missing working directory) is logged and the run continues with the rest. A single bad task never silently cancels the others.
- No agent-context resume: the command is re-run from scratch. If the agent supports a resume flag, put it in the task's arguments.

## Triggers and privileges

- Trigger is AtLogOn, not AtStartup: resumed commands run in the user's own logon session, which agent CLIs need. Consequence: if the PC reboots and sits at the lock screen, the resume waits until someone logs on.
- The scheduled task runs as the user, with normal (non-elevated) rights. Registering the task needs Administrator rights, so install.ps1 re-launches itself elevated only for registration. The task action uses "-ExecutionPolicy Bypass" because scheduled tasks do not inherit the user's interactive execution policy; the script is local and user-owned.

## Notifications

Primary channel is a WinRT toast (ToastNotificationManager, built into Windows, no modules). On some systems a toast from an unregistered app id silently does nothing, so the fallback is a WScript.Shell popup that closes itself after 8 seconds. Both channels are best effort: notification failure never fails the run, and the log file always has the record.

## Deterministic by design

100% code. No LLM, no network requests, no accounts, no cloud. The decision rule is fixed event-log logic: same input, same output. Tests live in tests/ (Pester 5) and run on every push in GitHub Actions on Windows (windows-latest).

## Verification status

Verified locally on the Linux build machine (2026-11-15, PowerShell 7.5.4 installed to /tmp for validation only):
- tasks.json and tasks.example.json parse as JSON; test.yml parses as YAML.
- All .ps1/.psm1 files parse cleanly with the real PowerShell parser.
- Pester suite: 31/31 tests pass on Linux (pwsh 7.5.4, Pester 5.7.1). The suite is written to run on Windows PowerShell 5.1 as well; the one Windows-only behavior (a missing executable throwing from Start-Process) is covered by a platform-conditional assertion, with the real path exercised by the Windows CI run.
- PSScriptAnalyzer: 0 errors (13 Information and 22 Warning findings remain, all non-blocking: missing comment-based help, ShouldProcess suggestions, and similar style notes).
- The tests caught three real bugs during development: a misspelled process name in the allowlist (MoUsoCoreWorker), a message-fallback regex that returned a full path on non-Windows systems, and -WindowStyle throwing on non-Windows PowerShell. All three are fixed.
- Known local-validation limits: PowerShell 7.5 on Linux cannot run the Windows-only paths (Get-WinEvent live queries, WinRT toast, WScript popup, scheduled-task registration). Those are exercised only by the Windows CI run and by real use.

Still needs the Windows CI run (after the repo is pushed):
- GitHub Actions workflow on windows-latest: JSON validation, PowerShell syntax parse, PSScriptAnalyzer (errors only), Pester suite. Do not call the tests green until that run passes.
