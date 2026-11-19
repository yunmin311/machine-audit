# Stage 15 · 残留净化复查

## 目的
清点指向不存在目标或长期停用的幽灵层，产出 R 系列清单（编号/类别/明细/权限档/动作）。**本阶段严格只读，不执行删除**——升级动作走 `references/execution-safety.md`。

## 子检查（每项独立出清单）

### 15.1 死快捷方式（双桌面必查）
- 现象：开启过又关闭 OneDrive KFM 时，机器同时存在 `<用户>\Desktop` 与 `<用户>\OneDrive\Desktop`，仅用 `[Environment]::GetFolderPath("Desktop")` 会漏扫另一份或修错桌面。
- 判据：先读注册表 `User Shell Folders\Desktop` 确定当前生效桌面，再全扫「用户生效桌面 + 另一份 Desktop（若存在）+ 公共桌面 `C:\Users\Public\Desktop`」及用户/公共开始菜单；`.TargetPath` 非空且 `Test-Path` 为 `$false` 判为死快捷方式（UWP 目标空者跳过）；修/建快捷方式必须三处同步并标清生效路径。
- 命令：`$curDesk = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders').Desktop`；COM `(New-Object -ComObject WScript.Shell).CreateShortcut($lnk.FullName).TargetPath`

### 15.2 – 15.6 死项扫描
- **15.2 死服务**：解析 `Win32_Service.PathName`（带引号取首段引号内；不带引号按 ` -`/` /`/` --` 切首段）；裸名（如 `wscript.exe`）先试 `Get-Command` 再 `Test-Path` 防误报。
- **15.3 死自启与卸载条目**：Run 键（HKCU/HKLM）同上解析；卸载表三键 `UninstallString` 过滤 `msiexec`；附「新位置是否存在」列，防把搬家软件当残留。
- **15.4 死计划任务**：`Get-ScheduledTask` 的 `Actions.Execute` 展开环境变量后两步法检查（系统目录任务放行）。
- **15.5 空壳、伪空壳与孤儿目录**：① 零文件且零子目录单列空壳表；② **伪空壳（Agent 会话空壳）**：目录（尤其盘根 `YYYY-MM-DD-HH-mm-ss` 纯时间戳目录）无任何业务文件，仅含 `.workbuddy/`、`.claude/`、`.codex/`、`.reasonix/`、`.smart-env/` 元数据且合计 `<64 KB`——不得误当真实工作区保留，须单列候选并提示检查客户端默认工作区配置以治本（避免边删边生）；③ Program Files / 用户安装区 / 数据盘 APP 区用卸载表 `DisplayName` 做包含匹配，无匹配者**只列候选不判死**（游戏库/数据目录常无卸载条目），处置交用户。
- **15.6 死防火墙规则**：收录阶段 7 筛选出的非系统路径失效 `Program` 入站 Allow 规则（管理员档）；另有命名含 `\r`/`\n`/控制字符或尾随空格/点号的畸形目录（如末尾带 `\r`），常规删改常失败，须用 `\\?\` 前缀处置。

### 15.7 权限残留：拒绝型 ACL
- 现象：用户可见文件却无法删改（提示需来自自身权限），主因是历史工具在根目录写下显式 `Deny` 并向下继承；由于 `Deny` 优先级高于 `Allow`，用 `/grant` 加权无法解决且脚本易误判"文件被占用"。
- 判据：`Access` 中存在显式 `Deny`（主体为 `Everyone`/本机账户且含 `Delete`/`Write`/`DeleteSubdirectoriesAndFiles`）→ R 项（管理员档）；若为 `*SandboxUsers` 仅含只读保护则仅标推测**不替用户决定**；`System Volume Information` 卷影属系统设计勿动；**禁止用 `icacls /grant` 覆盖（必须先移除 Deny）**；批准处置后须在目录内新建并删除临时文件实测通过才算关闭。
- 命令（只读检测；批准后管理员先轻后重：`icacls "<p>" /remove:d "Everyone"` / `"<域\用户名>"`，或 `takeown /f "<p>" /r /d y` + `icacls "<p>" /reset /t /c /q`）：
```powershell
Get-Acl -LiteralPath $path | Select-Object Owner,@{n='DenyCount';e={@($_.Access | Where-Object AccessControlType -eq 'Deny').Count}}
```

### 15.8 零使用服务与常驻软件
- 现象：服务自启正常、进程占用私有内存并监听端口，或伴随防火墙放行与官方示例库，但业务侧早已停用，传统死服务与孤儿检查均无法命中。
- 判据（以下四重证据**至少三条成立**才定性候选，且须查 `Get-ScheduledTask` 排除定时批处理）：① `Get-NetTCPConnection -LocalPort <端口>` 只有 `Listen` 无 `Established`；② 应用 `.err`/`.log` 自启动后停在 ready 无查询/连接；③ 写入型日志（如 binlog/access.log）仅空轮转无新写入；④ 代码项目搜索连接串/端口/驱动零引用（排除 `node_modules` 与打包产物）；数据目录仅剩官方示例库（如 `sakila`/`world`/`postgres` 模板库）且长期无真实写入则强化"教学/试用遗留"判定。报告必列**私有提交** `PrivateMemorySize64`、分离的**程序/数据目录**与**监听/防火墙暴露面**；处置分三档（停服改手动 → 收紧绑定 `127.0.0.1`/删放行 → 卸载删目录归档）。
- 命令（以 `OwningProcess` 准确定位嵌套子服务真实进程，卸载时 MSI `3010` 退出码代表需重启非失败）：
```powershell
Get-NetTCPConnection -State Listen -EA SilentlyContinue | Where-Object LocalAddress -notin '127.0.0.1','::1' | Select-Object LocalAddress,LocalPort,OwningProcess,@{n='Proc';e={(Get-Process -Id $_.OwningProcess -EA SilentlyContinue).ProcessName}},@{n='PrivateMB';e={[math]::Round((Get-Process -Id $_.OwningProcess -EA SilentlyContinue).PrivateMemorySize64/1MB,1)}}
```

## 输出与坑
`## 残留专项`：R 表（编号/类别/数量/明细/权限档/建议动作）+ 分类小计 + 与上轮 R 数 diff（建议默认挂起等拍板）。坑：UWP 目标空≠死；`InstallLocation` 常缺，以 `UninstallString` 为准；运行中软件变化属快照语义。
