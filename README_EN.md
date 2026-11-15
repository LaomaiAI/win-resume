# WinResume - Resume tasks automatically after a Windows Update reboot

One-line pain point: an overnight agent task killed by a forced Windows Update reboot, and all you find in the morning is the login screen.
Install: run `install.ps1` as Administrator, then edit `tasks.json` and enable the tasks you want resumed.

## What it does

WinResume is a small tool. After Windows Update reboots your PC, it re-runs your preset commands when you log on.
It does not block updates, change update settings, install drivers, or touch the network. It does one thing: resume unfinished tasks after the reboot.

## Why this exists

Evidence: on 2026-11-14, a V2EX hot thread (https://v2ex.com/t/1257008) described exactly this: the author set up an overnight AI agent task, woke up to a forced Windows Update reboot, and found only the login screen. Dozens of replies describe the same experience.
The gap: every existing answer is "prevent the reboot": WUB (one-click update blocker), Group Policy, LTSC, switching OS. And prevention does not even hold: Home edition has no Group Policy, and registry tweaks get quietly reverted by patches. No tool does "resume after the reboot".
The new approach: stop fighting the update. Accept the reboot, keep the task list, and auto-resume afterwards.

## How it decides

At logon, WinResume reads the Windows System event log and checks who initiated the last restart:
- The last restart is Event ID 1074 (User32), initiated by a Windows Update or servicing component (wuauclt.exe, USOClient.exe, MoUsoCoreWorker.exe, TrustedInstaller.exe), or by svchost.exe with the planned update reason code 0x80020010: that counts as an update-triggered reboot, and the resume starts.
- If the last shutdown was unexpected (Event ID 41 or 6008, crash or power loss), it does not resume: the last boot followed a crash, not a planned restart.
- A normal boot or a manual restart does nothing except write one log line and exit.
- Each boot session is processed at most once: the same boot never resumes twice.
- Details and sources: see NOTES.md.

## Install

Requirements: Windows 10 or Windows 11, PowerShell 5.1 (built in).
1. Put this folder where you want to keep it. Do not move it after installing; moving it means reinstalling.
2. Right-click `install.ps1` and choose "Run with PowerShell". Registering a scheduled task needs Administrator rights; the script re-launches itself elevated when needed.
3. It registers a scheduled task named WinResume that runs `resume.ps1` at your logon. The task runs as your own account, with normal (non-elevated) rights.
4. If `tasks.json` does not exist yet, install copies it from `tasks.example.json`.

## Configure your tasks

Edit `tasks.json`:
```json
{
  "version": 1,
  "tasks": [
    {
      "name": "my-agent",
      "command": "C:\\Tools\\my-agent\\agent.exe",
      "arguments": "--resume",
      "workingDirectory": "C:\\Tools\\my-agent",
      "enabled": true
    }
  ]
}
```
- name: task name, used in logs only.
- command: full path to the executable.
- arguments: passed to the program verbatim; quote paths with spaces yourself. May be empty.
- workingDirectory: the working directory the program starts in. It must exist; a task whose directory is missing is skipped and logged.
- enabled: only tasks set to true are resumed.
- Note: a .ps1 script cannot be the command directly. Set command to powershell.exe and arguments to `-File "C:\\path\\to\\script.ps1"`.
- v1 does not restore agent context: the command is re-run from scratch, not resumed mid-conversation. If your agent supports it, pass its own resume flag in arguments.

## Uninstall

Run `install.ps1 -Uninstall` as Administrator to remove the scheduled task. Log and state files under `%LOCALAPPDATA%\WinResume` are left in place; delete them by hand if you want.

## Logs and notifications

- Log: `%LOCALAPPDATA%\WinResume\win-resume.log`. Every logon writes one line with the decision; a resume writes one line per task.
- State: `%LOCALAPPDATA%\WinResume\state.json`. It only records the last processed boot time and decision, so the same boot is never resumed twice.
- Notification: after a resume, one Windows notification appears (a system toast first; if the toast cannot show, a small popup that closes itself). The notification is only a reminder. If it fails to show, the resume still happened, and the log always has the record.

## What v1 does NOT do

- It does not restore an agent's conversation context. It only re-runs commands.
- It does not block or delay Windows Update.
- It does not run before anyone logs on: the trigger is logon, not startup. If the PC reboots and sits at the lock screen, the resume waits until you log on.
- It does not know how far the last task had progressed. It only knows the last reboot was update-triggered.
- A power off (as opposed to a restart) does not trigger a resume.
- On localized Windows, the shutdown-type text is localized. v1 only accepts "restart" and the Chinese "重新启动". Anything unrecognized means no resume: better to skip once than to resume wrongly.

## Deterministic by design

This tool is 100% code. No LLM anywhere, no network requests, no accounts, no cloud. The decision rule is fixed event-log logic: same input, same output. Tests live in `tests/` (Pester) and run on every push in GitHub Actions on Windows.

## License

MIT License, see the LICENSE file.
