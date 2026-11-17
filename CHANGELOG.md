# Changelog

> 倒序排列：最新在最上。`0.6.0` 与 `0.6.4` 两个版本号跳过未发布（改动并入相邻条目）。

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
