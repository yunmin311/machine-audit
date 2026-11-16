# Stage 13 · 报告与基线 diff

## 目的
把 1-12+14-17 的产出渲染成两段式报告，并完成与上一轮的 diff。schema 稳定是硬要求。

## 报告模板
```
# YYYY-MM-DD 全机审查报告（第 N 轮）· <机型>
0. 快照信息与权限档位（受限项单列）
1-15/17. 各阶段事实（表格化；技术段）
16+. 与上轮 diff：新出现 / 已消失 / 恶化 / 改善
+1. 发现分级汇总（P0/P1/P2；每条：现象/证据/建议/可否代办）
+2. 基线值表更新记录
+3. 人话段（本次最该做的三件事，白话，≤10 行）
```

## 覆盖表与发现记录（v0.6 历史修订）

### 覆盖表（"全面"必须可核对）
报告开头列出本轮覆盖对象（磁盘/用户/虚拟机/核心资产/常用软件/远端），每项检查标注六态之一：**完整检查 / 抽样 / 失败 / 权限不足 / 未检查 / 不适用**，附原因与证据位置。有阶段号不等于覆盖完成。

### 关系链检查（跨系统问题藏在这里）
- 资料 → 应用 → 同步通道 → 备份 → 恢复
- 服务 → 端口 → 防火墙 → 远端可达性
- 凭据 → 所属应用 → 同步排除 → 暴露范围
每轮至少核对上述链条一遍：重要资料有没有被同步通道/备份覆盖、开放端口有没有防火墙规则、凭据目录有没有被同步排除。

### 四类记录（分开保存，不许互相转化）
1. **本轮事实**：观察到什么（含失败与离线）
2. **已确认正常的参照**：有证据、经复核的正常状态
3. **待处理问题**：未解决的发现 + 处置历史
4. **有依据的例外**：带证据、范围和复查时间的豁免（如"用户声明的公开身份"）
规则：新观察先进"本轮事实"→ 定性后才可入"已确认正常"；新装软件/新日志模式只登记，**不自动加入白名单**。

### diff 规范（v0.8 按 baseline schema 对位）

**比较对象只有一份**：`baseline-YYYYMMDD.json`（schema 见 `assets/baseline.schema.json`）。报告里的 md 视图和口头描述都不算基线。

1. **对位比较六个固定节**，逐节出 diff；字段缺失 = 结构漂移，记为缺陷并升 `schema_version`，不许"看着差不多"跳过。
2. **采样口径不同不比数值**：`sampled=true` 的两轮之间只比量级与排序（如"仍在前三"），差值写"±（采样，不作精确账目）"。全量 vs 采样混比等于伪造趋势。
3. **数值容差**：`free_bytes` 容差 1%、目录体量容差 5%；超容差才写"变化 N GB"。
4. **"已消失"必须重测原证据条件**才可记为改善——检查失败、对象离线、权限变化都不能记为"已修好"，只能标"本轮未观察到，原因待查"。
5. **git 层趋势用脚本，不靠人记**：`project-doctor.ps1 -Baseline <baseline.json> -SaveBaseline <下一轮基线>` 只读 `snapshots.doctor.repos`，输出新出现 / 已消失 / 改善 / 恶化 / 持平。无基线或基线无该快照时，报告必须出现「无基线，本轮不判趋势」字样——**不许凭印象说变好变坏**。
6. 同一天前测/后测都保留：输出文件名带毫秒级运行 ID（如 `项目登记表-YYYYMMDD-HHmmssfff.md`），不互相覆盖。

## 人话段写作守则
- 不用术语不用缩写；每条=一句问题+一句动作；只列用户本轮真正该做的（≤3 件）。
- 示例（好）：「你的电脑里有一份 32GB 的旧文件副本（OneDrive 备份残留），删掉它 C 盘能多出三分之一空间——删之前我会先确认云端没有你要留的东西。」
- 示例（坏）：「检测到 KFM 重定向遗留实例存在 32.54GB 冗余数据，建议执行 Tier-1 清理。」

## 归档

按 overlay `output_dir` 落盘；命名 `YYYY-MM-DD-全机审查报告.md`；登记表 CSV 同步；报告内链上一轮报告路径。

### 双写必须校验（v0.8）

配了 `archive_mirror` 时报告写两处（主归档目录 `output_dir` + 镜像归档目录 `archive_mirror.path`）。**写完立刻比哈希**：

```powershell
$a = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
$b = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
if ($a -ne $b) { "归档不一致: $src → $dst" }   # 写进报告，不许静默
```

镜像侧只放报告，**不放技能源码副本**——源码副本一旦存在就会与正本漂移，且没人知道哪个是当前版本。

### 证据入库前先过滤（v0.8，踩过的坑）

证据目录曾积累 3,989 个文件，其中 **1,820 个是 `.git/hooks/*.sample`**（45.6%）——七个 fixture 仓库各自把整套钩子模板提交了进来。入库前必须跑一步 strip：

```powershell
# 删钩子模板、*.sample、日志类临时件，再清空目录
Get-ChildItem -LiteralPath <evidence> -Recurse -File -Force |
  Where-Object { $_.Name -eq '*.sample' -or $_.FullName -match '\\\.git\\hooks\\' } |
  Remove-Item -Force
Get-ChildItem -LiteralPath <evidence> -Recurse -Directory -Force |
  Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
  Sort-Object { $_.FullName.Length } -Descending | Remove-Item -Force
```

验收口径是命令，不是感觉：`find <evidence> -name '*.sample' | wc -l` → **0**。

长期形态：每轮证据打成一个 `evidence/review-N-YYYY-MM-DD.tar.xz` + 一份解包说明，仓库里只留压缩包与索引——**原始报告留、钩子模板不留**。
