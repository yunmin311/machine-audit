# Stage 02 · 磁盘空间账目

## 目的与守则
回答空间去哪了、增长来自哪、哪些符合/违反规则（只读元数据，**不读文件内容**）。
- 每盘先 `Get-Volume` 确认在线与剩余（目标盘不足 200MB 时写临时目录并声明）；全程 `-LiteralPath` + `-ErrorAction SilentlyContinue`，Access Denied 末尾汇总。
- 跳过 `ReparsePoint`（junction/symlink）；云占位（`Offline`/`RecallOnDataAccess`）跳过读取仅计数；超长路径失败用 `\\?\` 重试一次；`>50 万` 文件或超时交接 WizTree/Everything 并声明深度受限。

## 标准动作与判定
1. **卷级红线**：`Get-CimInstance Win32_LogicalDisk | Select DeviceID,Size,FreeSpace`（系统盘/数据盘 `<15% → P1`、`<10% → P0`，可在 overlay 调）。
2. **根目录白名单（仅系统盘）**：`Get-ChildItem <sysroot>\ -Force -File` 记录白名单外文件并入阶段 15 核实主人。
3. **一级分解与热点下钻**：对大目录禁止直接使用 `Get-ChildItem -Recurse` 或 MSYS `du`，改用下方安全枚举；`Measure-Object Length` 空集合须 `if ($null -eq $s){$s=0}` 兜底；热点下钻至软件/媒体/缓存终端。
4. **缓存与临时（规则化 + 原生 GC 优先）**：声明式规则见 `assets/cleanup-rules.json`（18 条通用规则，每条强制含 `probe` 探针、`preferred_command` 原生清理与 `does_not_touch` 排除边界）；先只读跑 `powershell -Command "& '.\scripts\probe.ps1' -Action rules"` 匹配常见用户路径缓存，合计 `>10GB → P2`、`>20GB → P1`。对迁至非系统盘的自定义存储（如 `pnpm store path`、`<数据盘>:\$Recycle.Bin`）须补充盘级探测，并查看规则输出的 `path_details`（区分部分子路径无权限 `partial` 与整体不可读 `failed`）及稀疏 `.vhdx` 实占 `estimated_allocated_bytes`，禁删未核查 `does_not_touch` 项。
5. **多维分布、大文件筛选与断点流式（零额外 IO 单次顺采）**：`scripts/probe.ps1 -Action space` 将根目录直属文件与子目录树一体纳入统计，在同遍遍历中输出 **3×3 年龄（基于 `LastWriteTime`）× 体量桶表**、**≥100MB Top-50 大文件**（经 `GetCompressedFileSizeW` 附实际占盘 `allocated_bytes`，防稀疏 `.vhdx`/`Docker.raw` 与云占位虚胖误报），以及 **全卷已用 − 已枚举合计 = `unaccounted_bytes（<Unknown>）`**（覆盖卷影 VSS、`System Volume Information` 与受限跳过区）。支持结构化筛选参数（`-MinSizeMB`、`-MinAgeDays`、`-IncludeExt`、`-ExcludeExt` 仅筛大文件候选，不扭曲目录与矩阵总账）及带每目录分桶快照的 `-StreamOut <jsonl> [-Resume]` 断点续扫。
6. **四级漏斗只读查重（`scripts/probe.ps1 -Action dupes`）**：面向重复安装包/ISO/媒体/模型副本——**第 0 关**跳过 0 字节、重解析点与云占位文件（严禁哈希触发 OneDrive/云盘回源下载）并应用 `-MinSizeMB`（默认 10MB）/扩展名/年龄筛选；**第 1 关**按字节分组并经 Win32 `GetFileInformationByHandle` 识别 NTFS 硬链接（`pnpm store` 等硬链接同块只占一份空间，单列 `hardlink_clusters` 标 `reclaimable_bytes=0`，严禁误当重复删掉）；**第 2 关**仅读同大小候选的头 4KB + 尾 4KB 算局部 SHA256；**第 3 关**仅对碰撞组流式全文件 SHA256 确认并按 `allocated_bytes` 计算真实可回收空间。
7. **基线 diff**：对比 `overlay.baseline_current`（须为 `baseline-*.json`）的增长/缩小 top5 与新增根目录；单目录月增 `>20GB` 且无解释 → P1。
- **常见坑**：`Get-PhysicalDisk | Select FriendlyName,MediaType` 查出 HDD/SMR 时优先使用 `probe -Action env` 记下的 `fast_scanners`（WizTree / Everything）或 `-StreamOut` 分批落盘；`LastAccessTime` 在 Windows 默认可能延迟刷新，分桶口径固定写明 `LastWriteTime`。

## 扫描方法与实测判据

- **大目录安全枚举（替代 MSYS `du` 与 PS 7+ 专有 API）**：
  - 现象：`du` 在 pnpm/symlink 目录陷入重复遍历，而 `System.IO.EnumerationOptions` 在 Windows PS 5.1 抛找不到类型错；未跳 `ReparsePoint` 的枚举遇到链接会直接中断。
  - 判据：Windows 下统一使用 `.NET 4.x` `EnumerateFileSystemInfos('*', TopDirectoryOnly)` 显式跳过 `ReparsePoint`；**`files=0` 且目录非空时先怀疑采集失败**；异常必须显式标 `status=failed`，禁止返回 `0`。
  - 命令（推荐直接调用 `scripts/probe.ps1 -Action space -Roots <目录>`，等价脚本核心如下）：
```powershell
$sum = 0L; $count = 0; $skipped = 0; $failed = $false
if (-not (Test-Path -LiteralPath $root)) { $failed = $true }
elseif ($PSVersionTable.PSVersion.Major -ge 7) {
  try {
    $opt = New-Object System.IO.EnumerationOptions
    $opt.IgnoreInaccessible = $true; $opt.RecurseSubdirectories = $true; $opt.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
    foreach ($f in [IO.Directory]::EnumerateFiles($root, "*", $opt)) { try { $sum += (New-Object IO.FileInfo $f).Length; $count++ } catch { $failed = $true } }
  } catch { $failed = $true }
} else {
  $stack = New-Object System.Collections.Stack; $rootDi = New-Object System.IO.DirectoryInfo $root
  if ($rootDi.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped++ } else { $stack.Push($rootDi) }
  while ($stack.Count -gt 0) {
    $di = $stack.Pop()
    try {
      foreach ($e in $di.EnumerateFileSystemInfos('*', [IO.SearchOption]::TopDirectoryOnly)) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped++; continue }
        if ($e -is [IO.DirectoryInfo]) { $stack.Push($e) } else { $sum += $e.Length; $count++ }
      }
    } catch { $failed = $true }
  }
}
[pscustomobject]@{ path = $root; status = $(if($failed){"failed"}else{"ok"}); bytes = $(if($failed){$null}else{$sum}); files = $(if($failed){$null}else{$count}); skipped_reparse = $skipped }
```

- **规模预检与增量口径**：
  - 现象：对 TB 级大盘直接无上限全扫或 `-newermt` 全盘检索会打满磁盘 IO 并致半途中止。
  - 判据：先数一级子项——一级子项 `<5,000` 且总量估 `<20 万` 文件再由脚本扫，否则交接 WizTree/Everything 并标"深度受限，本表为抽样"；增量只读 `baseline.meta.generated_at` 作起始时间，增量值只解释近期增长，**不得替代总量**；全盘扫前先征得空闲时段运行确认。
  - 命令（先一级预检，再增量检索）：
```powershell
@(Get-ChildItem -LiteralPath $root -Directory -Force -EA SilentlyContinue).Count
$since = [datetimeoffset]::Parse($baseline.meta.generated_at, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime
Get-ChildItem -LiteralPath $root -Recurse -File -Force -EA SilentlyContinue | Where-Object LastWriteTime -gt $since
```

- **安装包 / 下载归档识别**：
  - 现象：目录体量巨大但并非业务数据，实为下载后长期未删的安装包集合。
  - 判据：以下三条**同时成立**定性为 B 级可重下，并在报告给出「安装包 vs 程序本体」对比；**禁止仅凭目录名含 Download/网盘直接判删**（常混有照片/文档）。① `>100MB` 文件占目录体量 `≥80%`；② 扩展名集中于 `.rar/.zip/.7z/.iso/.exe/.msi/.dmg`；③ 目录或文件名含软件名/版本号/绿色版/安装包/破解/BETA。
  - 命令：
```powershell
Get-ChildItem -LiteralPath $dir -Recurse -File -Force -EA SilentlyContinue | Group-Object Extension | Sort-Object { ($_.Group | Measure-Object Length -Sum).Sum } -Desc | Select-Object -First 8 Name,Count,@{n='GB';e={[math]::Round(($_.Group|Measure-Object Length -Sum).Sum/1GB,2)}}
```

## 三条防误判

- **大小写双拼写误报双份**
  - 现象：`Test-Path "Foo"` 与 `Test-Path "foo"` 均返回 `$true`，被误记成两个独立目录。
  - 判据：Windows 文件系统默认不区分大小写，同物理路径去重后再计账（Windows `-ieq` / 类 Unix `-ceq`）。
  - 命令：`([IO.Path]::GetFullPath($p1).TrimEnd('\') -ieq [IO.Path]::GetFullPath($p2).TrimEnd('\'))`
- **工作集 ≠ 进程真实内存占用**
  - 现象：某后台服务 WorkingSet 仅几 MB，实际长期吃掉数百 MB 提交内存。
  - 判据：评估进程或零使用服务内存开销时一律以 `PrivateMemorySize64`（私有提交）为准，不用 WS。
  - 命令：`Get-Process | Sort-Object PrivateMemorySize64 -Desc | Select-Object -First 10 Name,Id,@{n='PrivateMB';e={[math]::Round($_.PrivateMemorySize64/1MB,1)}},@{n='WSMB';e={[math]::Round($_.WS/1MB,1)}}`
- **空目录残余未单列**
  - 现象：清理后大文件消失即宣称"已清理干净"，实际目录与各级子目录空壳仍在。
  - 判据：0 文件且 0 子目录仍属真实目录对象，清点 R 类残留时须单列「空壳目录清单」。
  - 命令：`Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -EA SilentlyContinue | Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -Force -EA SilentlyContinue).Count -eq 0 } | Select-Object FullName`

## 输出 schema
`## 磁盘空间`：卷表（总量/剩/红线 + `<Unknown>` 未归账差额）→ 根目录 top 表 → 3×3 年龄×体量矩阵与 Top 大文件（含逻辑 vs 实占及筛选条件 `applied_filters`）→ 规则命中候选清单（附 `does_not_touch` 与 `preferred_command`）→ 可选重复文件组（含 `hardlink_clusters` 与真实可回收 `allocated_bytes`）→ 与基线 diff 表（全数值标注采样时刻）。
