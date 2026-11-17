---
name: machine-audit
description: >-
  整机治理循环（审查→报告→拍板→计划→分批执行→复核→维护）。Use when the user mentions
  整机审查 / 全机体检 / 跑一遍 doctor / 电脑变卡了 / 有没有垃圾残留 / 删东西前先检查 /
  帮我清理 / 二手验机 / 这台机器该怎么整理 / 按上次计划执行清理 / 复查一下改完的效果
  — or English: PC health check, disk audit, leftover cleanup, before-I-delete,
  apply the cleanup plan, re-check after changes. Works on any machine: explores
  at runtime instead of assuming machine type; diagnosis is read-only and mutations
  require an approved plan batch with before/after verification.
metadata:
  version: "0.9.0"
  category: "system-health"
  platforms: "windows (v1 roadmap: macOS/Linux)"
  scope: "diagnose-plan-execute-gated"
  languages: "zh,en"
---

# Machine Audit · 机器治理循环

```text
事实与风险(只读) → 具体方案(含预览) → 批准批次 → 前提校验 → 两段式隔离执行 → 复核 diff → 维护
```

## 1. 何时用 / 何时不用

**何时用（命中其一即可）**：
- 全机体检或首跑建档：摸清硬件/磁盘/环境/安全/备份基线，或持续做跨轮趋势 diff。
- 磁盘告急或性能变卡：定位大目录/安装包/冗余文档，或检查零使用后台服务。
- 改前安全检查与执行验收：删除/清理前出具体方案与三栏空间验收，执行后重验关闭问题。
- 二手验机/新机迁移/异常溯源：排查端口暴露、CLI 登录故障、持久化劫持、权限拒删。

**何时不用**：
- **一次性单命令问答**（如只查某进程 PID 或单文件语法），直接用系统命令更轻量。
- **要求绕过批准直接静默删文件/清目录/改系统配置**（违反方案先行与分级授权边界）。
- **要求实时流式入侵响应/取证或非 Windows 系统执行本包 PS1 脚本**（命令仅投影 Windows）。

## 2. 五条铁律（操作细节见 `references/conventions.md`）

1. **诊断只读与落盘隔离**：只查不改；写入仅限 `overlay.output_dir` 下的报告/基线/overlay。
2. **首轮定级与五要素证据**：明确的当前危险第一轮即报警，缺历史仅限趋势标"无基线"；发现须含事实/影响/证据/严重度/规则。
3. **受限与副作用如实声明**：遇无权限/AV/CLM/离线/云占位标"受限"不猜；会写盘、占带宽或执行 profile 的检查非只读，须先征得同意。
4. **自包含与零个人路径**：技能包内出现个人绝对路径即为缺陷；本机事实只进 `overlay.yaml` 与 `baseline-*.json`。
5. **先诊断、批内执行、重测关闭**：破坏性动作须在已批准方案批次内走隔离区；问题关闭必须重测原证据条件。

## 3. 阶段分层与路由表（唯一阶段总表见 `README.md`）

**三层执行范围**：**Tier 1 必查（6）** `00/02/04/07/11/13` · **Tier 2 按角色（7）** `05/06/09/10/15/16/17` · **Tier 3 触发（6）** `01/03/08/12/14/18`。
**模式约束**：`quick` 只跑 Tier 1；`full` 跑 Tier 1+2；Tier 3 仅当信号命中时按需展开；`bootstrap` 首跑建档+判风险；`execute` 按批执行；`maintain` 事件/周期维护。未知场景先查 `references/domain-packs.md` 线索再运行时联网核验（附来源与日期）。

| 用户信号（出现即按需加载对应文件） | 读哪份参考 / 调哪个脚本 |
|---|---|
| 首跑 / 建档 / 不知道这台机器承担什么角色 | `references/stage-00-bootstrap.md` + `assets/overlay.template.yaml` + `scripts/probe.ps1 -Action env` |
| 通用编码/路径/编码避坑或查 `overlay` 字段语义 | `references/conventions.md` |
| 认出机器所属行业/开发/创意/特殊场景信号 | `references/domain-packs.md` |
| 盘满了 / 空间去哪了 / 安装包太占空间 | `references/stage-02-disk.md` + `scripts/probe.ps1 -Action space` |
| 装了什么 / PATH 乱 / CLI 登录报错或身份异常 | `references/stage-04-dev-env.md` |
| 安全吗 / 防火墙端口暴露 / 陌生根证书 | `references/stage-07-security.md` |
| 开机莫名自启 / 怀疑被浏览器或任务劫持 | `references/stage-08-persistence.md` |
| 备份够不够 / 仓库同步是真是假 | `references/stage-11-backup.md` + `scripts/project-doctor.ps1` |
| 网络慢 / 代理黑洞 / VPN / 测三目标链路基线 | `references/stage-16-network.md` |
| 删不干净 / 死快捷方式 / 权限拒删 / 服务空跑 | `references/stage-15-residue.md` |
| 要动手删改 / 出批前预览 / 验空间真释放了 | `references/execution-safety.md` + `docs/design/execution-safety.md` + `scripts/probe.ps1 -Action delta` |
| 写报告 / 基线校验 / 与上一轮做结构 diff | `references/stage-13-report.md` + `assets/baseline.schema.json` + `scripts/baseline-check.ps1` |
| 文档或笔记爆炸 / 会话与工作日志膨胀 | `references/memory-hygiene.md` + `scripts/probe.ps1 -Action docs` |
| 虚拟机 / 模拟器 / 怀疑隐藏 WSL 或孤儿 vhdx | `references/stage-05-virtualization.md` |
| 查最近新装了什么软件、系统服务或自启变化 | `references/stage-06-software-diff.md` |
| 系统频繁出错 / 软件闪退查堆栈与噪音基线 | `references/stage-09-logs.md` |
| AI Agent 缓存占空间 / 沙箱账户 / 凭据进同步盘 | `references/stage-10-agents.md` |
| 硬件驱动固件 / 目录规则 / 终端崩溃 / 性能压测 / 照片原片 | `references/stage-01-hardware.md` / `stage-03-rules.md` / `stage-12-terminals.md` / `stage-14-benchmark.md` / `stage-17-media.md` |

> **脚本调用防踩坑**：PS 5.1 `-File` 会丢弃数组第二个值，多 `-Roots` 务必用 `powershell -Command "& '.\scripts\...' -Roots @('A','B')"`；回收站路径全程单引号 `'E:\$Recycle.Bin'`。

## 4. 输出形状与未脚本化边界

- **报告骨架**：技术段（snapshots 与权限档位 + 分阶段事实表 + 与上轮基线 diff + 分级问题/资产地图）+ 人话段（≤3 件当轮最该做的事）。完整模板与双写 SHA256 校验见 `references/stage-13-report.md`。
- **覆盖状态六态（每项检查必标其一）**：`完整检查` / `抽样` / `失败` / `权限不足` / `未检查` / `不适用`。
- **承诺格式（≤3 行）**：`截至 <时刻>，已完成 <范围清单与覆盖状态> 检查，发现 <分级问题>，未验证 <清单>；按批准方案处置后已取得 <复核证据>；出现 <触发条件> 时须重查。`
- **诚实声明**：`scripts/invoke-plan.ps1`、`scripts/rollback.ps1`、L2 树预览生成与 14 天隔离区自动宽限期管理**尚未脚本化/尚未实现**，当前严格按 `references/execution-safety.md` 手工执行并留存三栏实测证据。
