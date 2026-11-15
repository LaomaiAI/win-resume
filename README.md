# WinResume - Windows 更新重启后自动续跑任务

仓库：https://github.com/LaomaiAI/win-resume

一句话痛点：通宵挂着的 agent 任务被 Windows 更新强制重启杀掉，一觉醒来只剩登录界面。
安装：以管理员身份运行 `install.ps1`，再编辑 `tasks.json` 启用要续跑的任务。

## 它是做什么的

WinResume 是一个小工具。你的 Windows 电脑被 Windows 更新重启之后，它在你登录时自动把预设的命令重新跑起来。
它不阻止更新、不改更新设置、不装驱动、不联网。它只做一件事：重启之后把没跑完的任务续起来。

## 为什么做它

证据：2026-11-14，V2EX 热榜帖 https://v2ex.com/t/1257008 。楼主睡前安排了一整晚的 agent 全自动任务，一觉醒来被 Windows 自动更新重启杀了，只剩登录界面。几十条回复全是同款遭遇。
缺口：现有的办法全是“防重启”：WUB（一键禁用更新）、组策略、换 LTSC、换系统。而且防也防不住：家庭版没有组策略，注册表改动会被系统补丁悄悄改回来。没有一个工具做“重启之后自动续跑”。
新做法：不跟更新较劲。接受重启，记下任务，重启后自动续跑。

## 它怎么判断

WinResume 在登录时读 Windows 系统事件日志，找最近一次重启是谁发起的：
- 最近一次重启是 Event ID 1074（User32），发起进程是 Windows 更新或系统维护组件（wuauclt.exe、USOClient.exe、MoUsoCoreWorker.exe、TrustedInstaller.exe），或者是 svchost.exe 配上计划更新原因码 0x80020010，就判定为更新引发的重启，开始续跑。
- 如果最近一次关机是非正常关机（Event ID 41 或 6008，崩溃或断电），就不续跑：上一次启动是崩溃之后的事，不是计划重启。
- 普通开机、手动重启，都不续跑，只写一行日志就退出。
- 每次启动只处理一次：同一个开机会话不会重复续跑。
- 细节与来源见 NOTES.md。

## 安装

要求：Windows 10 或 Windows 11，PowerShell 5.1（系统自带）。
1. 把这个文件夹放在你想长期放它的位置，安装后不要移动，移动了要重装。
2. 右键 `install.ps1`，选“使用 PowerShell 运行”。注册计划任务需要管理员权限，没有权限时脚本会自己请求提权。
3. 脚本会注册一个名叫 WinResume 的计划任务，在你登录时运行 `resume.ps1`。任务以你自己的账号、普通权限运行。
4. 安装时如果还没有 `tasks.json`，会从 `tasks.example.json` 复制一份。

## 配置任务

编辑 `tasks.json`：
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
- name：任务名字，只用来写日志。
- command：可执行文件的完整路径。
- arguments：原样传给程序的参数，有空格的路径自己加引号。留空也可以。
- workingDirectory：程序启动时的工作目录，必须存在，不存在就跳过这个任务并记日志。
- enabled：只有 true 的任务会被续跑。
- 注意：.ps1 脚本不能直接当 command，要写成 command 是 powershell.exe，arguments 是 `-File "C:\\path\\to\\script.ps1"`。
- v1 不恢复 agent 的上下文：命令是从头重跑，不是接着断点续聊。需要上下文恢复的 agent，请在命令里自己加续跑参数。

## 卸载

以管理员身份运行 `install.ps1 -Uninstall`，删除计划任务。`%LOCALAPPDATA%\WinResume` 下的日志和状态文件会留着，手动删掉即可。

## 日志与通知

- 日志：`%LOCALAPPDATA%\WinResume\win-resume.log`，每一次登录都会写一行判断结果，续跑时每个任务各写一行。
- 状态：`%LOCALAPPDATA%\WinResume\state.json`，只记录上一次处理过的开机时间与判断结果，防止同一次开机重复续跑。
- 通知：续跑成功后弹一次 Windows 通知（先试系统 toast，toast 出不来就用自动关闭的小弹窗）。通知只是提醒，出不来也不影响续跑，日志里永远有记录。

## v1 不做的事

- 不恢复 agent 的对话上下文，只重跑命令。
- 不阻止、不推迟 Windows 更新。
- 不在没人登录时跑：触发器是登录，不是开机。电脑重启后停在锁屏界面，续跑会等到你登录才发生。
- 不判断“上次任务跑到哪一步了”：它只知道上次重启是更新引发的。
- 关机（power off）而不是重启，不触发续跑。
- 中文系统上关机类型字段是本地化文字，只认 restart 和“重新启动”两种，认不出的不续跑，宁可少跑一次也不错跑一次。

## 确定性说明

这个工具是 100% 代码，没有用到任何大模型，没有网络请求，没有账号，没有云端。判断规则是写死的事件日志规则，输入相同、结果相同。测试见 `tests/`（Pester），每次推送都会在 GitHub Actions 的 Windows 环境里跑一遍。

## 许可证

MIT License，见 LICENSE 文件。
