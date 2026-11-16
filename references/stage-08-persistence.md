# Stage 08 · 持久化与劫持

## 目的
排查"不请自来但长期驻留"的机制。这是恶意/流氓软件最爱藏的位面，也是本技能的 P0 高产区。全部只读。

## 检查位面（autoruns 思想的 PowerShell 化）
1. **IFEO**：`HKLM:\...\Image File Execution Options` 逐键查 `Debugger` 值——任何非空 Debugger 都是劫持候选（安全软件自家的除外，需溯源）。
2. **Winlogon**：Shell / Userinit / Notify 键值与标准值 diff（`explorer.exe` / `userinit.exe,`）。
3. **WMI 订阅**：`root\subscription` 的 __EventFilter/__EventConsumer/__FilterToConsumerBinding 计数与内容——系统自带 SCM Event Log Filter 是基线；CommandLine/ActiveScript Consumer 出现即 P0 候选。
4. **浏览器策略**：HKLM/HKCU `Policies\Google\Chrome`、`Policies\Microsoft\Edge` 全值枚举——搜索引擎劫持/强制扩展/托管配置在此现形。
5. **系统代理**：`ProxyEnable/ProxyServer/AutoConfigURL`——PAC URL 指向非本机/非知名来源 = 劫持候选。
6. **根证书**：`Cert:\CurrentUser\Root` + `Cert:\LocalMachine\Root`，排除主流 CA 词表后逐个列出；第三方根证书（抓包工具/加速器/网吧类常装）= 高关注，溯源到安装它的软件并提示"该软件可解密你的全部 HTTPS"。
7. **计划任务 autoruns 位面**：非 MS 任务的 Action 指向用户 Temp/AppData/临时目录的 = 高关注。
8. **DLL 劫持温床**（轻量）：`HKLM:\...\Windows NT\CurrentVersion\Windows` 的 AppInit_DLLs 与 LoadAppInit_DLLs。

## 判定
- 新增（对照基线）IFEO Debugger / WMI Consumer / 可疑根证书 / Winlogon 改动 = **先定性、再定级**：溯源到已知安全软件或用户自装工具且在用 → P2 登记；无法溯源 → P0 候选。
- 浏览器策略存在但内容良性（如 LocalNetworkAccess 类）= 记基线。
- 第三方根证书但软件在用 = P2 登记（卸载软件时须同步删证书）。

## 坑
- 根证书排除词表不能当白名单用——新 CA 每年出现；词表只做粗筛，余量人工复核。
- WMI 基线：Windows 自带 SCM Event Log Filter/Consumer 一对，别当入侵报。
- 受管机的策略键可能由组织下发——先判受管（阶段 0），受管机的"劫持"可能是"管理"。
