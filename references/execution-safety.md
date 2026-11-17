# Execution Safety · 两段式执行、预览与回退规程

> 完整设计见仓库 `docs/design/execution-safety.md`。**边界声明**：`scripts/invoke-plan.ps1`、`scripts/rollback.ps1`、L2 树预览生成及 14 天隔离区自动宽限期管理**尚未脚本化/尚未实现**，当前严格按本规程手工执行与核验。

## 执行五铁律
1. **删除先搬同盘隔离区**：一律移往 `<同盘>\_quarantine\<runid>\<原相对路径>`（同盘 rename 瞬间完成）；清空隔离区须独立再批准。
2. **先记日志后执行**：`operations.jsonl` 逐行记录 `runid/batch/seq/type/from/to/size/sha256/status/ts`。
3. **执行前指纹核对**：现场对象哈希与批准 manifest 不符 → 整批挂起并报"计划与现场不符"，回批准门重核。
4. **中断幂等可重放**：重跑读 `operations.jsonl`，`done` 跳过、`pending` 重做、`failed` 上报（`from` 无且 `to` 在 = 已完成）。
5. **不可回滚动作排最后**：清空回收站、清空隔离区、跳过隔离区的直删必须单独成批、单独授权并排在末尾。

## 预览与回退规程
- **批准前预览（`preview/<runid>/`）**：生成 L1 可删清单、L2 模拟前后树（`tree-before.md` / `tree-after.md`）、`operations-preview.jsonl`、`asset-map.md`（重要文件位置与前序检查）与 `rollback-manifest.json`；大额批次未经确认预览不得进入执行。
- **分层策略**：L1 清单与 L2 树状 diff 零风险可计算；L3 隔离区默认宽限 14 天（机器照常运行=真试运行）；系统级变更（服务/注册表/引导）优先 VM 预览，Home 版缺 Hyper-V 如实声明。
- **回退材料与演练**：文件移动/删除靠 `(from, to, hash)` 同盘逆序移回（设计约定 `rollback.ps1 -RunId <id> [-Batch N]`，尚未实现）；注册表用 `reg export`、服务用 `sc qc`+`sc query`、计划任务用 `schtasks /export /xml` 前置留档；每批执行后随机抽 2 条做回滚演练（"恢复已验证"制度化）。
- **批授权与计划变更**：未落盘授权批次号拒绝执行；若现场哈希变化，挂起该批重新确认预览与批准。

## 删除的验收口径（空间增量，非文件消失）

- **回收站假成功拦截**：
  - 现象：清理后原路径文件已消失且报告"已删除"，但资源管理器可用空间毫无变化（Shell 删除仅将空间转移至同一卷的 `$Recycle.Bin`）。
  - 判据：批内删除**严禁走 Shell/回收站 API**（一律 `Move-Item` 同盘隔离区；确经回收站且批内清零须按铁律 5 单独授权排最后）；唯一验收口径为**可用空间实测增量**，报告固定三栏 **`逻辑释放 X GB / 实测释放 Y GB / 回收站 Z GB`** 须满足 `X ≈ Y + Z`（容差 1%）；当 `Y ≈ 0` 且 `Z > 0` 时必须判 **`未释放，空间在回收站`**；`QuarantineMode` 下可用空间不增加判 `quarantine-pending` 属预期，最终释放验收在清空隔离区批完成。
  - 命令（批前后调用 `scripts/probe.ps1 -Action delta`；单引号保护 `'$Recycle.Bin'`；亦可直接对照 `Win32_LogicalDisk.FreeSpace`）：
```powershell
.\scripts\probe.ps1 -Action delta -DeltaMode Snapshot -Drive E: -OutFile "$env:TEMP\before.json"
# ... 执行本批（隔离区 Move-Item）...
.\scripts\probe.ps1 -Action delta -DeltaMode Compare -Drive E: -BeforeFile "$env:TEMP\before.json" -LogicalBytes <manifest总字节数>
# 手工等价校验: [math]::Round(((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='E:'").FreeSpace) / 1GB, 2)
```

## 反模式清单
- 用 `Test-Path` 判断"文件已不在原位"即当成功（回收站路径永远为假成功）。
- 仅凭肉眼看资源管理器刷新结果或把回收站体积算作"已释放"。
- 批内未保存隔离区哈希或前置导出即改动关键系统项。
- 跳过三栏差额对账或发现 `|X - (Y + Z)| > 1%` 仍强行宣称完全清理成功。
