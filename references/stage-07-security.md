# Stage 07 · 安全态势

## 目的
回答：这台机器当前的暴露面、防护状态、以及"正在发生的异常"。全部只读。

## 前置
受管机（域/MDM/EDR 进程探测命中）→ 报告头第一行声明"组织管理设备，本审查仅供参考"。杀软非 Defender → 各项以该 AV 为准并声明口径。

## 子检查（每项独立，受限可跳）

### 7.1 防护状态
`Get-MpComputerStatus | Select AMServiceEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanAge,FullScanAge`
判定：实时保护关 = P0；病毒库 >7 天 = P2；全盘扫描 >35 天 = P1（建议项）。威胁历史 `Get-MpThreatDetection`：新检出条目必须逐条定性（真威胁/软件误报）。

### 7.2 防火墙与暴露面
- 三 profile：`Get-NetFirewallProfile | Select Name,Enabled`（任一关闭 = P0 候选）。
- 入站 Allow 规则统计与死路径规则：`Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow | Get-NetFirewallApplicationFilter`——Program 非系统路径且 `Test-Path` 失败 = 死规则（残留信号，联动阶段 15）；**不用 netsh 文本解析**（locale 陷阱）。
- 监听端口：`Get-NetTCPConnection -State Listen`，排除 loopback，每个对外端口溯源到进程与安装来源；新增端口与基线 diff。
- 共享：`Get-SmbShare`（CIM，别用 `net share` 文本）；非默认共享逐个列名。
- 远程面：RDP（`fDenyTSConnections`）、UAC（EnableLUA）、SMB1。

### 7.3 持久化与劫持位面
- IFEO Debugger 值、Winlogon Shell/Userinit、WMI `root\subscription` 四类计数（系统自带 SCM Filter 属正常基线）。
- hosts：非注释行 diff（语义：第三方标记行/异常 IP 映射 = 劫持候选）。
- 浏览器策略键（HKLM/HKCU Policies）值枚举。
- 系统代理：ProxyEnable/ProxyServer/AutoConfigURL（PAC 劫持检查）。
- **根证书**：`Cert:\CurrentUser\Root` 与 LocalMachine 排除主流 CA 后逐个列出——第三方 CA（抓包工具/加速器/网吧类）= 高关注项，需溯源到安装它的软件。
- 事件日志四查（见阶段 9 的 System/Application 部分，本阶段只取安全相关 provider）。

### 7.4 网络身份
虚拟网卡清单（TUN/TAP/ZeroTier/Hyper-V/Host-Only）、DNS 解析路径（系统 DNS vs 代理 fake-ip）、WiFi 配置数量与加密类型（`netsh wlan show profiles` 仅作清单，安全参数用 `Get-SmbShare` 同理的 CIM 替代，文本解析标注 locale 风险）。

## 判定与输出（v0.6：条件化定级，每条发现带五要素）
- 每个子检查输出：事实表 + 覆盖状态 + 受限项列表。
- **条件化定级示例**：
  - 陌生根证书：事实=非主流 CA；影响=该 CA 可解密 HTTPS；证据=证书在册+ issuers 匹配；严重度=**先标"待确认"**——溯源到安装它的软件且该软件仍在用 → P2 登记；无法溯源 → P1；确认为用户自装的抓包工具且用户知情 → 记录即可。
  - 新对外监听端口：事实=新端口+进程名；影响=攻击面 +1；证据=netstat+进程映射；严重度=溯源到刚装的合法服务 → P2 登记；无法溯源或进程路径可疑 → P0 候选。
  - 实时保护关闭 / 确认恶意持久化 → 才是 P0。
- 已知噪音基线（overlay `noise`）：在基线内不算新发现，但数量突变（>2 倍）要报。

## 常见坑
- `Get-MpComputerStatus`/`Get-MpPreference` 在部分 AV 共存时行为不同——以实际返回为准，报错即标受限。
- 根证书排除名单不能写死（新 CA 会漏）——用"排除主流 CA 关键词 + 人工复核余量"两步法。
- 监听端口的进程可能是短暂存活的更新器——快照语义，标注采样时间。
