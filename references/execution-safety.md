# Execution Safety · 两段式执行、预览与回退（阶段 13/执行期引用）

> 完整设计见仓库 `docs/design/execution-safety.md`。本文件是执行者操作规程。

## 铁律
1. **删除永远不直接删除**：一律先移动到同盘隔离区 `<同盘>\_quarantine\<runid>\<原相对路径>`（同盘 rename 瞬间完成）。清空隔离区 = 独立的再批准动作。
2. **每个动作先写日志再执行**：`operations.jsonl` 逐行记录（runid/batch/seq/type/from/to/size/sha256/status/ts）。
3. **执行前指纹核对**：对象哈希与批准的 manifest 不符 → 该批拒绝执行，报"计划与现场不符"。
4. **中断恢复幂等**：重跑读日志——done 跳过、pending 重做、failed 上报；from 不在而 to 在 = 已完成。
5. **不可回滚动作清单**（清空回收站、清空隔离区、跳过隔离区的删除）：单独批次、单独授权、排在所有批次最后。

## 预览产物（批准门之前生成，大额批次必须）
```
preview/<runid>/
├── tree-before.md      受影响目录前置树（路径+体量+关键文件）
├── tree-after.md       模拟后树（[已删除] / [已移动→隔离区] 标注）
├── operations-preview.jsonl
├── asset-map.md        资产地图（重要文件位置+备份状态+保护方式+"动它之前先看哪节"）
└── rollback-manifest.json
```
> **该预览生成器尚未实现：以下为设计中的调用约定；当前需按本节规程手工生成。**

用户在批准门看到的是 tree-after + asset-map——"改完之后大概的样子"和"重要文件都在哪"。

## 分层预览
- L1 清单（可删除清单）
- L2 树状前后 diff（纯计算，零风险，所有批次可用；尚无生成脚本）
- L3 隔离区试运行（真实进入删除后状态，宽限期默认 14 天；宽限期管理脚本尚未实现，到期需手工复核）——文件操作的"真预览"
- VM 预览：仅系统级变更（服务/注册表/引导）建议；家庭版无 Hyper-V/Sandbox，如实声明

## 回退流程
```
rollback.ps1 -RunId <id> [-Batch N]   # 尚未实现：设计中的调用约定，当前按规程手工执行
  读 operations.jsonl → 过滤批次 → 逆序回放 → 每步校验隔离区哈希 → 移回原位 → 校验
  → 回滚报告（成功 N / 失败 M / 跳过 K）
```
> **该脚本尚未实现：以下为设计中的调用约定；当前需按本节规程手工执行。**
- 回滚失败 ≠ 数据丢失：对象仍在隔离区。
- 每批执行后随机抽 2 条做回滚演练（"恢复已验证"制度化）。
- 注册表/服务/任务类回滚材料：reg export / sc qc / schtasks /export 前置保存。

## 授权与日志
- 批准落在 plan 文件的批次上；operations.jsonl 每行记录授权批次号——未授权批次的动作拒绝执行。
- 计划变更（对象指纹不符）→ 该批挂起，重新走批准门。

---

## 删除的验收口径：看空间增量，不看文件是否消失（v0.8，两次踩坑）

### 现象

报"已删除"，用户去看磁盘可用空间——**一点没变**。于是判"清理失败"，重新扫一遍、重新删一遍。

典型场景：大额清理后文件确实从原位消失了，但磁盘可用空间没有回来。

### 机制

Windows 上"删除"有两条完全不同的路径：

| 路径 | 空间何时释放 | 可恢复性 |
|---|---|---|
| `Move-Item` 到同盘隔离区（rename） | 清空隔离区时 | 高（移回即可） |
| Shell / 资源管理器 / 回收站 API 删除 | **清空回收站时** | 中（回收站里能还原） |
| `Remove-Item`（PowerShell 直删） | 立即 | 无 |

第二条是关键：文件进了 `<盘>:\$Recycle.Bin`，占的还是**同一个盘**的空间。所以"逻辑上删了、物理上没释放"。

### 规矩

1. **批内删除一律走隔离区**（`Move-Item` 同盘 rename），不要用 Shell/资源管理器/回收站 API——既不产生回收站条目，也保住可回退性。
2. 若某批确实经由回收站（用户手动删、软件自己删、`Clear-RecycleBin` 前置的清理），**必须立刻清空并把回收站增量计入报告**；清空本身是不可回滚动作，按铁律 5 单独授权、排在最后。
3. **验收指令必须写成空间增量（推荐直接调用 `scripts/measure-space-delta.ps1`，同时精确采集 `Y` 与 `Z`）**：

```powershell
# 推荐用法（PS 5.1 兼容，单引号保护 '$Recycle.Bin' 并检测多 SID 受限）：
.\scripts\measure-space-delta.ps1 -Action Snapshot -Drive E: -OutFile "$env:TEMP\before.json"
# ... 执行本批 ...
.\scripts\measure-space-delta.ps1 -Action Compare -Drive E: -BeforeFile "$env:TEMP\before.json" -LogicalBytes <manifest总字节数>
```

手工对照等价算式：
```powershell
function Get-FreeGB([string]$d) {
  $v = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$d'"
  [math]::Round($v.FreeSpace / 1GB, 2)
}
$before = Get-FreeGB 'E:'
# ... 执行本批 ...
$after  = Get-FreeGB 'E:'
"实测释放: $([math]::Round($after - $before, 2)) GB"
```

4. **报告固定三栏**，缺一栏就是没验收：

```
逻辑释放 90.0 GB / 实测释放 0.0 GB / 回收站 90.0 GB  → 判「未释放，空间在回收站」
逻辑释放 90.0 GB / 实测释放 89.6 GB / 回收站 0.4 GB  → 判「已释放」
```

### 反模式

- ❌ 用"文件是否还在原路径"当验收：这在回收站路径下永远为真（文件确实不在了），会给出假成功。
- ❌ 只看资源管理器"可用空间"一眼：Windows 的刷新有延迟，且回收站占用要单独看。
- ❌ 删完不复核就报"已清理 N GB"：用户下次打开磁盘发现没变，整轮结论全部失信。
- ❌ 把回收站体积算进"已释放"：那是自欺——它还在同一个盘上。
