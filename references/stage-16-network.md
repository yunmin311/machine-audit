# Stage 16 · 网络 / VPN / 远端与配置漂移

## 目的
网络层"为什么连不上/为什么慢/谁在监听/远端连着谁"，以及所有手写配置的漂移台账。

## 检查项
1. **代理栈**：代理进程实例数（多实例=经典黑洞故障）；TUN/TAP 网卡在位；`git config` 代理端口 vs 实际监听端口（错配 = git 远程操作失败的常见根因，定级见判定节）；被测端口的防火墙规则有无。
2. **VPN/组网**：Mesh VPN（ZeroTier/Tailscale 类）allowGlobal/allowDefault 安全位；遗留 TAP 网卡（驱动日期过老=残留）；hosts 的第三方标记行。
3. **远端资产台账**：`~/.ssh/known_hosts` 主机清单、ssh 密钥→用途映射（私钥文件名+pub 备注，不读内容）、git remotes 全量、同步工具设备对（Syncthing 等）、gh/远端 CLI 登录状态。
4. **DNS 路径**：系统 DNS / 代理 fake-ip / DoH 叠加关系；解析测试（已知域名 vs IP 直连）。
5. **WSL 网络**：NAT vs mirrored（mirrored 前 localhost 代理无效是已知陷阱）；WSL 内监听端口（`wsl -e ss -tlnp`）。
6. **配置漂移台账**：overlay `configs:` 登记的所有手写配置文件（git/npm/pip/clash/syncthing/ssh/agent 环境变量/.wslconfig）逐个 hash 或 mtime，与上轮 diff——**配置改动失忆是排障最大成本**。
7. **连通性抽样**：对用户声明的常用远端（git remote/服务器）做 TCP 探测（Test-NetConnection 端口级），失败项给分层定位（DNS→路由→代理→防火墙→对端）。

## 判定
- 配置漂移未登记的改动 = P2（补登记）；代理指向无监听端口 = P1（功能性故障，与 stage-04 口径一致）；穿透/共享工具 allowGlobal 类安全位打开 = P1。

## §8 链路基线（有副作用，须先征得同意）
- **副作用声明**：网络探测产生流量并占用带宽（同 stage-14 口径），须先向用户说明并取得同意；未同意仅标 `未检查`。
- **采样写入**：固定 3 个代表目标 × 3 次采样测 p50 延迟（`latency_p50_ms`）、丢包率（`loss_pct`）与 DNS 解析耗时（`dns_ms`），结果写入基线可选 `network` 节（`assets/baseline.schema.json` `1.2`），下轮同口径 diff。
- **中立报告**：只报 `"变了多少"`（相对上轮差值），不替用户判定 `"哪条更好"`——多目标权衡交用户。
- **命令**：`3` 次循环计 `[Net.Dns]::GetHostAddresses($h)` 耗时与 `Test-NetConnection -ComputerName $h -Port 443`，排序取中位数 `[1]` 写入 `baseline.network.targets`。
