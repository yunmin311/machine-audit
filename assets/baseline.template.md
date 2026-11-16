# baseline-YYYYMMDD · 本机基线（模板）

> **关系**：`baseline-YYYYMMDD.json` 是唯一权威（受 `baseline.schema.json` 约束，由
> `scripts/baseline-check.ps1` 机械校验）；本 Markdown 是它的人读视图，嵌进报告用。
> **两者不一致时以 JSON 为准，并把不一致当缺陷记录**——不许手改 md 让数字好看。
>
> 复制本文件为 `<output_dir>/baseline-YYYYMMDD.md`，与同名 `.json` 一起落盘。
> 六节固定，节名与顺序不许改（schema 稳定是 diff 的前提）。

```yaml
# 与 JSON 的 schema_version / meta 一一对应，先填这里
schema_version: "1.1"
run_id: "YYYYMMDD-HHmmssfff"
generated_at: "YYYY-MM-DDTHH:mm:ss+08:00"
skill_version: "0.8.1"
mode: "bootstrap | quick | full | maintain"
scan_status: "ok | partial | failed"
previous_run_id: null
scope_note: "<本轮覆盖了什么、漏了什么>"
```

---

## §Environment

| 项 | 值 |
|---|---|
| OS | <Caption> |
| Build | <BuildNumber> |
| Locale | <OSLocale> |
| PowerShell | <5.1 / 7.x> |
| LanguageMode | <FullLanguage / ConstrainedLanguage> |
| 管理员 | <是 / 否 —— 否即全表标注"受限"> |
| 杀软/EDR | <进程名，或"未检出"> |
| KFM 重定向 | <开启 / 未开启> |
| Desktop 真实路径 | <User Shell Folders 值> |
| Personal 真实路径 | <同上> |
| Pictures 真实路径 | <同上> |

> 云重定向只认注册表值，不认 `[Environment]::GetFolderPath("Desktop")` 的返回值——
> 后者在 KFM 未重定向时也可能指向别处，机器上可能同时存在两个 Desktop。

## §Drives

| 盘 | 卷标 | 总量 | 剩余 | 剩余% | 介质 | 总线 | 红线 | 备注 |
|---|---|---:|---:|---:|---|---|---|---|
| <C:> | | <GB> | <GB> | <%> | <SSD/HDD/SMR> | <NVMe/SATA> | <ok/warn/critical> | |

红线判据：系统盘 <15% → P1，<10% → P0；数据盘同阈值。阈值可在 `overlay.yaml` 调；自定义阈值时跑 `baseline-check.ps1` 须传入 `-WarnPct` / `-CritPct`。

## §TopDirs

采样口径与采集状态必须标注：`sampled=true` 表示未全量枚举，数字只能当量级不能当账目；`scan_status=failed` 时整份基线不得判 PASS，`partial` 时必须 `sampled=true`。

| 路径 | 体量 | 文件数 | 采样 | 采集状态 | 深度 | 最后写入 | 归属定性 |
|---|---:|---:|---|---|---:|---|---|
| <路径> | <GB> | <n> | <是/否> | <ok/partial/failed> | <n> | <时间> | <哪个软件/哪类数据；必填，未知写"待用户定性"> |

> 归属定性不许留空，也不许填"未知"了事——未知就要写成"待用户定性"，进阶段 15 核实。

## §Persona

角色原语可叠加，不贴人群标签。命中的信号写进 evidence，缺失信号不排除角色。

| 角色族 | 命中原语 | 证据 |
|---|---|---|
| 生产 | <production-code / -doc / -media / -ml / -design / -notes> | <命中信号> |
| 消费 | <consume-*> | |
| 承载 | <host-*> | |
| 连接 | <connect-*> | |
| 治理 | <govern-*> | |

## §Domains

| 项 | 值 |
|---|---|
| 命中领域包 | <pack id，逗号分隔；空=通用流程照跑> |
| 本机特有线索 | <signal → meaning；附来源与日期> |

## §Restrictions

有受限项就没资格说"一切正常"，只能逐项标注覆盖状态。

| 类型 | 范围 | 说明 | 影响阶段 |
|---|---|---|---|
| <permission/policy/antivirus/offline/clm/long-path/encoding/unknown> | <哪些盘/目录/操作> | <具体表现> | <02,15> |

---

## 与上一轮的差异（diff）

> 无上一轮基线时，本节只写一行：**「无基线，本轮不判趋势」**——不许凭印象说变好变坏。

| 对象 | 上轮 | 本轮 | 变化 | 判定 |
|---|---:|---:|---|---|
| <盘符 / 目录> | | | <+/- > | <恶化/改善/持平> |

判定规则（见 `stage-13` §diff 规范）：
- "已消失"必须**重测原证据条件**后才可记为改善；采集失败、对象离线、权限变化只能记"本轮未观察到，原因待查"。
- 同日前后测各存一份，文件名带 run_id，不互相覆盖。
