# machine-audit

> **面向 AI 编码代理的可审计整机健康审查与治理循环技能包（Agent Skills 规范）**
> **Auditable Whole-Machine Health Audit & Governance Loop Skill for AI Coding Agents (Agent Skills Spec)**

`Version: v0.8.1` · `Baseline Schema: v1.1` · `License: MIT` · `Platform: Windows 10/11 (PowerShell 5.1+)` · `Stages: 19 (00–18)` · `Domain Packs: 62` · `Assertions: 89 (45 + 27 + 17)`

[中文文档](#中文文档) · [English Documentation](#english-documentation)

---

## 中文文档

### 1. 这是什么 & 它解决什么问题

`machine-audit` 是一套面向 AI 编码代理（Claude Code / Codex / ZCode / Gemini CLI / Cursor 等）的**整机健康治理循环技能包**。它不是"一键删掉几个缓存目录"的清理脚本，而是一套**可审计、可回看、严格分级授权**的机器治理工作流：

```text
事实与风险（只读） → 具体方案 → 预览与批准门 → 前提检查 → 分批执行与逐批验证 → 复核 diff → 长期维护循环
```

| 常见痛点 | 本技能的工程回答 |
|---|---|
| **机器当前到底什么状态？** | 19 个阶段（`00–17` 系统面 + `18` 记忆与文档卫生）的只读诊断，每项检查强制标注六态覆盖状态（完整 / 抽样 / 失败 / 权限不足 / 未检查 / 不适用），禁止采集失败静默当作正常 |
| **哪些可清、哪些绝对碰不得？** | 基于事实链的 Git 备份健康评分（`project-doctor.ps1`）+ 重要资产地图（`asset-map`），按五要素证据结构分级输出，重要文件默认只指向、不动作 |
| **改坏或误删怎么办？** | 设计了「预览产物 + 同盘隔离区（两段式 rename）+ `operations.jsonl` 幂等日志 + 逆序回退」规程；**注意：执行器与回滚脚本当前尚未实现（见 §6 诚实声明）** |
| **如何避免越用越乱、下次再失忆？** | Kernel/Instance 彻底分离（通用审计知识在包内，本机参数/阈值/基线在 `overlay.yaml` 与 `baseline-YYYYMMDD.json`）、运行时领域探索、结构化基线机械门（`baseline-check.ps1`）与阶段 18 文档寿命治理 |

---

### 2. 设计原则与包结构

1. **只读诊断，方案先行，分级授权**
   诊断阶段对被查对象零写入；有副作用的检查（写盘测速、加载 shell profile 执行用户代码）必须单独标注并先取得用户同意。任何修改/删除动作必须落在经过**具体方案**与**批次批准门**授权的批次内。
2. **语义模型驱动（反特征码过拟合）**
   不以硬编码软件清单猜测机器用途，而是用**可叠加角色原语**（生产 / 消费 / 承载 / 连接 / 治理）定权重，用**10 个子系统**（存储 / 安全 / 网络 / 计算 / 媒体 / 开发 / 同步 / 凭据 / 服务 / 桌面环境）定检查，每项发现拆为**五元组**（资产 / 健康 / 一致性 / 暴露 / 可恢复）。跨 OS 只需替换命令投影，不改语义。
3. **Kernel / Instance 严格分离（包内零个人路径）**
   技能包本体只包含通用方法论、Schema、模板与无状态工具脚本；所有与特定机器绑定的路径、阈值、排除名单、噪音基线与资产清单全部写入用户的 `overlay.yaml` 与 `baseline-YYYYMMDD.json`。**包内出现个人绝对路径即视为 Bug。**
4. **运行时探索与五要素分级**
   `references/domain-packs.md` 提供 62 条领域线索作为探索起点；遇到未知软件时由 Agent 现场联网核验规范（附来源与日期）。每条发现必须具备五要素（观察事实 / 可能影响 / 证据充分度 / 严重程度 / 适用规则），禁止用恐吓性大词逼迫审批。
5. **四类记录分离与事实链评分**
   「本轮事实 / 已确认正常 / 待处理问题 / 有依据的例外」严格分表保存、禁止自动转化；问题关闭必须**重测原证据条件**，检查失败或对象离线不得记为已修好。Git 备份评分严格沿用事实链：`远端可达 → 目标分支精确匹配（-ceq 区分大小写）→ 实时 SHA 比对 → 统一身份判定（拦截自指远端与本地上游 `.`）`，不被活跃度或文档分抵消。

#### 包内结构与开箱组件

```text
machine-audit/
├── SKILL.md                        # Agent 技能入口规范（v0.8.1，角色/铁律/门禁/速查）
├── README.md                       # 本说明文档（中英双语）
├── CHANGELOG.md                    # 版本变更记录
├── LICENSE                         # MIT 开源许可证
├── .gitignore                      # 排除本机私有产物（overlay/基线/报告）
├── assets/                         # 配置与基线权威模板（v0.8+ 齐备，勿自造结构）
│   ├── overlay.template.yaml       # 本机参数模板（18 顶层键）
│   ├── baseline.schema.json        # 基线 JSON Schema（v1.1，6 固定节 + meta + snapshots）
│   └── baseline.template.md        # 基线人读视图模板（不一致时以 JSON 为准）
├── references/                     # 全阶段操作规范与领域知识
│   ├── conventions.md              # 共通守则、PS5.1 陷阱规避与 §overlay 字段表
│   ├── domain-packs.md             # 62 条领域线索种子库
│   ├── execution-safety.md         # 两段式执行、预览、回退与三栏删除验收规程
│   ├── memory-hygiene.md           # Stage 18 记忆与文档五层寿命治理
│   └── stage-00 ~ stage-17         # 系统面 18 个阶段细则（stage-00-bootstrap.md ~ stage-17-media.md）
├── scripts/                        # PS 5.1 兼容只读工具集（全部 UTF-8 BOM）
│   ├── bootstrap-probe.ps1         # 首跑只读探测与 schema 1.1 基线生成器
│   ├── baseline-check.ps1          # 基线结构机械门（无 Test-Json 依赖，支持 -WarnPct/-CritPct）
│   ├── project-doctor.ps1          # Git 备份事实链巡检 v1.9（支持 -Baseline / -SaveBaseline）
│   ├── doc-hygiene.ps1             # Stage 18 Markdown 文档膨胀只读扫描
│   └── measure-space-delta.ps1     # 删除验收三栏空间增量测量器（FreeSpace + $Recycle.Bin）
├── tests/                          # 回归测试与负对照套件（PS 5.1 实跑 89 断言）
│   ├── test-backup-scoring.ps1     # doctor 备份评分反例与缓存/大小写回归（45 断言）
│   ├── test-baseline-schema.ps1    # 基线结构门正反例回归（27 断言）
│   └── test-agent-helpers.ps1      # bootstrap-probe 与 measure-space-delta 回归（17 断言）
└── docs/
    └── design/execution-safety.md  # 预览、隔离区、操作日志与空间增量完整设计书
```

| 脚本 | 核心能力 | 面向 Agent 的防踩坑特性 |
|---|---|---|
| `scripts/bootstrap-probe.ps1` | 只读探测 OS/权限/LanguageMode/KFM 云重定向/杀软进程/卷空间，并安全枚举指定目录生成 `baseline-YYYYMMDD.json` | 不传 `-Roots`/`-TopDirs` 绝不扫盘；PS 5.1 `EnumerateFileSystemInfos` 跳过 `ReparsePoint`；单目录默认 20 万文件上限截断并标 `partial`；失败显式记 `failed` |
| `scripts/baseline-check.ps1` | 机械校验基线 JSON 必填六节、带时区时间戳、数值型 `free_pct`、红线自洽、`owner_note` 与 `scan_status` | 不依赖 PS 6.1+ `Test-Json`；拦截 `files=0 && bytes>0` 假账目与 `scan_status=failed`；支持 `-WarnPct`/`-CritPct` 传入自定义阈值 |
| `scripts/project-doctor.ps1` | 扫描项目根目录下的 Git 仓库与非 Git 目录，按备份事实链输出 A/B/C/D/X 分级表、隐私检查与跨轮基线 diff | 15 秒进程级 `ls-remote` 超时；自指远端五种形态统一身份拦截；`-Baseline` 无快照时显式报「无基线，本轮不判趋势」；`-SaveBaseline` 仅补 `snapshots.doctor` |
| `scripts/doc-hygiene.ps1` | 只读统计各目录 `.md` 数量、体量、30/90 天陈旧率与最大行数，给出蒸馏/归档/退役建议 | 自动跳过 `node_modules` / `.git` / 构建产物目录；严格只读 |
| `scripts/measure-space-delta.ps1` | 在删除/清理批前后分别采样卷 `FreeSpace` 与 `$Recycle.Bin` 体量，输出三栏账目与判定 | 用单引号保护 `'$Recycle.Bin'` 避免 `$Recycle` 变量展开；检测跨用户 SID `Access Denied` 受限；自动判出「未释放，空间在回收站」假成功 |

---

### 3. 19 个审计阶段全览

| # | 阶段 | 核心检查内容 | 对应文档 |
|---|---|---|---|
| 00 | Bootstrap | 环境与权限探测、角色/领域识别、生成 `overlay.yaml` 与首轮基线（首轮照常判当前风险） | `references/stage-00-bootstrap.md` |
| 01 | 硬件与固件 | 硬件型号、内存频率差值、磁盘固件与驱动过时检测 | `references/stage-01-hardware.md` |
| 02 | 磁盘空间账目 | 红线判定、系统盘根目录白名单、热点下钻、安装包识别、PS 5.1 安全枚举与增量口径 | `references/stage-02-disk.md` |
| 03 | 磁盘规则符合度 | 按可选 `rules_file` 校验前缀/冻结名单/快照超期；无规则时仅做通用命名观察 | `references/stage-03-rules.md` |
| 04 | 开发环境 | 运行时版本矩阵、PATH 失效检查、Git/代理身份与凭据台账（五要素定级） | `references/stage-04-dev-env.md` |
| 05 | 虚拟化 | WSL 登记与注册表一致性、VBox/Hyper-V/模拟器实体与 vhdx 体量 | `references/stage-05-virtualization.md` |
| 06 | 软件服务自启 diff | 卸载表、系统服务、自启项与计划任务相对基线的变化 | `references/stage-06-software-diff.md` |
| 07 | 安全态势 | Defender/AV 防护状态、防火墙暴露面、监听端口进程溯源、SMB 共享与远程面 | `references/stage-07-security.md` |
| 08 | 持久化与劫持 | IFEO、WMI 订阅、浏览器策略、PAC、第三方根证书与 AppInit_DLLs（条件化定级） | `references/stage-08-persistence.md` |
| 09 | 事件日志四查 | System 7 天错误、应用崩溃/.NET 堆栈、PSCore、与 `overlay.noise` 基线 diff | `references/stage-09-logs.md` |
| 10 | Agent 与 CLI 盘点 | AI Agent 数据目录矩阵（`agent_dirs_extra`）、凭据与同步通道交叉、沙箱账户核对 | `references/stage-10-agents.md` |
| 11 | 备份合规 | Git 同步事实链（`project-doctor.ps1`）+ 核心资产 3-2-1 评估与还原点检查 | `references/stage-11-backup.md` |
| 12 | 终端健康 | `pwsh`/Windows Terminal/cmd/Git Bash/VS Code 终端配置与启动健壮性 | `references/stage-12-terminals.md` |
| 13 | 报告与 diff | 两段式报告（技术段 + 人话段）、覆盖状态表、四类记录、关系链检查与双写 SHA256 校验 | `references/stage-13-report.md` |
| 14 | 性能基准（可选） | 只读基线采样；写盘压测默认关闭，须单独授权 | `references/stage-14-benchmark.md` |
| 15 | 残留净化复查 | 双桌面死快捷方式、死服务、死卸载/自启、空壳/孤儿目录、拒绝型 ACL、零使用服务四重证据 | `references/stage-15-residue.md` |
| 16 | 网络 / VPN / 远端 | 代理栈、组网安全位、WSL NAT/mirrored、手写配置文件（`overlay.configs`）漂移台账 | `references/stage-16-network.md` |
| 17 | 媒体 / 相册治理 | 原片完整性、3-2-1 冷备、catalog 代数、重复副本与检索层选型 | `references/stage-17-media.md` |
| 18 | 记忆与文档卫生 | L0–L4 五层寿命模型、15 轮/200 份硬触发、先蒸馏后退役、`doc-hygiene.ps1` 扫描 | `references/memory-hygiene.md` |

---

### 4. 安装与使用

#### 4.1 安装（跨工具标准技能目录）

```text
~/.agents/skills/machine-audit/
```

从公开仓库（`https://github.com/yunmin311/machine-audit`）克隆或复制发布包至上述目录（或所用 Agent 的 skills 目录）即可识别。**维护铁律**：修改只在源仓库进行，安装位仅作部署副本同步覆盖，禁止双头编辑。

#### 4.2 标准工作流命令（Windows PowerShell 5.1+）

```powershell
# 1. 首跑建档：自动探测环境与目标根目录，生成符合 schema 1.1 的基线 JSON 与 MD
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  "& '.\scripts\bootstrap-probe.ps1' -Roots @('D:\MyProjects') -OutDir 'D:\AuditOut' -WriteMarkdown"

# 2. 基线结构机械门（自定义阈值时传入 -WarnPct / -CritPct）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\baseline-check.ps1 `
  -Path D:\AuditOut\baseline-20261116.json -WarnPct 15 -CritPct 10

# 3. 写入首轮 Git 快照到同一份基线（避免次轮 -Baseline 报"无基线"）
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  "& '.\scripts\project-doctor.ps1' -Roots @('D:\MyProjects','E:\Code') -OutDir 'D:\AuditOut' -SaveBaseline 'D:\AuditOut\baseline-20261116.json'"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\baseline-check.ps1 -Path D:\AuditOut\baseline-20261116.json

# 4. 后续复核：带趋势 diff 运行 project-doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  "& '.\scripts\project-doctor.ps1' -Roots @('D:\MyProjects','E:\Code') -OutDir 'D:\AuditOut' -Baseline 'D:\AuditOut\baseline-20261116.json' -SaveBaseline 'D:\AuditOut\baseline-20261123.json'"

# 5. 文档卫生巡检（Stage 18）
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  "& '.\scripts\doc-hygiene.ps1' -Roots @('D:\MyProjects') -OutFile 'D:\AuditOut\hygiene.md'"
```

> **Agent 防踩坑提示**：
> - **PowerShell `-File` 数组参数陷阱**：在 `powershell.exe -File script.ps1 -Roots "A","B"` 模式下，只有第一个值 `"A"` 会绑定进 `[string[]]$Roots`，第二个值会被静默丢弃！传多个根目录必须使用 `-Command "& '...' -Roots @('A','B')"`。
> - **禁止 `System.IO.EnumerationOptions`**：该类型在 PowerShell 5.1（.NET 4.x）不存在；枚举目录请使用 `scripts/bootstrap-probe.ps1` 或 `references/stage-02-disk.md` 的 `EnumerateFileSystemInfos` 2 参实现。
> - **自然语言触发**：对 Agent 说「整机体检」「跑一遍 machine-audit」「电脑变卡了」「删这些之前先检查」「按计划清理」「复查 diff」即可按 `SKILL.md` 自动进入对应模式（`bootstrap` / `quick` / `full` / `execute` / `maintain`）。

---

### 5. 执行安全（含"尚未脚本化"显式声明）

```text
批准门之前：tree-before / tree-after / asset-map / rollback-manifest
            （tree-after = 改完之后的样子；asset-map = 重要文件位置图）
执行时：    删除类一律先移同盘隔离区（不真删，机器照常使用 = 真实预览）
            每动作先写 operations.jsonl（幂等重放、中断恢复、防重复操作）
宽限期：    隔离区保留 14 天 → 期满且你再次确认 → 才真正清空
            （以上为设计规程约束；执行器脚本与验收证据见 v0.9 路线图）
回退：      rollback 读日志逆序回放，每步校验哈希；回滚失败 ≠ 数据丢失
```

> **该机制尚未脚本化（`invoke-plan.ps1` / `rollback.ps1` 等执行器尚未实现）：以上为设计中的调用约定；当前需按 `references/execution-safety.md` 规程手工执行。**

- **已实现并有自动化验证的机制**：
  - 删除三栏空间增量验收工具（`scripts/measure-space-delta.ps1`）：在清理批前后采集并输出「逻辑释放 X GB / 实测释放 Y GB / 回收站 Z GB」，防止文件移入 `$Recycle.Bin` 后原路径消失造成的"假成功"。
  - 完整设计规范见 [`docs/design/execution-safety.md`](docs/design/execution-safety.md) 与 [`references/execution-safety.md`](references/execution-safety.md)。
- **尚未实现的自动化执行器（诚实声明）**：
  - `scripts/invoke-plan.ps1`（计划消费、隔离区移动、`operations.jsonl` 自动写回与指纹校验）**尚未实现**。
  - `scripts/rollback.ps1`（逆序回放与哈希校验回滚）**尚未实现**。
  - L2 树状预览生成器（`preview/<runid>/tree-before.md`、`tree-after.md`、`operations-preview.jsonl`）与 L3 隔离区 14 天宽限期自动到期管理**尚未实现**。

---

### 6. 兼容性、测试与已知限制

#### 6.1 平台兼容性

| 平台 / 场景 | 状态与说明 |
|---|---|
| **Windows 10 / 11（PowerShell 5.1+）** | ✅ 当前主线平台；全包 `.ps1` 以 UTF-8 BOM + PS 5.1 为最低公分母验证 |
| **杀软 / CLM / 云占位 / 乱码 / 超长路径** | 有显式降级、跳过属性（`ReparsePoint` / `RecallOnDataAccess`）与受限声明，无静默吞错 |
| **macOS / Linux** | 语义模型已跨平台通用；命令投影为 `v1.0` 路线 |

#### 6.2 自动化测试（89 条断言，PS 5.1 实跑）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test-backup-scoring.ps1   # doctor 评分：45 断言
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test-baseline-schema.ps1  # 基线结构门：27 断言（v0.8.0 为 17）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test-agent-helpers.ps1    # Agent 辅助脚本：17 断言
```

- `test-backup-scoring.ps1`（**45 断言**）：覆盖各类对抗性边界反例（无远端 / 远端已删 / `.gitignore` 唯一资产 / 远端回退 / 空远端 / 无上游 / 索引损坏 / `Main/main` 大小写并存 / 自指远端五种形态 / 本地 `.` 上游 / 陈旧缓存不降级）+ 健康对照 + 报告完整性 + 阈值自检；`try/finally` 自清理 `%TEMP%` 并断言无残留。
- `test-baseline-schema.ps1`（**27 断言**）：专测结构门自身——正例通过；`free_pct` 字符串、空 `owner_note`、缺节、无毫秒 `run_id`、`redline` 矛盾、非管理员无受限登记、`sampled=false && files=0 && bytes>0`、`scan_status=failed`、`partial && !sampled`、`-CritPct 20` 自定义阈值与缺失文件，全部必须 FAIL 且精准定位字段。
- `test-agent-helpers.ps1`（**17 断言**）：专测 `bootstrap-probe.ps1`（1MB + 空目录 + junction 跳过 + `MaxFilesPerDir` 截断标 `partial` + 缺失路径标 `failed` 并被门禁拒绝）与 `measure-space-delta.ps1`（快照、`QuarantineMode`、50MB 进回收站负对照判「未释放」、500MB 实增正对照判「已释放」、非法盘符）。

#### 6.3 已知限制与路线图

- **当前已知限制**：`project-doctor.ps1` 全局 `SilentlyContinue` 的错误吞噬限制已如实声明；`ls-remote` 采用 15s 进程级超时；两段式执行器（`invoke-plan.ps1` / `rollback.ps1`）、L2 预览生成器与宽限期管理**尚未脚本化**；仅支持 Windows（macOS/Linux 命令投影待写）；除阶段 00/02/11/13/18 配套脚本外，其余系统面阶段以规范引导人工/Agent 采样为主。
- **v0.8.1（当前）**：修复 `stage-02` PS 5.1 枚举兼容与显式 `failed`；去掉 `baseline-check.ps1` 恒真断言并新增 `scan_status` 与 `-WarnPct`/`-CritPct`；schema 升 `1.1`；补 `conventions.md §overlay 字段表` 与 `noise: []`；新增 `bootstrap-probe.ps1` 与 `measure-space-delta.ps1`；完善中英双语公开版文档结构；89 条断言全过（45 + 27 + 17）。
- **v0.9**：执行器脚本化（`invoke-plan.ps1` / `rollback.ps1`，当前尚未实现）、L2 预览生成器、隔离区宽限期管理、其余阶段的最小断言补齐。
- **v1.0**：macOS/Linux 命令投影、多场景执行回归、更多领域包。

---

### 7. 许可（License）

本项目采用 [MIT License](LICENSE) 开源许可。

---

## English Documentation

### 1. What It Is & Problems It Solves

`machine-audit` is an **auditable whole-machine health audit and governance loop skill** built for AI coding agents (Claude Code, Codex, ZCode, Gemini CLI, Cursor, etc.) following the Agent Skills specification. Rather than acting as a blind one-click cleaner, it enforces a verifiable engineering lifecycle:

```text
Facts & Risks (Read-Only) → Concrete Plan → Preview & Approval Gate → Precondition Check → Batched Execution & Per-Batch Verification → Re-check Diff → Maintenance Loop
```

| Core Question | How `machine-audit` Answers It |
|---|---|
| **What is the machine's true state?** | 19 stages (`00–17` OS/subsystem checks + `18` memory & document hygiene) with mandatory six-state coverage reporting (`full / sampled / failed / permission-denied / unchecked / n/a`)—collection failures are never silently reported as healthy |
| **What can be cleaned vs. untouched?** | Evidence-chain Git backup scoring (`project-doctor.ps1`) + an explicit `asset-map` for irreplaceable files, graded via a 5-field structure without executing unapproved changes |
| **What if a change breaks something?** | Specifies a two-phase execution model (preview artifacts, same-disk quarantine rename, `operations.jsonl` idempotent journal, reverse hash-verified rollback). **Note: automated executor and rollback scripts are not yet implemented (see Section 5)** |
| **How to avoid recurring entropy?** | Strict Kernel/Instance separation (`overlay.yaml` + `baseline-YYYYMMDD.json`), runtime domain exploration, mechanical baseline schema gating (`baseline-check.ps1`), and Stage 18 Markdown lifecycle management |

---

### 2. Design Principles & Package Layout

1. **Read-Only Diagnosis, Plan-First Approval**
   Diagnostic phases perform zero writes on audited targets. Side-effecting checks (disk write benchmarks, sourcing shell profiles) require explicit labeling and user consent. Every destructive or mutating action must belong to an approved batch in a concrete plan.
2. **Semantic Model over Static Signatures**
   Machines are modeled as composable **role primitives** (`production / consume / host / connect / govern`) driving subsystem weights across **10 subsystems** (`storage / security / network / compute / media / dev / sync / credentials / services / desktop`), with each finding decomposed into a **5-tuple** (`asset / health / consistency / exposure / recoverability`). Porting to another OS only swaps command projections, never semantics.
3. **Strict Kernel / Instance Separation**
   The package holds only generic audit knowledge, schemas, templates, and stateless helpers. Machine-specific paths, thresholds, exclusions, noise baselines, and asset inventories live exclusively in per-machine `overlay.yaml` and `baseline-*.json` files. **Any personal absolute path inside the package is treated as a bug.**
4. **Runtime Exploration & 5-Element Grading**
   `references/domain-packs.md` seeds 62 domain cues as exploration starting points; unfamiliar software triggers live web verification with cited sources and dates. Every finding records five elements (observed fact / potential impact / evidence strength / severity / applicable rule).
5. **Four Separated Record Types & Backup Fact Chain**
   *Current observations*, *verified normal*, *open issues*, and *justified exceptions* are stored separately without silent promotion. Closing an issue requires re-testing the original evidence condition. Git backup grading follows a strict fact chain (`reachable remote → exact case-sensitive target ref match via -ceq → live SHA comparison → unified repository identity check blocking self-referential remotes and local "." upstreams`), never offset by commit activity or README presence.

```text
machine-audit/
├── SKILL.md                        # Agent skill specification (v0.8.1: roles, iron rules, gates, cheat sheet)
├── README.md                       # Bilingual documentation (Chinese / English)
├── CHANGELOG.md                    # Release history
├── LICENSE                         # MIT License
├── .gitignore                      # Ignores per-machine private artifacts (overlay/baseline/reports)
├── assets/                         # Authoritative config & baseline templates (v0.8+)
│   ├── overlay.template.yaml       # Per-machine parameter template (18 top-level keys)
│   ├── baseline.schema.json        # Baseline JSON Schema (v1.1: 6 fixed sections + meta + snapshots)
│   └── baseline.template.md        # Human-readable baseline view (JSON is authoritative on mismatch)
├── references/                     # Stage SOPs & domain knowledge
│   ├── conventions.md              # Cross-stage guardrails, PS 5.1 traps & §overlay field reference
│   ├── domain-packs.md             # 62 domain cue seed packs
│   ├── execution-safety.md         # Two-phase execution, preview, rollback & 3-column deletion SOP
│   ├── memory-hygiene.md           # Stage 18 5-tier document lifecycle model
│   └── stage-00 ~ stage-17         # 18 system audit stage specifications (stage-00-bootstrap.md ~ stage-17-media.md)
├── scripts/                        # PS 5.1-compatible read-only helpers (UTF-8 with BOM)
│   ├── bootstrap-probe.ps1         # Read-only bootstrap collector producing schema-1.1 baseline JSON/MD
│   ├── baseline-check.ps1          # Mechanical baseline gate (PS 5.1 safe, no Test-Json, -WarnPct/-CritPct)
│   ├── project-doctor.ps1          # Git backup fact-chain auditor v1.9 (-Baseline / -SaveBaseline)
│   ├── doc-hygiene.ps1             # Read-only Stage 18 Markdown bloat & age scanner
│   └── measure-space-delta.ps1     # 3-column deletion space verifier (FreeSpace + $Recycle.Bin delta)
├── tests/                          # PS 5.1 regression & negative-control suites (89 assertions total)
│   ├── test-backup-scoring.ps1     # Adversarial backup-scoring counterexamples, cache invariance & case collision (45 assertions)
│   ├── test-baseline-schema.ps1    # Mechanical gate positive/negative controls (27 assertions)
│   └── test-agent-helpers.ps1      # bootstrap-probe & measure-space-delta verification (17 assertions)
└── docs/
    └── design/execution-safety.md  # Detailed design spec for previews, quarantine, journal & space accounting
```

| Script | Capabilities | Agent-Safety Guardrails |
|---|---|---|
| `scripts/bootstrap-probe.ps1` | Collects OS, admin privilege, `LanguageMode`, KFM redirection, AV processes, disk volumes, and bounded directory sizes into schema-1.1 `baseline-YYYYMMDD.json` | Refuses default full-disk scans (empty `top_dirs` if no `-Roots`/`-TopDirs` passed); uses PS 5.1-safe `EnumerateFileSystemInfos` skipping `ReparsePoint`; truncates at `-MaxFilesPerDir` (`partial`) and marks errors explicitly as `failed` |
| `scripts/baseline-check.ps1` | Validates required 6 sections, timezone-offset ISO timestamps, numeric `free_pct`, redline consistency, `owner_note`, and `scan_status` | No PS 6.1+ `Test-Json` dependency; rejects `sampled=false && files=0 && bytes>0` and `scan_status="failed"`; accepts `-WarnPct` and `-CritPct` from `overlay.yaml` |
| `scripts/project-doctor.ps1` | Audits Git repos and non-Git folders across target roots with A/B/C/D/X grading, email/secret checks, and baseline diffs | 15s process-level `ls-remote` timeout; detects 5 self-referential remote patterns; outputs explicit "no baseline" when snapshots are absent; `-SaveBaseline` updates only `snapshots.doctor` |
| `scripts/doc-hygiene.ps1` | Scans `.md` count, size, >30d/>90d age ratios, and max line counts per top directory with distill/archive/retire advice | Skips `node_modules`, `.git`, and build artifacts; strictly read-only |
| `scripts/measure-space-delta.ps1` | Snapshots `Win32_LogicalDisk.FreeSpace` and `$Recycle.Bin` before/after a cleanup batch and computes the 3-column verdict | Single-quotes `'$Recycle.Bin'` to prevent `$Recycle` variable expansion; detects cross-SID `Access Denied` restrictions; catches Recycle-Bin false successes |

---

### 3. The 19 Audit Stages (00–18)

| # | Stage | Scope | Reference |
|---|---|---|---|
| 00 | Bootstrap | Environment & privilege probe, role/domain detection, `overlay.yaml` & initial baseline (grades current risks on first run) | `references/stage-00-bootstrap.md` |
| 01 | Hardware & Firmware | Device model, RAM speed mismatch, disk firmware & outdated driver checks | `references/stage-01-hardware.md` |
| 02 | Disk Space Accounting | Redline checks, system root whitelist, hotspot drilldown, installer detection, PS 5.1 safe enumeration & incremental scans | `references/stage-02-disk.md` |
| 03 | Disk Rule Compliance | Validates naming/structure/snapshot retention against optional `rules_file`; advisory naming checks when unconfigured | `references/stage-03-rules.md` |
| 04 | Dev Environment | Runtime version matrix, PATH health, Git/proxy identity & credential inventory (5-element grading) | `references/stage-04-dev-env.md` |
| 05 | Virtualization | WSL registry vs `wsl -l -v` parity, VBox/Hyper-V/emulators & `.vhdx` footprint | `references/stage-05-virtualization.md` |
| 06 | Software & Autorun Diff | Uninstall entries, services, startup items & scheduled tasks diffed against baseline | `references/stage-06-software-diff.md` |
| 07 | Security Posture | Defender/AV status, firewall exposure, listening port process attribution, SMB shares & remote surfaces | `references/stage-07-security.md` |
| 08 | Persistence & Hijacking | IFEO, WMI subscriptions, browser policies, PAC, third-party root CAs & AppInit_DLLs (conditional grading) | `references/stage-08-persistence.md` |
| 09 | Event Log 4-Way Check | 7-day System errors, App crashes + `.NET Runtime` stacks, PSCore, diffed against `overlay.noise` | `references/stage-09-logs.md` |
| 10 | Agent & CLI Inventory | AI agent data footprint (`agent_dirs_extra`), credential-vs-sync overlap checks & sandbox accounts | `references/stage-10-agents.md` |
| 11 | Backup Compliance | Git sync fact chain (`project-doctor.ps1`) + 3-2-1 evaluation for `overlay.assets` & restore points | `references/stage-11-backup.md` |
| 12 | Terminal Health | `pwsh`, Windows Terminal, `cmd`, Git Bash & VS Code integrated terminal diagnostics | `references/stage-12-terminals.md` |
| 13 | Report & Baseline Diff | Two-part report (technical + plain-language), coverage matrix, 4-class records, cross-system chains & SHA256 mirror verification | `references/stage-13-report.md` |
| 14 | Benchmarks (Optional) | Read-only baseline metrics; write benchmarks disabled unless explicitly authorized | `references/stage-14-benchmark.md` |
| 15 | Residue Audit | Dual-Desktop dead shortcuts, dead services/uninstall/tasks, orphan/empty dirs, Deny ACLs & 4-evidence zero-use services | `references/stage-15-residue.md` |
| 16 | Network / VPN / Remotes | Proxy stack, mesh/VPN security bits, WSL NAT/mirrored & `overlay.configs` drift tracking | `references/stage-16-network.md` |
| 17 | Media & Photo Governance | RAW integrity, 3-2-1 cold backup, catalog generation tracking, duplicate copies & search layer sizing | `references/stage-17-media.md` |
| 18 | Memory & Doc Hygiene | 5-tier document lifespan (`L0–L4`), 15-turn / >200-file hard triggers, distill-before-retire & `doc-hygiene.ps1` | `references/memory-hygiene.md` |

---

### 4. Installation & Usage

#### 4.1 Installation

Clone `https://github.com/yunmin311/machine-audit` or copy the release package into the cross-agent standard skill folder:

```text
~/.agents/skills/machine-audit/
```

Always make edits in the source repository and re-sync the installed copy rather than maintaining divergent copies.

#### 4.2 Standard Workflow Commands (Windows PowerShell 5.1+)

```powershell
# 1. First-run bootstrap: collect environment + target roots into a schema-1.1 baseline
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  "& '.\scripts\bootstrap-probe.ps1' -Roots @('D:\MyProjects') -OutDir 'D:\AuditOut' -WriteMarkdown"

# 2. Validate baseline mechanically (pass -WarnPct / -CritPct when customized in overlay.yaml)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\baseline-check.ps1 `
  -Path D:\AuditOut\baseline-20261116.json -WarnPct 15 -CritPct 10

# 3. Seed initial snapshots.doctor into the baseline and re-validate
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  "& '.\scripts\project-doctor.ps1' -Roots @('D:\MyProjects','E:\Code') -OutDir 'D:\AuditOut' -SaveBaseline 'D:\AuditOut\baseline-20261116.json'"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\baseline-check.ps1 -Path D:\AuditOut\baseline-20261116.json

# 4. Subsequent runs: produce repo diff against prior baseline
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  "& '.\scripts\project-doctor.ps1' -Roots @('D:\MyProjects','E:\Code') -OutDir 'D:\AuditOut' -Baseline 'D:\AuditOut\baseline-20261116.json' -SaveBaseline 'D:\AuditOut\baseline-20261123.json'"

# 5. Stage 18 document hygiene check
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  "& '.\scripts\doc-hygiene.ps1' -Roots @('D:\MyProjects') -OutFile 'D:\AuditOut\hygiene.md'"
```

> **Agent Gotchas to Avoid**:
> - **PS 5.1 `-File` array parameter trap**: `powershell.exe -File script.ps1 -Roots "A","B"` binds only `"A"` and silently drops `"B"`. Always use `-Command "& '...' -Roots @('A','B')"` for multi-value `string[]` arguments.
> - **No `System.IO.EnumerationOptions` on PS 5.1**: That class does not exist in .NET Framework 4.x. Use `scripts/bootstrap-probe.ps1` or the 2-arg `EnumerateFileSystemInfos` loop documented in `references/stage-02-disk.md`.
> - **Natural-language triggers**: Prompts such as *"PC health check"*, *"run machine-audit"*, *"before-I-delete audit"*, *"apply the cleanup plan"*, or *"re-check after changes"* activate the corresponding mode (`bootstrap` / `quick` / `full` / `execute` / `maintain`).

---

### 5. Execution Safety & Honest Status

```text
Pre-approval:  tree-before / tree-after / asset-map / rollback-manifest
Execution:     Move deletions to same-disk quarantine first (never direct delete)
               Append operations.jsonl before each step (idempotent resume & replay)
Grace period:  14 days in quarantine → explicit second user confirmation → permanent purge
               (Design specification & SOP rules; executor automation pending v0.9)
Rollback:      rollback replays operations.jsonl in reverse with SHA256 verification
```

> **Not Yet Scripted (`invoke-plan.ps1` / `rollback.ps1` are not yet implemented): the flow above is a design & SOP contract currently executed manually per `references/execution-safety.md`.**

- **Implemented & Verified**:
  - **3-Column Deletion Space Verifier (`scripts/measure-space-delta.ps1`)**: Measures `FreeSpace` and `$Recycle.Bin` deltas before/after cleanup and prints `Logical X GB / Measured Free Δ Y GB / Recycle Bin Δ Z GB`, blocking false successes caused by Recycle-Bin retention.
  - Full design specification in [`docs/design/execution-safety.md`](docs/design/execution-safety.md) and operator SOP in [`references/execution-safety.md`](references/execution-safety.md).
- **Pending Implementation (Not Yet Scripted)**:
  - `scripts/invoke-plan.ps1` (automated plan consumption, quarantine moves, fingerprint checks & `operations.jsonl` journaling) — **not yet implemented**.
  - `scripts/rollback.ps1` (reverse journal replay & hash verification) — **not yet implemented**.
  - L2 preview generator (`preview/<runid>/tree-before.md`, `tree-after.md`, `operations-preview.jsonl`) and automated L3 14-day quarantine grace-period expiration management — **not yet implemented**.

---

### 6. Compatibility, Tests & Known Limitations

| Platform / Condition | Status |
|---|---|
| **Windows 10 / 11 (PowerShell 5.1+)** | ✅ Current primary platform (all `.ps1` scripts carry UTF-8 BOM and are verified on `powershell.exe` 5.1) |
| **AV / CLM / Cloud Placeholders / Mojibake / Long Paths** | Explicit degraded handling (`ReparsePoint` & `RecallOnDataAccess` skip, `restrictions` logging, no silent fallback) |
| **macOS / Linux** | Semantic model is cross-platform; OS command projections planned for `v1.0` |

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test-backup-scoring.ps1   # Git backup scoring: 45 assertions
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test-baseline-schema.ps1  # Baseline schema gate: 27 assertions (17 in v0.8.0)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test-agent-helpers.ps1    # Agent helpers: 17 assertions
```

- **`test-backup-scoring.ps1` (45 assertions)**: Covers adversarial backup-scoring counterexamples (missing remote, deleted remote, `.gitignore`-only sole asset, force-pushed/rolled-back remote, empty remote, missing upstream, corrupted index, case-colliding `Main/main` packed-refs, 5 self-referential remote forms, local `.` upstream, and stale-cache invariance) plus healthy controls, report integrity, and threshold self-checks, with `try/finally` `%TEMP%` cleanup assertions.
- **`test-baseline-schema.ps1` (27 assertions)**: Validates the mechanical gate itself—positive control plus negative controls for string `free_pct`, empty `owner_note`, missing sections, non-millisecond `run_id`, redline mismatch, non-admin without restrictions, `sampled=false && files=0 && bytes>0`, `scan_status="failed"` (`meta` and `top_dirs`), `scan_status="partial"` with `sampled=false`, custom `-CritPct 20`, and missing files.
- **`test-agent-helpers.ps1` (17 assertions)**: Verifies `bootstrap-probe.ps1` (1MB + empty dir + junction skipping, `MaxFilesPerDir` truncation → `partial`, missing path → `failed` rejected by `baseline-check.ps1`) and `measure-space-delta.ps1` (snapshot, `QuarantineMode`, 50MB Recycle-Bin trap negative control, 500MB release positive control, invalid drive handling).
- **Known Limitations & Roadmap**: `project-doctor.ps1` uses global `SilentlyContinue` (explicitly declared) and a 15s `ls-remote` timeout; `invoke-plan.ps1` / `rollback.ps1`, L2 preview generation, and quarantine grace-period automation are **not yet implemented** (targeted for `v0.9`); macOS/Linux command projections are targeted for `v1.0`.

---

### 7. License

Released under the [MIT License](LICENSE).
