# Stage 02 · 磁盘空间账目

## 目的
回答三个问题：空间去哪了、增长来自哪、哪些块符合/违反既定规则。全程元数据操作，**不读文件内容**。

## 前置与守则
- 每个盘先 `Get-Volume` 确认在线与剩余空间；写报告前检查目标盘剩余（不足 200MB 改写临时目录并声明）。
- 全程 `-LiteralPath` + `-ErrorAction SilentlyContinue`；Access Denied 静默收集，最后汇总一行，不逐条刷屏。
- ReparsePoint（junction/链接）排除，防重复计数；云占位文件（RecallOnDataAccess/Offline 属性）跳过内容读取，只报占位。
- 超长路径：枚举失败时用 `\\?\` 前缀重试一次。
- 大目录（>50 万文件或采样超时）：降级为 WizTree/Everything 交接，声明"深度受限"。

## 标准动作（按序）
1. **卷级**：`Get-CimInstance Win32_LogicalDisk | Select DeviceID,Size,FreeSpace`——红线判定（系统盘 <15% P1、<10% P0；数据盘同阈值；阈值可在 overlay 调）。
2. **根目录白名单**（仅系统盘）：`Get-ChildItem <sysroot>\ -Force -File`，白名单外文件逐一记录（= 垃圾候选）。
3. **一级分解**：每个根目录的直接子目录体量排序（top 15-20）。命令骨架（含 symlink/大目录时勿直接 `-Recurse`，改用下节 `§扫描方法` 的 PS 5.1 安全枚举）：
   `Get-ChildItem -LiteralPath <root> -Directory -Force -EA SilentlyContinue | ForEach-Object { $s=(Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum; ... }`
   （尾递归注意：目录含 0 文件时 Measure 无输入会报属性错——用 `if ($null -eq $s) {$s=0}` 兜底。）
4. **热点下钻**：对 top 块各下钻一层，直到找到"可解释的终端"（某软件目录/某媒体目录/某缓存）。
5. **缓存与临时清单**：`%TEMP%`、`C:\Windows\Temp`、SoftwareDistribution\Download、各盘 `$Recycle.Bin`、浏览器缓存、包管理器缓存（npm/pip/uv/pnpm，位置从各自 config 读而非硬编码）。
6. **diff**：与上一轮基线同位对比：增长 top5 / 缩小 top5；新增根目录项。

## 判定
- 新增"白名单外根文件"或未知大目录 → 记录并入残留阶段（15）核实主人。
- 缓存类合计 >10GB → P2 提示；>20GB → P1。
- 增长异常（单目录月增 >20GB 且无法解释）→ P1 定性任务。

## 输出 schema
`## 磁盘空间`：卷表（总量/剩/红线状态）→ 根目录 top 表 → 每热点一行"体量/最后修改/归属定性"→ 缓存清单 → diff 表。数字全部标注采样时间。

## 常见坑
- junction 双算（Users 体积虚高）——ReparsePoint 排除后如仍对不上总账，声明差额。
- `Measure-Object Length` 对空集合抛错——必须兜底。
- SMR/HDD 大目录枚举极慢——预检 `Get-PhysicalDisk MediaType`，HDD 直接 WizTree 交接。
- OneDrive 占位：`Length` 是逻辑大小，本地实际占用可能为 0——报告分"逻辑/实际"两列（实际占用用 `fsutil file layout` 太重，简化为标注占位数量）。

---

## 扫描方法（2026-11-16 新增，实战校准）

### `du` 在本机不可用于大目录

实测：`du -sm <项目根>` **15 分钟无结果**，`du -sm <游戏库>` 90 秒超时。
原因：`node_modules` 里的 symlink（pnpm 布局）让 `du` 陷入重复遍历，且 MSYS 层不做重解析点判断。

**正确方法（PS 5.1 / .NET 4.x 兼容实现）**：使用 `DirectoryInfo.EnumerateFileSystemInfos('*', [IO.SearchOption]::TopDirectoryOnly)` 迭代遍历并显式跳过 `ReparsePoint`。切勿在 PS 5.1 上使用 `System.IO.EnumerationOptions`（那是 .NET Core 2.1+ / PS 7+ 才有的类型，PS 5.1 会直接抛"找不到类型"）。

```powershell
# PS 5.1 可用：DirectoryInfo.EnumerateFileSystemInfos 的 2 参重载
$sum = 0L; $count = 0; $skipped = 0; $failed = $false
if (-not (Test-Path -LiteralPath $root)) { $failed = $true }
elseif ($PSVersionTable.PSVersion.Major -ge 7) {
  # PS 7+ 可选快速路径（加速用，非必需；PS 5.1 走下方 else 分支）
  try {
    $opt = New-Object System.IO.EnumerationOptions
    $opt.IgnoreInaccessible    = $true   # 注意：无权子目录会被跳过，需结合受限清单声明
    $opt.RecurseSubdirectories = $true
    $opt.AttributesToSkip      = [IO.FileAttributes]::ReparsePoint
    foreach ($f in [IO.Directory]::EnumerateFiles($root, "*", $opt)) {
      try { $sum += (New-Object IO.FileInfo $f).Length; $count++ } catch { $failed = $true }
    }
  } catch { $failed = $true }
} else {
  $stack = New-Object System.Collections.Stack
  $rootDi = New-Object System.IO.DirectoryInfo $root
  if ($rootDi.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    $skipped++
  } else {
    $stack.Push($rootDi)
  }
  while ($stack.Count -gt 0) {
    $di = $stack.Pop()
    try {
      foreach ($e in $di.EnumerateFileSystemInfos('*', [IO.SearchOption]::TopDirectoryOnly)) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped++; continue }  # 不跟 junction/symlink
        if ($e -is [IO.DirectoryInfo]) { $stack.Push($e) } else { $sum += $e.Length; $count++ }
      }
    } catch { $failed = $true }   # 失败必须显式，不许当 0
  }
}
if ($failed) {
  [pscustomobject]@{ path = $root; status = "failed"; bytes = $null; files = $null; skipped_reparse = $skipped }
} else {
  [pscustomobject]@{ path = $root; status = "ok"; bytes = $sum; files = $count; skipped_reparse = $skipped }
}
```

**实测口诀**：**`files=0` 且目录非空时，先怀疑采集失败，再谈目录为空。** 任何异常都必须输出 `status=failed`（且不返回 `0` 当有效账目），对应铁律 4「采集失败不等于一切正常」。

**实测对比**（同一批目录）：

| 目录 | `du` | `.NET 枚举（跳过重解析点）` |
|---|---|---|
| `<游戏库>` 125,220 文件 / 332 GB | 420 秒超时 | **8.2 秒** |
| `<应用库>` 454,951 文件 / 189 GB | 90 秒超时 | **56.5 秒** |
| `<项目根>` 580,908 文件 / 29 GB | 15 分钟无结果 | **51 秒** |

**注意**：`EnumerateFiles` 在遇到重解析点时若未设 `AttributesToSkip`，会抛
`系统无法访问此文件` 并**立即中断整个枚举**（只数到 1,134 个文件就停），
看起来像"目录很小"，实为采集失败——必须把返回值和已知规模对一下。

### 大目录不要无上限扫描

遍历 TB 级大盘会占满磁盘 IO，导致整机卡顿（实测会引起系统明显卡顿）。
规矩：**按目录分批、每批限时、且在用户空闲时执行**；报告里标注"扫描期间可能影响性能"。

### 规模预检与增量口径（v0.8 新增）

**先量规模，再决定怎么扫**——全盘 `-newermt` 扫描实测 45 分钟跑不完，中途放弃等于白扫。

1. **规模预检**（秒级，只数不读）：`Get-ChildItem -LiteralPath <root> -Depth 1 -Directory -Force -EA SilentlyContinue | ForEach-Object { ... 计数 }`。
   - 一级子项 < 5,000 且总量估 < 20 万文件 → 本技能自己扫（`.NET EnumerateFiles` 或 PS 5.1 枚举）。
   - 任一超过 → 直接走外部工具交接（WizTree / Everything），声明"深度受限，本表为抽样"。
2. **增量口径**：只扫 `LastWriteTime -gt <上轮时间戳>`。时间戳**从基线读**（`meta.generated_at`），不靠记忆、不靠"上次大概是上周"：
   ```powershell
   $since = [datetimeoffset]::Parse($baseline.meta.generated_at, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime
   Get-ChildItem -LiteralPath $root -Recurse -File -Force -EA SilentlyContinue | Where-Object LastWriteTime -gt $since
   ```
   增量结果只回答"这段时间什么在长"，**不能当作总量**——总量仍用全量枚举或外部工具。
3. **满盘扫描的代价要预先说**：TB 级全盘遍历会占满 IO，导致整机卡顿。开工前声明"扫描期间可能影响性能，建议空闲时执行"，并给分批计划；用户没同意就别在上班时间跑。

---

## 安装包/下载归档的识别（新增判据）

**症状**：某目录体量巨大，但里面不是"数据"，是"下载了没删的安装包"。

**判据三条同时成立即定性为 B 级（可重下）**：
1. 大文件占比高：>100 MB 的文件占目录体量 80% 以上
2. 扩展名集中：`.rar` / `.zip` / `.7z` / `.iso` / `.exe` / `.msi` / `.dmg`
3. 目录名或文件名含软件名 / 版本号 / "绿色版" / "安装包" / "破解" / "BETA"

判定后统计"可回收 = 全部安装包体量"，并在报告里给出「安装包 vs 程序本体」对比
（例如某机 Photoshop 已装 5.6 GB，其安装包却占 35.9 GB —— 安装包是程序本体的 6 倍）。

**反面**：不要因为"目录名叫下载"就直接判可删。`BaiduNetdiskDownload` 里可能混着
用户下载的照片/文档 —— 必须看扩展名分布，不能只看目录名。

---

## 三条防误判（本轮实战踩过）

| 误区 | 事实 | 后果 |
|---|---|---|
| `Test-Path "A"` 与 `Test-Path "a"` 都为真 = 两个目录 | **Windows 不区分大小写**，两者是同一对象 | 会把一个目录报成"大小写双份"（本技能实际犯过） |
| 进程工作集小 = 不占内存 | 工作集（WS）只是常驻物理页 | 某数据库服务实测 WS 6.3 MB，**私有提交 630.9 MB**；判内存看 `PrivateMemorySize64` |
| 空目录 = 不存在 | 0 文件 0 子目录仍是真实目录 | 报"已清理"但实际残留空壳，需单独列"空壳目录"清单 |

