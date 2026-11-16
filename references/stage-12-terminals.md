# Stage 12 · 终端健康

## 目的
终端是 agent 与人的主入口，坏终端会伪装成"agent 有问题"。逐终端体检。

## 标准动作
1. **PowerShell 7**：无 profile 启动测试可直接做；**带 profile 的启动测试会执行用户 profile 里的任意代码（有副作用，需先取得同意或由用户本人运行）**——profile 相关错误优先从 `PowerShellCore/Operational` 日志离线取证；`PowerShellCore/Operational` 日志查 FailFast（已知 7.6.x 更新横幅 bug：`UpdatesNotification.ShowUpdateNotification` 在窄窗宿主 PadRight 负值崩溃——止血 `POWERSHELL_UPDATECHECK=Off`，根治等补丁）；执行策略三 scope。
2. **Windows Terminal**：`settings.json` 的 profiles 逐个验 commandline 存在性；默认 profile 指向。
3. **cmd**：HKCU/HKLM `Command Processor` 的 AutoRun 劫持检查。
4. **Git Bash**：`~/.bashrc/.bash_profile/.minttyrc` 与发行版原样 diff（自定义即潜在故障点，也即用户资产——只登记不评判）。
5. **VS Code 集成终端**：`terminal.integrated.defaultProfile.windows` 与 profiles 定义有效性。
6. **编码三坑**：PS1 无 BOM 被 GBK 误读；`wsl.exe` UTF-16；netsh 中文输出——都是"agent 在终端里看起来坏了"的高频假故障。

## 判定
- pwsh 崩溃堆栈指向 UpdatesNotification → 给止血命令（环境变量）+ 升级建议，不算环境问题。
- 终端配置全默认 = "干净"，不评"简陋"——技能不审美。
