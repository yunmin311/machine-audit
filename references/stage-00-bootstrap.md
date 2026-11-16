# Stage 00 · Bootstrap（首跑建档 + 判当前风险）

## 目的
在某台机器第一次运行本技能时：探明环境、识别人群与领域、写出机器参数 overlay 与基线，**并对当前状态作出风险判断**。

**v0.6 历史修订**：首轮照常判级——明确的当前危险（唯一副本、备份损坏、凭据外泄、裸奔的敏感服务、无防护）第一轮就必须报警；历史不存在只影响**趋势类**结论，那些标注"尚无历史，暂不能判断趋势"。基线记录与风险判断在同一轮完成。

## 前置检查
1. PowerShell 版本：`$PSVersionTable.PSVersion`（5.1 最低公分母；检测 Constrained Language Mode：`$ExecutionContext.SessionState.LanguageMode` 非 FullLanguage 则声明受限）。
2. 管理员可用性：`([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`（注意：CLM 下此调用可能失败，失败即标受限）。
3. OS：`Get-CimInstance Win32_OperatingSystem | Select Caption,BuildNumber,OSLocale`；版本差异决定后续哪些 cmdlet 可用（Home 无 BitLocker/Get-VM cmdlet 等）。
4. 云重定向：读 `HKCU:\...\Explorer\User Shell Folders` 的 Desktop/Personal/My Pictures **真实路径**（OneDrive KFM 会改它们）；扫描时对 `FileAttributes` 含 `RecallOnDataAccess`/`Offline` 的文件跳过内容读取。
5. 杀软进程探测（360/火绒/Huorong/QQPCMgr/卡巴/EDR 名单存于 overlay `antivirus_processes`）：命中则在报告头声明"杀软环境，枚举结果可能不完整"。

## 步骤
1. 人群/领域探测：扫安装目录、进程、文件扩展名、注册表痕迹，对照 `references/domain-packs.md` 的信号表；命中包记入 overlay `domains:`。信号缺失不排除领域——探索阶段可推翻。
2. 磁盘拓扑：`Get-Disk`/`Get-Partition`/`Get-Volume`（在线、总线、HealthStatus）；外置/网络盘标记为"可离线"。
3. 规模感知：对每个根目录做**限时采样**（`Get-ChildItem -Depth 2` 计数）而非全量，决定 full 模式是否需要 WizTree 交接。
4. 写 `overlay.yaml`：**从 `assets/overlay.template.yaml` 复制**后填本机值（`roots`、`exclude_names`/`exclude_paths`、`thresholds`、`output_dir`、`domains`、`baseline_current`、`assets` 与 `configs` 台账）。不要自造字段名——字段语义见 `references/conventions.md §overlay 字段表`；新增字段要先改模板再改该表。
5. 写基线：优先跑 `scripts/bootstrap-probe.ps1 -Roots <目标根> -OutDir <output_dir> -WriteMarkdown` 自动采集并生成符合 `assets/baseline.schema.json`（`1.1`）的 `baseline-YYYYMMDD.json` + `.md` 人读视图（也可对照 `assets/baseline.template.md` 手工补全）；未传 `-Roots` 时只采集环境与卷账目（防误全盘扫描）。注意：`top_dirs[].owner_note` 必填（未知写`"待用户定性"`）；非管理员运行时 `restrictions` 必须非空或 `meta.scope_note` 已声明；`scan_status` 可选 `ok | partial | failed`（`failed` 整份不判 PASS，`partial` 必须 `sampled=true`）。
6. 跑 `scripts/baseline-check.ps1 -Path <baseline.json>`（若在 `overlay.yaml` 修改了 `thresholds.disk_free_pct_p1` / `p0`，必须传入 `-WarnPct` / `-CritPct`），**必须 PASS 才算建档完成**；FAIL 就按报错逐条修，不许手改 md 掩盖。随后跑一次 `scripts/project-doctor.ps1 -Roots <overlay roots> -OutDir <output_dir> -SaveBaseline <同一份基线>` 把 `snapshots.doctor` 补进去（写回后再跑一次 `baseline-check.ps1` 复核），否则次轮 `-Baseline` 仍会报"无基线"。
7. 报告尾声明："首跑基线已建立；**当前风险已在本报告判级**；趋势类结论自下一轮起可用"。

## 输出 schema

**唯一权威 = `assets/baseline.schema.json`**（JSON），六节固定：Environment / Drives / TopDirs / Persona / Domains / Restrictions，另加 `meta`（run_id、带时区时间戳、技能版本、模式）与可选 `snapshots`（工具快照，供脚本消费）。

- `baseline-YYYYMMDD.md` 是 JSON 的人读视图，两者不一致时以 JSON 为准，并把不一致记为缺陷。
- 结构不兼容变更 = 升 `schema_version` 主版本 + 升技能版本；只加可选字段 = 升次版本，不必升技能。
- **为什么必须机械校验**：`free_pct` 一旦被写成 `"16.9%"` 这样的字符串，下一轮比较会按字符串走，红线永远不出 P1——肉眼看不出来。`baseline-check.ps1` 就是拦这类静默错误的。

## 无基线时怎么办

首轮无基线属正常：报告写"无基线，本轮不判趋势"，**但当前风险照样按事实判级**（铁律 2）。非首轮却找不到基线要查三处：overlay 的 `baseline_current` 路径是否写错、基线是否随报告一起归档、上一轮是否根本没建档。
