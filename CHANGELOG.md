# Changelog

> 倒序排列：最新在最上。`0.6.0` 与 `0.6.4` 两个版本号跳过未发布（改动并入相邻条目）。

## 1.0.1 — 2026-11-19（工作区总根防污染 · 伪空壳与同源远端分身识别 · 回收站快照）

针对真实长期使用中出现的"客户端在盘根反复生成时间戳空壳（如 `YYYY-MM-DD-HH-mm-ss` 内仅含 `2KB` `.workbuddy/memory`）、删除后积压回收站、多项目容器根一级散落文件与同源兄弟克隆目录、以及末尾控制字符/尾随空格异常目录名"完成只读探测增强与规范加固：

- **工作区总根边界与伪空壳规则 (`SKILL.md` · `references/`)**：
  - `references/conventions.md` 新增「工作区总根边界」：当工作目录为多项目总容器根（一级含 `>=2` 个 `.git` 子仓）时，禁止在总根新建散件/分身副本（`-fresh`/`-check`/`-v2`/`-gapfix`），隔离验证统一进对应仓 `.worktrees/` 或 `_scratch/`/`$env:TEMP`，禁止向纯时间戳空壳写 `.workbuddy/memory/`。
  - `references/stage-15-residue.md` / `stage-03-rules.md` / `stage-10-agents.md` / `stage-02-disk.md` 补全「Agent `<64KB` 伪空壳（`.workbuddy`/`.claude`/`.codex`/`.reasonix`）」「`\r`/`\n` 与尾随空格 `\\?\` 处置」「回收站积压检查（仍走铁律 5 独立批准）」及「客户端默认工作区设置溯源」规程。
- **总根卫生与伪空壳只读探测 (`scripts/probe.ps1`)**：`-Action space` 新增 `recycle_bin` 卷积压快照与 `hygiene_flags`（`timestamp-shell` / `agent-pseudo-empty-shell` / `weird-name` / `portfolio-loose-files`），并同步渲染进 `-WriteMarkdown` `§SpaceBreakdown`；扩展 `Get-WinLongSafePath` `\\?\` 对尾随空格/点号路径的保护，同时保护 `Resolve-WinCanonicalPath` 不截去尾随空格。
- **同源分身聚类与容器根巡检 (`scripts/project-doctor.ps1`)**：新增同源远端 URL 规范化分身聚类（兼容 SSH/HTTPS/本地 bare 仓）、`-fresh/-check/-v2/-gapfix` 后缀分身识别、非 git 目录下细分 `timestamp-shell` / `agent-empty-shell` / `weird-name`，以及多项目容器根一级散件清单 `## 同源分身与工作区卫生提示`（自动放行 `AGENTS.md` 等锚点文件）。
- **回归测试扩充 (`tests/`)**：`test-backup-scoring.ps1` 增至 `50` 条、`test-baseline-schema.ps1` `33` 条、`test-agent-helpers.ps1` 增至 `71` 条，全套共计 **`154`** 条全部通过。

## 1.0.0 — 2026-11-18（Windows 生产正式版 · E2E 全链路与离线盲测 8 场景全通过 · README 徽章定版）

完成 `v0.9.0 → v0.9.7` 全阶段重构与边界加固后的首个 Windows 生产正式版本（`19` 审计阶段、`62` 领域包、`18` 条声明式规则、`Schema v1.2`、`147` 条回归断言，GitHub Actions `windows-latest` 全绿）：

- **全链路验收通过**：外部隔离沙盒补齐 `E2E-1 ~ E2E-7`（两轮连续治理闭环 + Git `新出现/已消失/改善/恶化` 四态 diff、真实 `fsutil` 稀疏文件 10MB 实占 0B 估算与剪枝、`docs` 行数/年龄段触发、`dupes` 多副本与 `-TopDupesCount` 截断、`baseline-check` 自定义阈值与 `network` 校验、镜像双写 SHA256 一致/篡改告警、147/147 回归全绿）及离线 `8` 场景盲测全通（`0` 越权、`0` 假成功）。
- **术语与文档统一**：修正 `scripts/project-doctor.ps1` 第 24 行注释术语（`"新出现/已消失/升级/降级"` 对齐为脚本与 `stage-13-report.md` 实际输出的 `"新出现/已消失/改善/恶化/持平"`）；更新 `README.md` 为居中大标题 + Shields.io `flat-square` 徽章栏与实时 CI 状态徽章。
- **v1.0.0 诚实边界与后续路线图**：`v1.0.0` 为 Windows（PowerShell 5.1+）生产正式版；`invoke-plan.ps1` / `rollback.ps1` 执行器自动化、L2 预览生成器与 14 天隔离区自动宽限期管理当前仍按 `references/execution-safety.md` 人工批门与 `operations.jsonl` 规程执行（顺延至 `v1.1`），macOS / Linux 命令投影与一机多系统治理规范列入 `v2.0` 路线图。

## 0.9.7 — 2026-11-18（GitHub Actions `windows-latest` 实测修复：Windows 8.3 短路径规范化）

依据首次在 GitHub Actions `windows-latest`（`%TEMP%` 含 `RUNNER~1` 8.3 短路径名）跑通的云端 CI 日志定位并根治长短路径混用偏差：

- **8.3 短路径与长路径统一规范化 (`scripts/probe.ps1`)**：新增 `Resolve-WinCanonicalPath`（小于 240 字符的非 `\\?\` 路径经 `[IO.Path]::GetFullPath` 统一展开 8.3 短路径并去尾斜杠）；接入 `Measure-DirSafe`、`Invoke-SpaceAction`（`-Roots`/`-TopDirs`/`-StreamOut`/`-Resume` 键以及子树对账 `$rootMeta`）与 `Invoke-DupesAction`，消除传入 `RUNNER~1` 等 8.3 短路径时出现的 `-Resume` 缓存静默未命中与子树对账漏汇总问题。
- **测试夹具规范化与 8.3 回归 (`tests/test-agent-helpers.ps1`)**：初始化 `$WorkRoot` 后即规范化为完整长路径以兼容 `windows-latest` (`runneradmin`/`RUNNER~1`)，并新增 `Torture-9e`（实测传入 FSO 生成的 8.3 短路径执行 `space` 子树对账与 `-StreamOut/-Resume`）；全套断言增至 `47 + 33 + 67 = 147` 条。

## 0.9.6 — 2026-11-18（压测问题修复：`-Roots` 缺失/离线路径强制标 `failed` · `-OutDir` 方括号建目录安全）

针对黑盒边界压力测试 Case 7 暴露的路径口径不一致完成精准修复：

- **缺失 `-Roots` 与 `-TopDirs` 口径对齐 (`scripts/probe.ps1`)**：修复 `Invoke-SpaceAction` 中当 `-Roots` 传入不存在或离线路径时只记 `offline` restriction 却将 `meta.scan_status` 保持为 `"ok"` 从而绕过 `baseline-check.ps1` 的问题；现同步置 `$overallScanStatus = "failed"`、写入失败条目进 `top_dirs`，并用 `Get-WinLongSafePath` + `[IO.DirectoryInfo]` 处理根目录直属文件读取异常（权限受限显式记入 `partial`/restrictions 而非静默吞错）。
- **`-OutDir` 方括号目录创建保护 (`scripts/probe.ps1`)**：`env`/`space` 输出目录创建统一由 `New-Item -Path` 改用 `[IO.Directory]::CreateDirectory($OutDir)`，彻底消除 `[v1]` 等通配符路径创建异常。
- **回归测试补强 (`tests/test-agent-helpers.ps1`)**：新增 `Torture-9d`（3 条断言），覆盖缺失 `-Roots` 输出 `scan_status=failed` 且被 `baseline-check.ps1` 拒绝（exit `1`）以及 `[v1]` `-OutDir` 创建；全套断言增至 `47 + 33 + 66 = 146` 条。

## 0.9.5 — 2026-11-18（公开陷阱加固：通配符 `-LiteralPath` · `MAX_PATH` `\\?\` 兜底 · Torture 脏边界测试 · GitHub Actions CI）

针对 Windows / NTFS / PowerShell 5.1 公开高频故障场景完成轻量加固，不引入重型虚拟机也不膨胀包体积（公开脚本维持 `3` 个）：

- **通配符与括号路径防崩溃 (`scripts/project-doctor.ps1`)**：`-Roots` 与 `-OutDir` 中含 `[v1]`、`$` 或中文字符时，将 `Test-Path`、`Out-File`、`Export-Csv` 与目标报告校验全部切换为 `-LiteralPath`，创建输出目录改用 `[IO.Directory]::CreateDirectory($OutDir)`，消除 PowerShell 通配符误解析导致的路径找不到或导出失败。
- **超长路径 `MAX_PATH > 260` `\\?\` 兜底 (`scripts/probe.ps1`)**：新增共享 `Get-WinLongSafePath` 辅助函数（对长度 `>= 240` 的盘符路径自动补 `\\?\` 前缀）；在 `Measure-DirSafe`、`Invoke-DupesAction` 的目录枚举以及 `Get-FilePartialSha256`、`Get-FileFullSha256` 的文件读取路径启用 `\\?\` 兜底，避免未启用系统长路径策略时的 `PathTooLongException`。
- **第 9 节 Torture 脏边界测试集 (`tests/test-agent-helpers.ps1`)**：新增 `Torture-9a/9b/9c` 共 7 条断言——分别在无权限/无 OneDrive 环境下可控复现 `torture-[v1] $中文` 路径、`[IO.FileAttributes]::Offline` 云盘占位符零水合跳过与标记、`MAX_PATH > 260` 超长目录与跨深分支查重，并在 `finally` 中增加 `\\?\` 递归自清理。
- **云端自动回归 (`/.github/workflows/ci.yml`)**：新增轻量 GitHub Actions `windows-latest` CI 工作流（并在 `release/public-allowlist.txt` 纳入 `.github/`），每次 push / PR 自动在真实 Windows PowerShell 环境跑通全部 `143` 条回归断言；公开 `scripts/*.ps1` 仍保持 `3` 个。
- **基线门与测试通过**：全套测试升级至 `47 + 33 + 63 = 143` 条（`test-backup-scoring.ps1` `47` + `test-baseline-schema.ps1` `33` + `test-agent-helpers.ps1` `63`），全量通过且无临时目录残留。

## 0.9.4 — 2026-11-18（真机与沙盒对抗实测修复：直属大文件 · 无损续扫 · 硬链接/云盘校准 · 跨环境守则）

> 主线：依据真机全流程实跑与边缘沙盒对抗实验暴露出的具体缺陷逐一修补，确保口径诚实、边界自洽、跨 WSL2/Windows 顺手。

- Fixed (`scripts/probe.ps1 -Action space`): 根目录直属文件现随子目录树一并纳入 `age_size_matrix` 与 `top_large_files`（不再只入 `volume_reconciliation` 造成根内大文件漏报）；`-StreamOut` 现每目录写入 `dir_matrix`、`dir_large_files`、`stream_filters` 与 `allocated_bytes`，`-Resume` 时无损合并分桶与大文件，且检测到传入更宽松过滤条件（如 `-MinSizeMB` 调低）时自动绕过陈旧流缓存重扫（记入 `stream_cache_bypassed_count`），杜绝静默空表。
- Fixed (`scripts/probe.ps1 -Action rules|docs|dupes|env` / `assets/cleanup-rules.json`): `-Action rules` 多路径部分成功由全盘判 `failed` 改为 `partial` 并逐条输出 `path_details` 及基于稀疏/压缩检查的 `estimated_allocated_bytes`（优化 `dev-docker-wsl` 等 `.vhdx` 估算精度），补充 Yarn/Bun 双命令说明与数据盘回收站复核提示；`-Action docs` 跨重叠父子 `-Roots` 按全路径去重计数且跳过 `ReparsePoint`；`-Action dupes` 对含外部硬链接副本的组别自动输出 `recommended_keep_path` 并剔除单删不释盘的外链字节；`Get-FastScannerTools` 补充扫描运行中 `Everything`/`WizTree` 进程与注册表路径，并在 `drives[].note` 自动标示 Google Drive/WinFsp 等疑似云端虚拟共享盘防重复计容。
- Fixed (`scripts/project-doctor.ps1` / `references/execution-safety.md` / `references/stage-02-disk.md` / `references/stage-07-security.md` / `references/stage-11-backup.md` / `SKILL.md`): `project-doctor.ps1` 枚举目录与统计非 Git 文件均显式跳过 `ReparsePoint`，消除符号链接目录双倍计入；对齐 `execution-safety.md` 系统盘并发噪声（85% 自动化达标与 1% 人工复核说明）；`stage-07`/`11` 补充 SMB Share ACL vs NTFS 交叉对比、GUID/陌生根证书溯源命令与跟踪敏感文件（`SensHits > 0`）优先轮换秘钥/`git rm --cached` 处置边界；`SKILL.md` 新增跨 WSL2 调用 `powershell.exe` 防卡死/转义参数守则。
- Added (`docs/brand/*.svg` / `README.md` / `release/public-allowlist.txt`): 纳入优化版双主题矢量品牌标（顺时针透视渐深圆环 + 居中 `Δ` 核验棱镜）并在 `README.md` 顶部接入 `<picture>` 明暗自适应 Banner（设计脚本与提案草稿仅留私有仓，白名单仅发布纯文本 SVG）。
- Tested (`tests/test-backup-scoring.ps1` / `tests/test-agent-helpers.ps1`): 新增 `ReparsePoint` 跳过、根目录直属文件入矩阵、无损流式续扫与宽条件重扫绕过、多路径部分失败 `path_details`、`docs` 重叠根去重及外部硬链接推荐保留等 **7 条**回归断言（全包总计 **136** 断言 = `47 + 33 + 56`，PS 5.1 全过）。

## 0.9.3 — 2026-11-18（第 2 批：四级漏斗查重 · 结构化筛选 · 流式续扫 · 多场景规则扩展）

> 主线：补齐面向跨用户多样机器环境的高价值只读模块——四级漏斗只读查重（含 NTFS 硬链接与云占位防护）、结构化候选筛选、`-StreamOut`/`-Resume` 断点续扫、MFT 快速工具探测，以及更多常见开发/Windows 规则。

- Added (`scripts/probe.ps1 -Action dupes`): 新增第六动作 `-Action dupes` 实现四级漏斗只读查重：① 第 0 关跳过 0 字节、重解析点、`Offline`/`RecallOnDataAccess`/`RecallOnOpen` 云占位并应用 `-MinSizeMB`（默认 10MB）/ `-MinAgeDays` / `-IncludeExt` / `-ExcludeExt`；② 第 1 关按字节分组并调用 Win32 `GetFileInformationByHandle` 识别 NTFS `(VolumeSerial, FileIndex)` 硬链接，把同块硬链接单独归簇为 `hardlink_clusters`（`reclaimable_bytes=0`，绝不把 `pnpm store`/硬链接误判为重复）；③ 第 2 关仅读头 4KB + 尾 4KB 算局部 SHA256 淘汰伪碰撞；④ 第 3 关仅对极少碰撞组流式全文件 SHA256 确认并按 `allocated_bytes` 计真实可回收空间（默认 Top-50，含 `oldest_path`/`newest_path` 与重叠 `-Roots` 自动去重）。
- Added (`scripts/probe.ps1 -Action space|env` / `assets/baseline.schema.json`): `-Action space` 新增结构化筛选参数（仅作用于 `top_large_files` 候选，绝不扭曲 `top_dirs` 与 `age_size_matrix` 总账）及 `-StreamOut <jsonl>` / `-Resume` 每目录实时落盘与断点续扫；`-Action env` 与 `space` 顺带只读探测 `es.exe`/WizTree 并存入可选 `snapshots.fast_scanners`（保持 `1.2` schema 兼容）。
- Added (`assets/cleanup-rules.json` / `references/stage-02-disk.md` / `SKILL.md`): 声明式规则库由 14 条扩充至 **18 条**（新增 Yarn/Bun、Go `go-build`、Scoop 安装包缓存与 CrashDumps/Minidump，每条均带明确 `does_not_touch` 护栏）；`stage-02-disk.md` 与 `SKILL.md` 同步更新 `-Action dupes` 规程与开关。
- Tested (`tests/test-agent-helpers.ps1`): 新增 11 条断言（结构化筛选保真度、`-StreamOut`/`-Resume` 续扫、`dupes` 第 0/2/3 关漏斗逐级收敛计数、`mklink /H` NTFS 硬链接识别归 0、重叠根去重与缺失根拒扫保护；全包总计 **129** 断言 = `45 + 33 + 51`，PS 5.1 全过）。

## 0.9.2 — 2026-11-17（第 1 批：声明式清理规则库 · 单遍多维探测 · 预估/实际闭环）

> 主线：从 MangoDisk / TreeSize / SpaceSniffer 吸取高性价比工程机制落地为第 1 批改进——规则数据化、每条强约束 `does_not_touch` 排除边界、单遍遍历顺带产出 3×3 年龄×体量矩阵与 Win32 实占 Top-50 / `<Unknown>` 对账、以及预估与实际回收偏差闭环。

- Added (`assets/cleanup-rules.json` / `scripts/probe.ps1 -Action rules`): 新增 JSON 格式声明式清理候选规则库（14 条核心规则，PS 5.1 原生可解析、零硬编码本机路径），每条强制声明 `does_not_touch`（不碰什么）与 `execution_mode`（`native-command` / `quarantine` / `empty-recycle-bin`）；`probe.ps1` 新增第五动作 `-Action rules` 只读匹配本机路径、输出可回收估算与原生建议命令（如 `pnpm store prune`、`docker builder prune`）。
- Changed (`scripts/probe.ps1 -Action space` / `assets/baseline.schema.json`): 在原有单遍 `Measure-DirSafe` 循环内（零额外磁盘 IO）顺带产出 `age_size_matrix`（`LastWriteTime` 3×3 矩阵）、`top_large_files`（≥100MB Top-50，调用 Win32 `GetCompressedFileSizeW` 读取实际占盘 `allocated_bytes` 并标出稀疏文件与云占位）、以及 SpaceSniffer `<Unknown>` 同源的 `volume_reconciliation`（卷已用 vs 已枚举 `unaccounted_bytes`）；传 `-Baseline` 时写入可选 `snapshots.space` 并在 `-WriteMarkdown` 渲染 `§SpaceBreakdown`，现有 1.2 必填字段零改动。
- Updated (`references/stage-02-disk.md` / `stage-13-report.md` / `execution-safety.md` / `scripts/probe.ps1 -Action delta`): 阶段 02 接入规则库优先与多维排查；阶段 13 人话段新增百分比条形图（禁混入原始账目、禁跨采样比较）与「预估 vs 实际」闭环要求；`delta Compare` 输出 `estimated_vs_actual_diff_bytes` 与 `estimated_vs_actual_summary`。
- Tested (`tests/test-agent-helpers.ps1`): 新增 15 条回归与结构门校验断言（规则库不变式与边界检查、`-Action rules` 合成规则只读匹配、3×3 矩阵分桶、Top-N 实占字节、子树对账、`§SpaceBreakdown` MD 渲染、`baseline-check.ps1` 兼容性及 `delta` 预估偏差；全包总计 **118** 断言 = `45 + 33 + 40`，PS 5.1 全过）。

## 0.9.1 — 2026-11-17（路由表措辞修正）

- Fixed (`SKILL.md`): 路由表标题由「唯一阶段总表见 `README.md`」改为「完整阶段表在 `README.md`，供人阅读；agent 不必加载」。原措辞会让 agent 误以为必须加载这份 405 行的人类文档，与"默认路径窄"的设计相反。无功能变更、无字段变更。

## 0.9.0 — 2026-11-17（路由重构 · 判定精简 · 脚本 5→3 · CLI 与链路基线）

> 主线：减重复、加 Tier 1/2/3 分层与信号路由、剥离纯故事保留可运行判据、公开脚本 5 合 3 统一为 `scripts/probe.ps1`，并新增 CLI 登录三态体检与三目标链路基线。

- Refactored (`SKILL.md` / `README.md` / `assets/overlay.template.yaml`): `SKILL.md` 重写为「何时用/不用 · 五铁律 · Tier 1(6)/Tier 2(7)/Tier 3(6) 信号路由表 · 输出形状」；唯一 19 阶段全览表与断言总数收敛至 `README.md`，`overlay` 字段表收敛至 `references/conventions.md`（模板顶部去重直指权威表）。
- Refactored (`references/stage-02-disk.md` / `stage-15-residue.md` / `execution-safety.md` / `domain-packs.md` / `memory-hygiene.md`): 将故事型叙事剥离为「现象 / 判据 / 命令」三行格式，并将 62 条领域线索与文档寿命治理压缩为紧凑索引与规则表（判定条件与可运行命令零删减）。
- Changed (`scripts/probe.ps1`, 公开脚本 `5 → 3`): 新建 `scripts/probe.ps1`（`-Action env | space | docs | delta`），合并替代 `bootstrap-probe.ps1`、`doc-hygiene.ps1` 与 `measure-space-delta.ps1`；同步更新 `release/public-allowlist.txt` 与 `tests/test-agent-helpers.ps1`（全 4 动作实跑回归，25 断言）。
- Added (`references/stage-04-dev-env.md` / `stage-16-network.md` / `assets/baseline.schema.json` / `scripts/baseline-check.ps1`): 新增阶段 04 CLI 登录三态体检（`gh`/`git`/`npm`/`docker`/`ssh -T` 脱敏报告）与阶段 16 `§8` 链路基线（固定 3 目标 × 3 次 p50/丢包/DNS，仅报差值）；`baseline.schema.json` 升 `1.2`（加可选 `network` 节）并新增结构校验与正反例测试（共 103 断言 = 45 + 33 + 25，PS 5.1 全过）。

## 0.8.1 — 2026-11-16（PS 5.1 枚举兼容 · 结构门去恒真 · 公开版基线）

> 主线：消除 PS 5.1 枚举兼容隐患、移除 `baseline-check.ps1` 恒真断言、补齐 `overlay` 字段表与 Agent 只读辅助脚本，并完善公开版文档与发布白名单规范。

- Fixed [P0]: `references/stage-02-disk.md` §扫描方法 —— **修了什么**：将主枚举路径改为 PS 5.1 兼容的 `DirectoryInfo.EnumerateFileSystemInfos('*', [IO.SearchOption]::TopDirectoryOnly)` 迭代并显式跳过 `ReparsePoint`，异常显式输出 `status=failed`（`bytes/files=$null` 不返回 `0`），将 `System.IO.EnumerationOptions` 移入 `if ($PSVersionTable.PSVersion.Major -ge 7)` 加速分支，并补充「`files=0` 且目录非空时先怀疑采集失败」口径。**为什么**：`EnumerationOptions` 在 PS 5.1（.NET 4.x）直接抛"找不到类型"导致静默落成 `0` 字节。
- Fixed [P1]: `scripts/baseline-check.ps1` / `assets/baseline.schema.json` / `assets/baseline.template.md` / `references/stage-00-bootstrap.md` / `tests/test-baseline-schema.ps1` —— **修了什么**：删掉恒真断言 `files -ge 0`，替换为 `sampled=false && files=0 && bytes>0` 拒绝、可选 `scan_status`（`ok|partial|failed`，`failed` 整份不判 PASS、`partial` 必须 `sampled=true`）、`-WarnPct`/`-CritPct` 参数化（默认 `15`/`10`）；schema 升次版本 `1.0 → 1.1`（`owner_note` 进 `required`、`drives.id` 加 `$`、`scan_status` 入 schema 与模板）；`stage-00` 补充首轮 `project-doctor.ps1 -SaveBaseline` 指引；测试新增 10 条反例断言（共 27 条）。**为什么**：`files -ge 0` 恒真放过采集失败基线，且 schema 与校验器口径及自定义阈值未对齐。
- Fixed [P1]: `assets/overlay.template.yaml` / `references/conventions.md` / `references/stage-00-bootstrap.md`（及 `stage-03` / `07` / `09` / `10` / `11`）/ `SKILL.md` —— **修了什么**：`noise: {}` 改为 `noise: []` 与列表注释一致；在 `conventions.md` 新增 `## overlay 字段表` 覆盖全部 18 个顶层键与阶段别名；补齐 `rules_file` 可选磁盘规则说明并统一阶段内别名写法。**为什么**：模板类型自相矛盾且 `§overlay 字段表` 引用断链。
- Fixed [P1]: `references/`、`docs/design/execution-safety.md`、`doc-hygiene.ps1`、`scripts/project-doctor.ps1`、`CHANGELOG.md` —— **修了什么**：全面清理包内示例路径与内部叙事，统一替换为通用占位符并保留实测参考数量级。**为什么**：遵循 Kernel/Instance 分离原则，保证技能包自包含且可直接公开发布。
- Fixed [P2]: `README.md`、`SKILL.md`、`references/execution-safety.md`、`docs/design/execution-safety.md`、`references/memory-hygiene.md`、`assets/overlay.template.yaml` —— **修了什么**：将 `README.md` 重写为正式中英双语版并同步阶段数为 19、断言数为 89（45+27+17；v0.8.0 为 62）；移除「L1 清单预览（已实现）」误述；在所有 `invoke-plan.ps1`、`rollback.ps1`、`tree-before/tree-after`、`operations-preview.jsonl` 与宽限期管理出现处紧跟"尚未实现/尚未脚本化"显式标注。**验收命令**：`rg -n "rollback\.ps1|invoke-plan\.ps1" -A3` 逐处确认含未实现/待建/尚未脚本化提示。
- Added: `bootstrap-probe.ps1` / `measure-space-delta.ps1`（已于 `0.9.0` 合并至 `scripts/probe.ps1`）/ `tests/test-agent-helpers.ps1` / `LICENSE` —— **修了什么**：新增面向 Agent 的 PS 5.1 只读首跑基线采集器（跳过 ReparsePoint、按 `-MaxFilesPerDir` 限流、未传 `-Roots` 不全盘扫、异常显式标 `failed`）与删除三栏空间增量测量器（精确采样 `FreeSpace` 与单引号 `'$Recycle.Bin'` 增量，自动拦截回收站假成功）；补充 MIT 许可证并在 `SKILL.md` 新增 Agent 防踩坑速查（`-File` 数组传参陷阱等）。**验收命令**：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test-agent-helpers.ps1`（17 PASS / 0 FAIL）。

## 0.8.0 — 2026-11-16（基线可校验 · 模板齐备 · 删除验收改口径）

> 主线：把"每台机器自造结构、无法做 diff"这个根因堵掉；把"删了但空间没回来"这个假成功堵掉。

- Added: `assets/overlay.template.yaml` —— 带注释的本机参数模板，收敛散落在 13 个阶段文件里的 overlay 字段（roots / exclude / thresholds / quarantine / antivirus / domains / rules_file / baseline_current / noise / assets / configs / agent_dirs_extra）。此前 SKILL、stage-00/03/13 全篇引用 overlay，包里却无模板也无 schema。
- Added: `assets/baseline.schema.json` —— 基线六节唯一权威（Environment / Drives / TopDirs / Persona / Domains / Restrictions）+ `meta` + 可选 `snapshots`；`free_pct` 强类型、`sampled` 强制声明、`owner_note` 不许留空、非管理员必须登记受限。
- Added: `assets/baseline.template.md` —— 人读视图模板，明确"两者不一致以 JSON 为准并记为缺陷"。
- Added: `scripts/baseline-check.ps1` —— 基线机械校验，PS 5.1 可用（不依赖 `Test-Json`，那是 6.1+ 才有）；含 `free_pct` 与 `free/size` 自洽、`redline` 与阈值一致两条交叉校验。
- Added: `tests/test-baseline-schema.ps1` —— 17 断言专测结构门本身：正例必须过；`"16.9%"` 字符串、空 `owner_note`、缺节、`run_id` 缺毫秒、`redline` 矛盾、非管理员无受限登记、文件不存在，七类反例必须逐条 FAIL 且定位到字段。
- Added: `doctor -Baseline` / `-SaveBaseline`（v1.9）—— 读基线 `snapshots.doctor.repos` 出"新出现/已消失/改善/恶化/持平"；无基线或基线无快照时报告显式写「无基线，本轮不判趋势」；写回只补 `snapshots.doctor` 一段，不代造六节基线。
- Added: `execution-safety` 删除验收口径（references §删除的验收口径 + design §7）—— 删除走回收站时空间不释放，用"文件是否还在原位"验收会得到假成功；验收改为可用空间增量，报告固定「逻辑释放 / 实测释放 / 回收站」三栏，要求 `X ≈ Y + Z`（容差 1%）。
- Changed: `stage-00` 步骤 4–7 重写 —— 从模板复制 overlay、写 `baseline-*.json` + md 视图、必须跑 `baseline-check.ps1` 才算建档完成；新增「无基线时怎么办」三条排查。
- Changed: `stage-13` diff 规范改为按 schema 对位 —— 六节逐节比、`sampled=true` 之间只比量级不比数值、`free_bytes` 容差 1% / 目录体量容差 5%、git 层趋势必须走脚本。
- Changed: `stage-13` 归档节 —— 双写必须比 SHA256（不一致写进报告，不许静默）、镜像侧不放源码副本；证据入库前 strip（`*.sample` + 空 `hooks` 目录），验收口径是命令输出 0。
- Changed: `stage-15 §15.1` 范围扩到"全部桌面"——KFM 未重定向时可能同时存在两个 Desktop，只认 `User Shell Folders` 的值，三处都要扫、一起修。
- Fixed: `tests/test-backup-scoring.ps1` 自清理移入 `finally` 并加残留断言——原先在脚本最末行，中途异常就到不了。
- Fixed: `docs/design/execution-safety.md` §3 资产地图表的个人绝对路径改为占位符，并注明"下表是某机实例，要复制的是列名与口径"。
- Chore: 清理证据目录中的冗余 `*.sample` 钩子模板与空 `hooks` 目录；`.gitignore` 增 `**/*.sample` 与 `**/evidence/**/hooks/`，并补 `baseline-*.json`（含个人路径，绝不入库）。
- 教训: 趋势比较块一度被插在 `$gitRows` 赋值**之前**，导致本轮仓库集合为空、全部误报"已消失"——实测才抓到。**顺序错 = 静默算错**，这类代码必须跑一遍带基线的用例，不能只看语法通过。

## 0.7.1 — 2026-11-16（扫描方法与零使用软件识别）
- Added: `stage-02` §扫描方法——`du` 在含 `node_modules` symlink 的目录易陷入重复遍历；改用 `.NET` 安全枚举 + 跳过 `ReparsePoint`，附完整命令骨架与量级对比表。
- Added: `stage-02` §安装包/下载归档识别——三条判据（>100MB 文件占 80%、扩展名集中、名称含版本号/绿色版）+ "安装包 vs 程序本体"体量对比；并写明反面约束（不能只看目录名）。
- Added: `stage-02` §三条防误判——Windows 大小写不敏感（Test-Path 双拼写为真 ≠ 两个目录）、工作集 ≠ 内存（判内存看 `PrivateMemorySize64`）、空目录仍是目录（需单列空壳清单）。
- Added: `stage-15` §15.8 零使用服务/软件——四重证据（无 Established 连接 / 应用日志停在 ready / 写入型日志无新记录 / 项目侧零引用）、官方示例数据判据、三档处置；内存口径明确为私有提交而非工作集。
- Added: `execution-safety` §6 交接脚本可用性——提权必须 `-NoExit`（否则用户看不到结果，实测导致用户误判失败）、复核段必须进日志不能只 `Write-Host`、末尾留暂停、退出码语义表（3010/1605 不算失败）。

## 0.7.0 — 2026-11-07（记忆与文档卫生）
- Added: `references/memory-hygiene.md`（stage-18）——五层寿命模型（L0 会话 / L1 日志 30 天 / L2 报告 90 天 / L3 沉淀 / L4 草稿）、三种触发（15 轮或里程碑 / 目录 >200 份或单文件 >3000 行 / 每周周期）、三档动作（蒸馏 / 归档 / 退役）、写入闸门。
- Added: `doc-hygiene.ps1`（已于 `0.9.0` 合并至 `scripts/probe.ps1 -Action docs`）——只读扫描各目录 MD 数量与年龄分布，输出硬触发判定与三档建议。
- Changed: SKILL.md 阶段数 18 → 19；maintain 模式新增「记忆卫生是常驻子任务」条款；README 阶段表补 18。
- Fixed: CHANGELOG 条目倒序整理（此前 0.5.1 在顶、0.6.x 在底）。
- Rationale: 大量 Markdown 文档膨胀的主因是「每轮必写 / 只增不并 / 无退役」，属流程缺陷而非使用问题。清理只治标，写入闸门才治本。

## 0.6.6 — 2026-10-26（远端同步链收尾）
- Fixed [P1] 网络远端短路：删除 v1.7 引入的 external-url 类别——网络与本地独立目标共用同一条内容核验链（ls-remote 可达/分支存在/目标引用/SHA 比对），网络目标分支删除不再判健康；in-sync 评分只读实时值（缓存刷新不再改变等级，前后对照测试覆盖）。
- Fixed [P2] 测试 BOM：测试文件双 BOM 剥离（曾致参数失效）。
- Fixed [P2] 大小写负对照：packed-refs 构造 Main/main 并存用例；负对照实测撤销 `-ceq` 即 FAIL，恢复即全过。
- Fixed [P2] 缓存不变性测试重写：真实"push 经路径留陈旧缓存 → fetch 刷新"前后对比。
- Fixed: file URI 根斜杠（file:///tmp/x 此前被剥成相对路径；现按 URI 语义保留根，Windows 盘符路径仍正确剥前导斜杠）。
- Tests: fixture commit 补显式测试作者（无全局 git 作者配置的机器上不再失败）；44 断言全过。

## 0.6.5 — 2026-10-26（自指远端与实时差异）
- Fixed [P1] 自指地址四种形态（./ .git ../name file:///…）：目标身份解析收敛为统一算法——所有本地形态解析为绝对路径后与自身 git-common-dir 比较（按平台大小写语义），命中 → 类别 self → D；身份无法确认 → 类别 identity-unknown → 封顶 C（不得健康）。
- Fixed [P2] 路径比较按平台大小写语义（Windows -ieq / 类 Unix -ceq）——修复独立仓大小写变体在 Linux 被误判 self 的误报。
- Fixed [P2] 实时差异结构化：AheadLive/BehindLive（实时 SHA 比对）与 CachedAhead/CachedBehind（status 缓存）分列；external-in-sync 的同步分不再读取缓存。
- Fixed [P2] 修复测试断言括号解析缺陷与缓存不变性测试。
- Fixed: doctor 头部 v1.7、SKILL 0.6.5、README 阶段计数 18。

## 0.6.3 — 2026-10-25（引用大小写与本地上游）
- Fixed [P1] 引用比较大小写：目标匹配改用 -ceq（git 引用大小写敏感，PS -eq 默认忽略大小写导致 Main/main 互替）。
- Fixed [P1] 本地上游：branch.<name>.remote = "." （上游指向本仓库）单独定类——分支间一致不构成独立同步副本，记 D 缺口"上游指向本仓库（.）"。
- Fixed [P2] 报告事实来源统一：Remote 列改为展示实际核验的远端名+脱敏地址（git remote get-url），多远端标注"另有 N 个未核验远端"；领先/落后改为实时 SHA 比对值（rev-list），无法计算标未知。
- Fixed: 健康对照 fixture 改为克隆（带跟踪的正常同步仓）；23 断言全过。

## 0.6.2 — 2026-10-25（上游目标精确匹配）
- Fixed [P1] 上游目标改按 git 官方定义解析（branch.<name>.remote + merge，不再假设本地与远端同名）；目标引用整名精确比较（refs/heads/main 不命中 main-extra）；目标引用缺失 → D 风险，不再落入健康分支。
- Fixed [P1] 无上游措辞：不再捏造"未发布 N 个"——改为与核验到的远端 SHA 实际比对：一致→"上游未设置（内容一致）"，不同→"领先 X / 落后 Y（需 fetch 核对）"，无法比对→"未知"。
- Fixed [P2] Git 主表从 Markdown 恢复；CSV 远端列恢复填充；主表新增"目标引用/备份缺口"列。
- Fixed [P1] 旧指令六处清除（stage-00 判级、stage-04/16 代理 P0、stage-08 先定性、stage-11 资产级判断、README 三处）。
- Tests: 23 断言全过（18 阶段指南 + 62 领域线索不变）。

## 0.6.1 — 2026-10-25（远端内容核验升级）
- Fixed [P1]: 远端核验从"连接成功"升级为"内容同步"——ls-remote --heads --exit-code（15s 进程级超时）获取实时分支 SHA，与本地 HEAD 比对。
- Fixed [P1]: git 状态读取失败（如索引损坏）不再当作干净——status 退出码检查，失败即 D 风险 + 缺口"读取失败"。
- Fixed [P1]: 无上游 + 未发布提交不再按 ahead=0 奖励。
- Fixed [P1]: 非 origin 远端名（upstream 等）正确核验。
- Fixed: gitignore 忽略项计数并展示（专用 --ignored 调用）。
- Added: conventions 副作用/隐私节（只读按实际副作用判断；远端 URL 脱敏；待审数据原则）；范围声明入报告头。
- 已知限制：doctor 全局 SilentlyContinue 仅声明未根除；多远端只核验跟踪远端；跨平台投影未写；多场景执行回归为 v1.0 计划。

## 0.5.1 — 2026-10-25
- Fixed: removed personal-path defaults from scripts/project-doctor.ps1 (Roots now defaults to current directory; meta-dir rule generalized) — Kernel/Instance separation restored.
- Tested: residue-scan method verified with and without parameters; environment-probe commands validated on Windows 11 Home, PS 5.1, non-admin.
- Added: README.md.

## 0.5.0 — 2026-10-25
- Semantic refactor: machine = composable role set; checks decomposed into five-tuple semantics (asset/health/consistency/exposure/recoverability); 15 stages are the Windows projection.
- Full lifecycle: audit → report → approval gate → plan → batched execution with verification → re-check → maintenance. New modes: execute, maintain. Read-only is now a phase behavior, not the skill identity.
- Runtime exploration promoted to first-class: unknown software → web research with sources and dates; patterns written back to overlay. domain-packs repositioned as seed-hint library.

## 0.4.0 — 2026-10-24
- Domain packs (35): developer/creative/industry/consumer/scenario groups with detection signals, specialized checks, weights.
- Bilingual triggers in description; metadata block (version/category/platforms/scope/languages) per agentskills spec.
- Four-layer safety pattern adopted (diagnose → plan → safe → escalated-handed-to-user).

## 0.2–0.3 — 2026-10-24
- Single-machine prototype iterations: bootstrap/quick/full modes, restricted-mode declaration, deployment to ~/.agents/skills, lifecycle documentation.

## 0.1 — 2026-10-24
- Shell draft: trigger conditions + project-doctor.ps1 + design spec.
