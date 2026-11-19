<#
.SYNOPSIS
  probe.ps1 - 整机审查统一只读探测工具 v1.2（PS 5.1 兼容，-Action env|space|docs|delta|rules|dupes）
.DESCRIPTION
  通过 -Action 选择六项只读测量之一（绝不修改被测目录或删除文件）：
  - env   : 按 references/stage-00-bootstrap.md 与 assets/baseline.schema.json (1.2) 采集
            环境档位、权限/KFM/杀软、快速 MFT 工具探测与卷级空间账目，输出标准基线 JSON。
  - space : 按 references/stage-02-disk.md 安全枚举 -Roots/-TopDirs（跳过 ReparsePoint，
            -MaxFilesPerDir 限流防卡死，支持 -StreamOut/-Resume 断点流式产出，支持结构化筛选）；
            同遍产出 3x3 年龄x体量矩阵、>=100MB Top-N 实占大文件与 <Unknown> 对账。
  - docs  : 按 references/memory-hygiene.md 五层模型扫描 Markdown 文档数量/体量/陈旧度，
            给出蒸馏/归档/退役建议（严格只读）。
  - delta : 实现 references/execution-safety.md §删除的验收口径 与 docs/design/execution-safety.md §7，
            在批前后采样卷 FreeSpace 与 <盘>:\$Recycle.Bin，输出「逻辑预估/实测释放/回收站」三栏与偏差核对。
  - rules : 只读读取 assets/cleanup-rules.json 声明式规则库，按探针与 does_not_touch 边界匹配本机候选路径，
            估算可回收体量并列出原生建议命令（绝不自动执行或修改文件）。
  - dupes : 四级漏斗只读查重（0 字节/云占位跳过 → 大小分组+NTFS 硬链接归簇 → 首尾 4KB 局部哈希 →
            流式全文件 SHA256），绝不触发云文件回源下载，绝不误判 hardlink 为可释放空间。
用法:
  powershell.exe -NoProfile -Command "& '.\scripts\probe.ps1' -Action env -OutDir '.\out' -WriteMarkdown"
  powershell.exe -NoProfile -Command "& '.\scripts\probe.ps1' -Action space -Roots @('D:\ProjA','E:\ProjB') -Baseline '.\out\baseline-20261117.json'"
  powershell.exe -NoProfile -Command "& '.\scripts\probe.ps1' -Action rules"
  powershell.exe -NoProfile -Command "& '.\scripts\probe.ps1' -Action dupes -Roots @('D:\Downloads') -MinSizeMB 10"
  powershell.exe -NoProfile -Command "& '.\scripts\probe.ps1' -Action docs -Roots @('D:\ProjA') -OutFile '.\hygiene.md'"
  .\scripts\probe.ps1 -Action delta -DeltaMode Snapshot -Drive E: -OutFile "$env:TEMP\before.json"
  .\scripts\probe.ps1 -Action delta -DeltaMode Compare -Drive E: -BeforeFile "$env:TEMP\before.json" -LogicalBytes 52428800
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("env","space","docs","delta","rules","dupes")]
  [string]$Action,

  [string[]]$Roots = @(),
  [string[]]$TopDirs = @(),
  [string]$OutDir = "",
  [string]$OutFile = "",
  [string]$Baseline = "",
  [ValidateSet("bootstrap","quick","full","maintain")][string]$Mode = "bootstrap",
  [string]$PreviousRunId = "",
  [double]$WarnPct = 15,
  [double]$CritPct = 10,
  [int]$MaxFilesPerDir = 200000,
  [string[]]$ExcludeNames = @("node_modules",".git","$Recycle.Bin","System Volume Information"),
  [string[]]$ExcludePaths = @(),
  [string[]]$AntivirusProcesses = @("360tray","HipsTray","QQPCTray","avp","MsMpEng","ekrn"),
  [string[]]$Roles = @("production-code"),
  [string[]]$DomainPacks = @(),
  [string]$ScopeNote = "",
  [switch]$WriteMarkdown,

  [int64]$LargeFileMinBytes = 104857600,
  [int]$TopLargeCount = 50,
  [int64]$MinSizeBytes = -1,
  [double]$MinSizeMB = -1,
  [double]$MinAgeDays = 0,
  [string[]]$IncludeExt = @(),
  [string[]]$ExcludeExt = @(),
  [string]$StreamOut = "",
  [switch]$Resume,
  [int]$TopDupesCount = 50,

  [string]$RulesFile = "",
  [string[]]$RuleIds = @(),

  [int]$DirThreshold = 200,
  [int]$FileLineThreshold = 3000,
  [int]$LogAgeDays = 30,
  [int]$ReportAgeDays = 90,

  [ValidateSet("","Snapshot","Compare")][string]$DeltaMode = "",
  [string]$Drive = "",
  [string]$BeforeFile = "",
  [int64]$LogicalBytes = 0,
  [switch]$QuarantineMode
)

$SKILL_VERSION = "1.0.1"
$SCHEMA_VERSION = "1.2"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Initialize-NativeFileHelper {
  if ('MaFileNativeV2' -as [type]) { return $true }
  try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MaFileNativeV2 {
  [StructLayout(LayoutKind.Sequential)]
  private struct FILETIME {
    public uint dwLowDateTime;
    public uint dwHighDateTime;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct BY_HANDLE_FILE_INFORMATION {
    public uint FileAttributes;
    public FILETIME CreationTime;
    public FILETIME LastAccessTime;
    public FILETIME LastWriteTime;
    public uint VolumeSerialNumber;
    public uint FileSizeHigh;
    public uint FileSizeLow;
    public uint NumberOfLinks;
    public uint FileIndexHigh;
    public uint FileIndexLow;
  }

  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  private static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);

  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  private static extern IntPtr CreateFileW(
    string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    IntPtr lpSecurityAttributes, uint dwCreationDisposition,
    uint dwFlagsAndAttributes, IntPtr hTemplateFile);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetFileInformationByHandle(
    IntPtr hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool CloseHandle(IntPtr hObject);

  public static long GetAllocatedBytes(string path, long fallbackLogical) {
    try {
      string p = path;
      if (!string.IsNullOrEmpty(p) && p.Length >= 248 && !p.StartsWith("\\\\?\\")) {
        p = "\\\\?\\" + p;
      }
      uint high;
      uint low = GetCompressedFileSizeW(p, out high);
      if (low == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) {
        return fallbackLogical;
      }
      return ((long)high << 32) | low;
    } catch {
      return fallbackLogical;
    }
  }

  public static string GetFileIdentityKey(string path) {
    IntPtr INVALID = new IntPtr(-1);
    IntPtr h = INVALID;
    try {
      string p = path;
      if (!string.IsNullOrEmpty(p) && p.Length >= 248 && !p.StartsWith("\\\\?\\")) {
        p = "\\\\?\\" + p;
      }
      h = CreateFileW(p, 0x0080, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
      if (h == INVALID || h == IntPtr.Zero) return null;
      BY_HANDLE_FILE_INFORMATION info;
      if (!GetFileInformationByHandle(h, out info)) return null;
      ulong idx = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
      return string.Format("{0:X8}:{1:X16}:{2}", info.VolumeSerialNumber, idx, info.NumberOfLinks);
    } catch {
      return null;
    } finally {
      if (h != INVALID && h != IntPtr.Zero) CloseHandle(h);
    }
  }
}
'@ -ErrorAction Stop | Out-Null
    return $true
  } catch {
    return $false
  }
}

$script:hasNativeSize = Initialize-NativeFileHelper

function Get-WinLongSafePath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
  if (-not $Path.StartsWith('\\?\') -and $Path -match '^[A-Za-z]:\\' -and ($Path.Length -ge 240 -or $Path -match '[\s\.]$')) {
    return ('\\?\' + $Path)
  }
  return $Path
}

function Resolve-WinCanonicalPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
  $t = $Path.TrimEnd('\')
  if ($t -match '^[A-Za-z]:$') { $t = $t + '\' }
  if ($t.Length -lt 240 -and -not $t.StartsWith('\\?\') -and ($t -notmatch '[\s\.]$')) {
    try {
      $t = [IO.Path]::GetFullPath($t)
      if ($t.Length -gt 3 -and ($t -notmatch '[\s\.]$')) { $t = $t.TrimEnd('\') }
    } catch { }
  }
  return $t
}

function Normalize-ExtList {
  param([string[]]$Exts)
  $out = New-Object System.Collections.ArrayList
  foreach ($x in @($Exts)) {
    if ([string]::IsNullOrWhiteSpace($x)) { continue }
    $t = $x.Trim().ToLowerInvariant()
    if (-not $t.StartsWith('.')) { $t = '.' + $t }
    if (-not ($out -contains $t)) { [void]$out.Add($t) }
  }
  return @($out.ToArray())
}

function Get-EffectiveMinSizeBytes {
  param([int64]$DefaultBytes)
  if ($MinSizeBytes -ge 0) { return [int64]$MinSizeBytes }
  if ($MinSizeMB -ge 0) { return [int64][math]::Round($MinSizeMB * 1MB) }
  return [int64]$DefaultBytes
}

function Test-FileMatchesFilter {
  param(
    [System.IO.FileInfo]$FileObj,
    [int64]$MinBytes = 0,
    [double]$MinAgeDaysVal = 0,
    [string[]]$IncExts = @(),
    [string[]]$ExcExts = @(),
    [datetime]$NowTime = (Get-Date)
  )
  if ($MinBytes -gt 0 -and [int64]$FileObj.Length -lt $MinBytes) { return $false }
  $ext = if ($FileObj.Extension) { $FileObj.Extension.ToLowerInvariant() } else { "" }
  if ($IncExts.Count -gt 0 -and -not ($IncExts -contains $ext)) { return $false }
  if ($ExcExts.Count -gt 0 -and ($ExcExts -contains $ext)) { return $false }
  if ($MinAgeDaysVal -gt 0) {
    $age = ($NowTime - $FileObj.LastWriteTime).TotalDays
    if ($age -lt $MinAgeDaysVal) { return $false }
  }
  return $true
}

function Get-FastScannerTools {
  $es = $null
  $wiz = $null
  $evGui = $null

  $c1 = Get-Command "es.exe" -EA SilentlyContinue
  if ($c1 -and $c1.Source) { $es = $c1.Source }
  foreach ($wc in @("wiztree64.exe", "wiztree.exe")) {
    $cw = Get-Command $wc -EA SilentlyContinue
    if ($cw -and $cw.Source) { $wiz = $cw.Source; break }
  }
  if (-not $wiz) {
    foreach ($wp in @("$env:ProgramFiles\WizTree\WizTree64.exe", "$env:ProgramFiles\WizTree\WizTree.exe")) {
      if ($wp -and (Test-Path -LiteralPath $wp)) { $wiz = $wp; break }
    }
  }
  foreach ($ep in @("$env:ProgramFiles\Everything\Everything.exe", "${env:ProgramFiles(x86)}\Everything\Everything.exe")) {
    if ($ep -and (Test-Path -LiteralPath $ep)) { $evGui = $ep; break }
  }

  # 补充：检测运行中进程路径与注册表安装位置（覆盖非默认盘/便携安装）
  if (-not $evGui) {
    try {
      $pEv = Get-Process -Name "Everything" -EA SilentlyContinue | Select-Object -First 1
      if ($pEv -and $pEv.Path) { $evGui = $pEv.Path }
    } catch { }
  }
  if (-not $evGui) {
    foreach ($rk in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Everything.exe", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Everything.exe")) {
      try {
        $rv = (Get-ItemProperty $rk -EA SilentlyContinue).'(default)'
        if ($rv -and (Test-Path -LiteralPath $rv)) { $evGui = $rv; break }
      } catch { }
    }
  }
  if (-not $evGui) {
    try {
      $evInst = (Get-ItemProperty "HKLM:\SOFTWARE\voidtools\Everything" -EA SilentlyContinue).InstallLocation
      if ($evInst) {
        $cand = Join-Path $evInst "Everything.exe"
        if (Test-Path -LiteralPath $cand) { $evGui = $cand }
      }
    } catch { }
  }
  if (-not $wiz) {
    try {
      $pWz = Get-Process -Name "WizTree64","WizTree" -EA SilentlyContinue | Select-Object -First 1
      if ($pWz -and $pWz.Path) { $wiz = $pWz.Path }
    } catch { }
  }
  if (-not $es -and $evGui) {
    try {
      $sibEs = Join-Path ([IO.Path]::GetDirectoryName($evGui)) "es.exe"
      if (Test-Path -LiteralPath $sibEs) { $es = $sibEs }
    } catch { }
  }

  return [ordered]@{
    everything_cli = $es
    everything_gui = $evGui
    wiztree        = $wiz
  }
}

function Get-FilePhysicalDetail {
  param([System.IO.FileInfo]$FileObj, [datetime]$NowTime)
  $attrInt = [int]$FileObj.Attributes
  $isSparse = ($attrInt -band 0x0200) -ne 0
  $isCloud = ($attrInt -band (0x1000 -bor 0x00040000 -bor 0x00400000)) -ne 0
  $logical = [int64]$FileObj.Length
  $alloc = if ($script:hasNativeSize) { [MaFileNativeV2]::GetAllocatedBytes($FileObj.FullName, $logical) } else { $logical }
  $ageDays = [math]::Round(($NowTime - $FileObj.LastWriteTime).TotalDays, 1)
  return [ordered]@{
    path                 = $FileObj.FullName
    logical_bytes        = $logical
    allocated_bytes      = $alloc
    is_sparse            = $isSparse
    is_cloud_placeholder = $isCloud
    last_write           = $FileObj.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:sszzz")
    age_days             = $ageDays
  }
}

function New-AgeSizeMatrix {
  return [ordered]@{
    lt_30d    = [ordered]@{ lt_1mb = [ordered]@{ files = 0; bytes = 0L }; mb1_to_100 = [ordered]@{ files = 0; bytes = 0L }; ge_100mb = [ordered]@{ files = 0; bytes = 0L } }
    d30_to_180= [ordered]@{ lt_1mb = [ordered]@{ files = 0; bytes = 0L }; mb1_to_100 = [ordered]@{ files = 0; bytes = 0L }; ge_100mb = [ordered]@{ files = 0; bytes = 0L } }
    gt_180d   = [ordered]@{ lt_1mb = [ordered]@{ files = 0; bytes = 0L }; mb1_to_100 = [ordered]@{ files = 0; bytes = 0L }; ge_100mb = [ordered]@{ files = 0; bytes = 0L } }
  }
}

function Update-AgeSizeMatrix {
  param($MatrixBuckets, [int64]$FileLength, [datetime]$LastWrite, [datetime]$NowRef)
  if ($null -eq $MatrixBuckets) { return }
  $ageDays = ($NowRef - $LastWrite).TotalDays
  $ageKey = if ($ageDays -lt 30) { "lt_30d" } elseif ($ageDays -le 180) { "d30_to_180" } else { "gt_180d" }
  $sizeKey = if ($FileLength -lt 1048576L) { "lt_1mb" } elseif ($FileLength -lt 104857600L) { "mb1_to_100" } else { "ge_100mb" }
  $cell = $MatrixBuckets[$ageKey][$sizeKey]
  $cell.files++
  $cell.bytes += $FileLength
}

function Merge-AgeSizeMatrix {
  param($TargetMatrix, $SourceMatrix)
  if ($null -eq $TargetMatrix -or $null -eq $SourceMatrix) { return }
  foreach ($ak in @("lt_30d","d30_to_180","gt_180d")) {
    $srcRow = $SourceMatrix.$ak
    if ($null -eq $srcRow) { continue }
    $dstRow = $TargetMatrix[$ak]
    foreach ($sk in @("lt_1mb","mb1_to_100","ge_100mb")) {
      $sc = $srcRow.$sk
      if ($null -eq $sc) { continue }
      $dstRow[$sk].files += [int]$sc.files
      $dstRow[$sk].bytes += [int64]$sc.bytes
    }
  }
}

function Test-StreamFilterCompatible {
  param($CachedFilters, [int64]$ReqMinBytes, [double]$ReqMinAgeDays, [string[]]$ReqIncExts, [string[]]$ReqExcExts)
  if ($null -eq $CachedFilters) { return $false }
  if ([int64]$CachedFilters.min_size_bytes -gt $ReqMinBytes) { return $false }
  if ([double]$CachedFilters.min_age_days -gt $ReqMinAgeDays) { return $false }
  $cInc = @($CachedFilters.include_ext | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
  if ($cInc.Count -gt 0) {
    if ($ReqIncExts.Count -eq 0) { return $false }
    foreach ($re in $ReqIncExts) {
      if (-not ($cInc -contains $re)) { return $false }
    }
  }
  $cExc = @($CachedFilters.exclude_ext | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
  foreach ($ce in $cExc) {
    if (-not ($ReqExcExts -contains $ce)) { return $false }
  }
  return $true
}

function Measure-DirSafe {
  param(
    [string]$TargetPath,
    [int]$LimitFiles,
    [string[]]$SkipNames,
    [int64]$LargeMinBytes = 0,
    [int]$MaxLargeKeep = 0,
    [System.Collections.ArrayList]$LargeCollector = $null,
    $MatrixBuckets = $null,
    [datetime]$NowRef = (Get-Date),
    [double]$FilterMinAgeDays = 0,
    [string[]]$FilterIncludeExts = @(),
    [string[]]$FilterExcludeExts = @()
  )
  $TargetPath = Resolve-WinCanonicalPath -Path $TargetPath
  $safeTarget = Get-WinLongSafePath -Path $TargetPath
  if (-not ((Test-Path -LiteralPath $TargetPath) -or [IO.Directory]::Exists($safeTarget))) {
    return [pscustomobject]@{
      path = $TargetPath; bytes = 0L; allocated_bytes = 0L; files = 0; sampled = $false; scan_status = "failed"
      note = "路径不存在"
    }
  }
  $rootDi = New-Object System.IO.DirectoryInfo $safeTarget
  if ($rootDi.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    return [pscustomobject]@{
      path = $TargetPath; bytes = 0L; allocated_bytes = 0L; files = 0; sampled = $false; scan_status = "ok"
      note = "重解析点（已跳过）"
    }
  }
  $sum = 0L; $allocSum = 0L; $cnt = 0; $rootFailed = $false; $partialErr = $false; $hitLimit = $false
  $stack = New-Object System.Collections.Stack
  $stack.Push($rootDi)
  while ($stack.Count -gt 0) {
    $di = $stack.Pop()
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
      $scanDi = if ($attempt -eq 0) { $di } else {
        New-Object System.IO.DirectoryInfo (Get-WinLongSafePath -Path $di.FullName)
      }
      try {
        foreach ($e in $scanDi.EnumerateFileSystemInfos('*', [IO.SearchOption]::TopDirectoryOnly)) {
          if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
          if ($e -is [IO.DirectoryInfo]) {
            $skip = $false
            foreach ($xn in $SkipNames) {
              if ($e.Name -ieq $xn) { $skip = $true; break }
            }
            if (-not $skip) { $stack.Push($e) }
          } else {
            $fLen = [int64]$e.Length
            $sum += $fLen
            $fAlloc = if ($script:hasNativeSize -and (([int]$e.Attributes -band (0x0200 -bor 0x0800)) -ne 0)) {
              [MaFileNativeV2]::GetAllocatedBytes($e.FullName, $fLen)
            } else { $fLen }
            $allocSum += $fAlloc
            $cnt++

            Update-AgeSizeMatrix -MatrixBuckets $MatrixBuckets -FileLength $fLen -LastWrite $e.LastWriteTime -NowRef $NowRef

            if ($null -ne $LargeCollector -and $LargeMinBytes -gt 0 -and $fLen -ge $LargeMinBytes) {
              if (Test-FileMatchesFilter -FileObj $e -MinBytes $LargeMinBytes -MinAgeDaysVal $FilterMinAgeDays -IncExts $FilterIncludeExts -ExcExts $FilterExcludeExts -NowTime $NowRef) {
                [void]$LargeCollector.Add((Get-FilePhysicalDetail -FileObj $e -NowTime $NowRef))
                if ($MaxLargeKeep -gt 0 -and $LargeCollector.Count -gt ($MaxLargeKeep * 4)) {
                  $kept = @($LargeCollector | Sort-Object { $_.logical_bytes } -Descending | Select-Object -First $MaxLargeKeep)
                  $LargeCollector.Clear()
                  foreach ($k in $kept) { [void]$LargeCollector.Add($k) }
                }
              }
            }

            if ($LimitFiles -gt 0 -and $cnt -ge $LimitFiles) {
              $hitLimit = $true
              break
            }
          }
        }
        break
      } catch {
        if ($attempt -eq 0 -and (Get-WinLongSafePath -Path $di.FullName) -ne $di.FullName) { continue }
        if ($di.FullName -eq $rootDi.FullName) { $rootFailed = $true }
        else { $partialErr = $true }
        break
      }
    }
    if ($hitLimit) { break }
  }
  if ($rootFailed) {
    return [pscustomobject]@{
      path = $TargetPath; bytes = 0L; allocated_bytes = 0L; files = 0; sampled = $false; scan_status = "failed"
      note = "根目录读取失败"
    }
  }
  if ($hitLimit -or $partialErr) {
    $why = if ($hitLimit) { "达到单目录上限 $LimitFiles 文件，已截断采样" } else { "部分子目录无权限或读取失败" }
    return [pscustomobject]@{
      path = $TargetPath; bytes = $sum; allocated_bytes = $allocSum; files = $cnt; sampled = $true; scan_status = "partial"
      note = $why
    }
  }
  return [pscustomobject]@{
    path = $TargetPath; bytes = $sum; allocated_bytes = $allocSum; files = $cnt; sampled = $false; scan_status = "ok"
    note = ""
  }
}

function Write-BaselineMarkdown {
  param(
    [string]$MdPath,
    [string]$Stamp,
    $BaselineObj
  )
  $avHits = @($BaselineObj.environment.antivirus)
  $avLabel = if ($avHits.Count -gt 0) { $avHits -join ',' } else { '未检出' }
  $priv = $BaselineObj.environment.privilege
  $meta = $BaselineObj.meta
  $mdLines = @(
    "# baseline-$Stamp · 本机基线（由 probe.ps1 生成）",
    "",
    ("- ``schema_version``: {0} | ``run_id``: {1} | ``generated_at``: {2} | ``scan_status``: {3}" -f $BaselineObj.schema_version, $meta.run_id, $meta.generated_at, $meta.scan_status),
    ("- ``admin``: {0} | ``LanguageMode``: {1} | ``PS``: {2} | ``AV``: {3}" -f $priv.admin, $priv.language_mode, $priv.ps_version, $avLabel),
    ("- ``scope_note``: {0}" -f $meta.scope_note),
    "",
    "## §Drives",
    "",
    "| 盘 | 总量(GB) | 剩余(GB) | 剩余% | 红线 |",
    "|---|---:|---:|---:|---|"
  )
  foreach ($d in @($BaselineObj.drives)) {
    $mdLines += "| $($d.id) | $([math]::Round($d.size_bytes/1GB,2)) | $([math]::Round($d.free_bytes/1GB,2)) | $($d.free_pct)% | $($d.redline) |"
  }
  $mdLines += @("", "## §TopDirs", "", "| 路径 | 体量(MB) | 文件数 | 采样 | 采集状态 | 归属定性 |", "|---|---:|---:|---|---|---|")
  foreach ($t in @($BaselineObj.top_dirs)) {
    $mdLines += "| $($t.path) | $([math]::Round($t.bytes/1MB,2)) | $($t.files) | $($t.sampled) | $($t.scan_status) | $($t.owner_note) |"
  }

  $spSnap = $null
  if ($BaselineObj -is [System.Collections.IDictionary]) {
    if ($BaselineObj.Contains("snapshots") -and $null -ne $BaselineObj["snapshots"]) {
      if ($BaselineObj["snapshots"] -is [System.Collections.IDictionary] -and $BaselineObj["snapshots"].Contains("space")) {
        $spSnap = $BaselineObj["snapshots"]["space"]
      } elseif ($null -ne $BaselineObj["snapshots"].PSObject.Properties["space"]) {
        $spSnap = $BaselineObj["snapshots"].space
      }
    }
  }
  if ($null -ne $spSnap) {
    $mdLines += @("", "## §SpaceBreakdown（年龄口径: $($spSnap.age_method)）", "", "| 年龄档 | <1MB (件/MB) | 1-100MB (件/MB) | >=100MB (件/GB) |", "|---|---|---|---|")
    $m = $spSnap.age_size_matrix
    foreach ($ak in @(@{k="lt_30d";l="<30 天"},@{k="d30_to_180";l="30–180 天"},@{k="gt_180d";l=">180 天"})) {
      $row = $m[$ak.k]
      $mdLines += ("| {0} | {1} / {2:N1} | {3} / {4:N1} | {5} / {6:N2} |" -f $ak.l, $row.lt_1mb.files, ($row.lt_1mb.bytes/1MB), $row.mb1_to_100.files, ($row.mb1_to_100.bytes/1MB), $row.ge_100mb.files, ($row.ge_100mb.bytes/1GB))
    }
    if (@($spSnap.top_large_files).Count -gt 0) {
      $mdLines += @("", "| 大文件 (>=Threshold) | 逻辑(MB) | 实占(MB) | 稀疏 | 云占位 | 年龄(天) |", "|---|---:|---:|---|---|---:|")
      foreach ($lf in @($spSnap.top_large_files)) {
        $mdLines += ("| ``{0}`` | {1:N2} | {2:N2} | {3} | {4} | {5} |" -f $lf.path, ($lf.logical_bytes/1MB), ($lf.allocated_bytes/1MB), $lf.is_sparse, $lf.is_cloud_placeholder, $lf.age_days)
      }
    }
    if (@($spSnap.volume_reconciliation).Count -gt 0) {
      $mdLines += @("", "| 位置 / 卷 | 口径 | 已枚举(GB) | 卷已用(GB) | 未归账 `<Unknown>` (GB / %) |", "|---|---|---:|---:|---|")
      foreach ($vr in @($spSnap.volume_reconciliation)) {
        $unLabel = if ($null -eq $vr.unaccounted_bytes) { "不适用（子树）" } else { "{0:N2} GB / {1}%" -f ($vr.unaccounted_bytes/1GB), $vr.unaccounted_pct }
        $usedLabel = if ($null -eq $vr.used_bytes) { "-" } else { "{0:N2}" -f ($vr.used_bytes/1GB) }
        $mdLines += ("| {0} | {1} | {2:N3} | {3} | {4} |" -f $vr.root, $vr.scope, ($vr.enumerated_bytes/1GB), $usedLabel, $unLabel)
      }
    }
    $rbList = @()
    if ($spSnap -is [System.Collections.IDictionary] -and $spSnap.Contains("recycle_bin")) { $rbList = @($spSnap["recycle_bin"]) }
    elseif ($null -ne $spSnap.PSObject.Properties["recycle_bin"]) { $rbList = @($spSnap.recycle_bin) }
    if ($rbList.Count -gt 0) {
      $mdLines += @("", "| `$Recycle.Bin` 盘 | 体量(GB) | 文件数 | 状态说明 |", "|---|---:|---:|---|")
      foreach ($rbItem in $rbList) {
        $rbStat = if (-not $rbItem.exists) { "无回收站目录" } elseif ($rbItem.restricted) { "部分受限" } elseif ($rbItem.bytes -gt 0) { "待确认（清零须单独授权 Batch 3）" } else { "空" }
        $mdLines += ("| {0} | {1:N3} | {2} | {3} |" -f $rbItem.drive, ($rbItem.bytes/1GB), $rbItem.files, $rbStat)
      }
    }
    $hfList = @()
    if ($spSnap -is [System.Collections.IDictionary] -and $spSnap.Contains("hygiene_flags")) { $hfList = @($spSnap["hygiene_flags"]) }
    elseif ($null -ne $spSnap.PSObject.Properties["hygiene_flags"]) { $hfList = @($spSnap.hygiene_flags) }
    if ($hfList.Count -gt 0) {
      $mdLines += @("", "| 根卫生提示 | 路径 / 位置 | 说明 |", "|---|---|---|")
      foreach ($hf in $hfList) {
        $mdLines += ("| {0} | ``{1}`` | {2} |" -f $hf.kind, $hf.path, $hf.note)
      }
    }
  }
  [IO.File]::WriteAllText($MdPath, ($mdLines -join "`r`n"), $utf8Bom)
}

function Test-DriveNorm([string]$d) {
  $t = $d.Trim().TrimEnd('\')
  if ($t -notmatch '^[A-Za-z]:$') { return $null }
  return $t.ToUpperInvariant()
}

function Get-VolumeMetrics([string]$d) {
  $v = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$d'" -EA SilentlyContinue
  if (-not $v -or -not $v.Size) { return $null }
  return [pscustomobject]@{ drive = $d; size_bytes = [int64]$v.Size; free_bytes = [int64]$v.FreeSpace }
}

function Get-RecycleBinMetrics([string]$d) {
  $rbRoot = Join-Path ($d + '\') '$Recycle.Bin'
  $sum = 0L; $files = 0; $restricted = $false
  if (-not (Test-Path -LiteralPath $rbRoot)) {
    return [pscustomobject]@{ exists = $false; bytes = 0L; files = 0; restricted = $false }
  }
  $stack = New-Object System.Collections.Stack
  $stack.Push((New-Object System.IO.DirectoryInfo $rbRoot))
  while ($stack.Count -gt 0) {
    $di = $stack.Pop()
    try {
      foreach ($e in $di.EnumerateFileSystemInfos('*', [IO.SearchOption]::TopDirectoryOnly)) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($e -is [IO.DirectoryInfo]) { $stack.Push($e) }
        else { $sum += $e.Length; $files++ }
      }
    } catch { $restricted = $true }
  }
  return [pscustomobject]@{ exists = $true; bytes = $sum; files = $files; restricted = $restricted }
}

function Test-PseudoEmptyAgentShell([string]$DirPath) {
  $name = Split-Path $DirPath -Leaf
  $isTs = ($name -match '^\d{4}[-_]\d{2}[-_]\d{2}([-_]\d{2}){1,3}$')
  $agentDirs = @(".workbuddy",".claude",".codex",".reasonix",".smart-env",".agent",".cursor",".gemini")
  $safe = Get-WinLongSafePath -Path $DirPath
  $rDi = try { New-Object System.IO.DirectoryInfo $safe } catch { $null }
  if (-not $rDi -or -not $rDi.Exists -or ($rDi.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    return [pscustomobject]@{ is_pseudo_empty = $false; is_timestamp_name = $isTs; file_count = 0; bytes = 0L; reason = "" }
  }
  $prefixLen = $rDi.FullName.TrimEnd('\').Length
  $stk = New-Object System.Collections.Stack
  $stk.Push($rDi)
  $fc = 0; [int64]$tot = 0L; $dirsVisited = 0; $allMeta = $true
  while ($stk.Count -gt 0) {
    $cur = $stk.Pop()
    $dirsVisited++
    if ($dirsVisited -gt 24) { $allMeta = $false; break }
    try {
      foreach ($e in $cur.EnumerateFileSystemInfos('*', [IO.SearchOption]::TopDirectoryOnly)) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($e -is [IO.DirectoryInfo]) {
          $stk.Push($e)
        } else {
          $fc++
          $tot += [int64]$e.Length
          $rel = if ($e.FullName.Length -gt ($prefixLen + 1)) { $e.FullName.Substring($prefixLen + 1) } else { $e.Name }
          $topSeg = ($rel -split '[\\/]')[0]
          if (-not ($rel -match '[\\/]' -and ($agentDirs -contains $topSeg.ToLowerInvariant())) -or $fc -gt 15 -or $tot -ge 65536) {
            $allMeta = $false
            break
          }
        }
      }
    } catch { $allMeta = $false; break }
    if (-not $allMeta) { break }
  }
  $hit = ($allMeta -and (($isTs -and $fc -eq 0) -or ($fc -gt 0 -and $tot -lt 65536)))
  $why = if (-not $hit) { "" } elseif ($fc -eq 0) { "纯时间戳空目录（疑似 WorkBuddy/IDE 遗留会话壳，核查客户端默认工作区设置）" } elseif ($isTs) { "纯时间戳+仅含<64KB Agent 元数据伪空壳（$fc 文件/$tot B）" } else { "仅含<64KB Agent 元数据伪空壳（$fc 文件/$tot B，非真实业务项目）" }
  return [pscustomobject]@{ is_pseudo_empty = $hit; is_timestamp_name = $isTs; file_count = $fc; bytes = $tot; reason = $why }
}

function Invoke-EnvAction {
  $ErrorActionPreference = "Continue"
  $runId = Get-Date -Format "yyyyMMdd-HHmmssfff"
  $stamp = Get-Date -Format "yyyyMMdd"
  $genAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
  $restrictions = New-Object System.Collections.ArrayList

  $psVer = "$($PSVersionTable.PSVersion)"
  $langMode = "$($ExecutionContext.SessionState.LanguageMode)"
  $isAdmin = $false
  try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { $isAdmin = $false }

  $osCim = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue
  $caption = if ($osCim -and $osCim.Caption) { "$($osCim.Caption)".Trim() } else { "Windows" }
  $build = if ($osCim -and $osCim.BuildNumber) { "$($osCim.BuildNumber)".Trim() } else { "0" }
  $locale = if ($osCim -and -not [string]::IsNullOrWhiteSpace("$($osCim.OSLocale)")) {
    "$($osCim.OSLocale)".Trim()
  } else {
    [Globalization.CultureInfo]::CurrentUICulture.Name
  }

  $usf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -EA SilentlyContinue
  $desk = if ($usf -and $usf.Desktop) { "$($usf.Desktop)" } else { "" }
  $pers = if ($usf -and $usf.Personal) { "$($usf.Personal)" } else { "" }
  $pics = if ($usf -and $usf.'My Pictures') { "$($usf.'My Pictures')" } else { "" }
  $kfm = ($desk -like "*OneDrive*") -or ($pers -like "*OneDrive*")

  $avHits = @()
  try {
    $avHits = @(Get-Process -EA SilentlyContinue | Where-Object { $AntivirusProcesses -contains $_.Name } | Select-Object -ExpandProperty Name -Unique)
  } catch { $avHits = @() }

  if (-not $isAdmin) {
    [void]$restrictions.Add([ordered]@{
      kind = "permission"; scope = "非管理员运行"
      note = "未提权运行，系统目录、服务与部分 ACL 检查受限"; affects = @("02","07","08","15")
    })
  }
  if ($langMode -ne "FullLanguage") {
    [void]$restrictions.Add([ordered]@{
      kind = "clm"; scope = "PowerShell LanguageMode=$langMode"
      note = "受限语言模式下部分 .NET 检查不可用"; affects = @("00","02","15")
    })
  }
  if ($avHits.Count -gt 0) {
    [void]$restrictions.Add([ordered]@{
      kind = "antivirus"; scope = "检测到杀软/EDR进程: $($avHits -join ',')"
      note = "安全软件驻留时枚举与行为检测可能不完整"; affects = @("02","07","15")
    })
  }

  $drives = New-Object System.Collections.ArrayList
  $vols = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -EA SilentlyContinue)
  $sysDrvUpper = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\').ToUpperInvariant() } else { "C:" }
  $sysVol = $vols | Where-Object { "$($_.DeviceID)".ToUpperInvariant() -eq $sysDrvUpper } | Select-Object -First 1
  foreach ($v in $vols) {
    if (-not $v.Size -or [int64]$v.Size -le 0) { continue }
    $sz = [int64]$v.Size
    $fr = [int64]$v.FreeSpace
    $pct = [math]::Round(($fr / $sz) * 100, 1)
    $red = if ($pct -lt $CritPct) { "critical" } elseif ($pct -lt $WarnPct) { "warn" } else { "ok" }
    $dObj = [ordered]@{
      id = "$($v.DeviceID)"; size_bytes = $sz; free_bytes = $fr; free_pct = [double]$pct; online = $true; redline = $red
    }
    if (-not [string]::IsNullOrWhiteSpace("$($v.VolumeName)")) {
      $dObj.label = "$($v.VolumeName)".Trim()
    }
    $isCloudMounted = $false
    if ("$($v.VolumeName)" -match '(?i)Google\s*Drive|OneDrive|iCloud|Dropbox') { $isCloudMounted = $true }
    elseif ("$($v.FileSystem)" -match '(?i)WinFsp|Dokan|FUSE') { $isCloudMounted = $true }
    elseif ($sysVol -and "$($v.DeviceID)".ToUpperInvariant() -ne $sysDrvUpper -and [int64]$sysVol.Size -eq $sz -and [math]::Abs([int64]$sysVol.FreeSpace - $fr) -le 104857600L -and "$($v.FileSystem)" -ieq "FAT32") {
      $isCloudMounted = $true
    }
    if ($isCloudMounted) {
      $dObj.note = "疑似虚拟/云端挂载卷（文件系统 $($v.FileSystem)，请核对是否与本地卷共享容量防重复计容）"
    }
    [void]$drives.Add($dObj)
  }

  $effScope = if ([string]::IsNullOrWhiteSpace($ScopeNote)) {
    "仅环境与卷账目（待按需运行 -Action space 枚举 top_dirs）"
  } else { $ScopeNote }

  $baselineObj = [ordered]@{
    schema_version = $SCHEMA_VERSION
    meta = [ordered]@{
      run_id          = $runId
      generated_at    = $genAt
      skill_version   = $SKILL_VERSION
      mode            = $Mode
      scan_status     = "ok"
      previous_run_id = if ([string]::IsNullOrWhiteSpace($PreviousRunId)) { $null } else { $PreviousRunId }
      scope_note      = $effScope
    }
    environment = [ordered]@{
      os = [ordered]@{ caption = $caption; build = $build; locale = $locale }
      user = [ordered]@{ name = "$env:USERNAME"; profile_path = "$env:USERPROFILE" }
      privilege = [ordered]@{ admin = [bool]$isAdmin; language_mode = $langMode; ps_version = $psVer }
      antivirus = @($avHits)
      cloud_redirection = [ordered]@{ kfm_active = [bool]$kfm; desktop = $desk; personal = $pers; pictures = $pics }
    }
    drives       = @($drives.ToArray())
    top_dirs     = @()
    persona      = [ordered]@{ roles = @($Roles) }
    domains      = [ordered]@{ packs = @($DomainPacks) }
    restrictions = @($restrictions.ToArray())
    snapshots    = [ordered]@{ fast_scanners = Get-FastScannerTools }
  }

  $jsonText = $baselineObj | ConvertTo-Json -Depth 10
  if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
    if (-not (Test-Path -LiteralPath $OutDir)) { [void][IO.Directory]::CreateDirectory($OutDir) }
    $jsonPath = Join-Path $OutDir "baseline-$stamp.json"
    [IO.File]::WriteAllText($jsonPath, $jsonText, $utf8NoBom)
    Write-Host "已生成基线 JSON: $jsonPath (scan_status=ok, top_dirs=0)"
    if ($WriteMarkdown) {
      $mdPath = Join-Path $OutDir "baseline-$stamp.md"
      Write-BaselineMarkdown -MdPath $mdPath -Stamp $stamp -BaselineObj $baselineObj
      Write-Host "已生成人读视图: $mdPath"
    }
  } else {
    Write-Output $jsonText
  }
}

function Invoke-SpaceAction {
  $ErrorActionPreference = "Continue"
  $stamp = Get-Date -Format "yyyyMMdd"
  $nowTs = Get-Date
  $genAt = $nowTs.ToString("yyyy-MM-ddTHH:mm:sszzz")
  $spaceRestrictions = New-Object System.Collections.ArrayList

  $effLargeMinBytes = Get-EffectiveMinSizeBytes -DefaultBytes $LargeFileMinBytes
  $incExts = Normalize-ExtList -Exts $IncludeExt
  $excExts = Normalize-ExtList -Exts $ExcludeExt
  $fastTools = Get-FastScannerTools

  $streamCompleted = @{}
  $resumedCount = 0
  if (-not [string]::IsNullOrWhiteSpace($StreamOut)) {
    $streamDir = [IO.Path]::GetDirectoryName($StreamOut)
    if ($streamDir -and -not (Test-Path -LiteralPath $streamDir)) { New-Item -ItemType Directory -Path $streamDir -Force | Out-Null }
    if ($Resume -and (Test-Path -LiteralPath $StreamOut)) {
      foreach ($sl in @(Get-Content -LiteralPath $StreamOut -Encoding UTF8 -EA SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($sl)) { continue }
        try {
          $rec = $sl | ConvertFrom-Json
          if ($rec -and "$($rec.scan_status)" -eq "ok" -and -not [string]::IsNullOrWhiteSpace("$($rec.path)")) {
            $k = (Resolve-WinCanonicalPath -Path "$($rec.path)").ToLowerInvariant()
            $streamCompleted[$k] = $rec
          }
        } catch { }
      }
    } elseif (-not $Resume -and (Test-Path -LiteralPath $StreamOut)) {
      [IO.File]::WriteAllText($StreamOut, "", $utf8NoBom)
    }
  }

  $appliedFilters = [ordered]@{
    min_size_bytes = $effLargeMinBytes
    min_age_days   = $MinAgeDays
    include_ext    = @($incExts)
    exclude_ext    = @($excExts)
  }
  $matrix = New-AgeSizeMatrix
  $largePool = New-Object System.Collections.ArrayList
  $topDirItems = New-Object System.Collections.ArrayList
  $overallScanStatus = "ok"
  $streamBypassedCount = 0
  [int64]$totalAllocBytes = 0L
  [int64]$totalLogicalBytes = 0L

  $targetDirs = New-Object System.Collections.ArrayList
  $rootMeta = @{}
  $scannedDrives = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $hygieneFlags = New-Object System.Collections.ArrayList
  $anchorRootFiles = @("AGENTS.md","CLAUDE.md","GEMINI.md","README.md",".gitignore",".gitattributes",".editorconfig","LICENSE","desktop.ini","thumbs.db","pagefile.sys","hiberfil.sys","swapfile.sys")

  foreach ($td in $TopDirs) {
    if (-not [string]::IsNullOrWhiteSpace($td)) {
      $cTd = Resolve-WinCanonicalPath -Path $td
      [void]$targetDirs.Add($cTd)
      if ($cTd -match '^([A-Za-z]:)') { [void]$scannedDrives.Add($Matches[1].ToUpperInvariant()) }
    }
  }
  foreach ($r in $Roots) {
    if ([string]::IsNullOrWhiteSpace($r)) { continue }
    if ($r -match '^([A-Za-z]:)') { [void]$scannedDrives.Add($Matches[1].ToUpperInvariant()) }
    if (-not ((Test-Path -LiteralPath $r) -or [IO.Directory]::Exists((Get-WinLongSafePath $r)))) {
      $overallScanStatus = "failed"
      [void]$spaceRestrictions.Add([ordered]@{
        kind = "offline"; scope = $r; note = "指定扫描根目录不存在或离线"; affects = @("02")
      })
      [void]$topDirItems.Add([ordered]@{
        path = $r; bytes = 0L; files = 0; sampled = $false; scan_status = "failed"; owner_note = "待用户定性"
      })
      continue
    }
    $rNorm = Resolve-WinCanonicalPath -Path $r
    $rSafe = Get-WinLongSafePath $rNorm
    $rootFilesBytes = 0L; $rootFilesAlloc = 0L; $rootFilesCount = 0
    $looseFilesInRoot = New-Object System.Collections.ArrayList
    $gitChildCount = 0
    try {
      $rdi = New-Object System.IO.DirectoryInfo $rSafe
      foreach ($rf in $rdi.EnumerateFiles('*', [IO.SearchOption]::TopDirectoryOnly)) {
        if ($rf.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $rLen = [int64]$rf.Length
        $rAlloc = if ($script:hasNativeSize -and (([int]$rf.Attributes -band (0x0200 -bor 0x0800)) -ne 0)) {
          [MaFileNativeV2]::GetAllocatedBytes($rf.FullName, $rLen)
        } else { $rLen }
        $rootFilesBytes += $rLen
        $rootFilesAlloc += $rAlloc
        $rootFilesCount++
        if ($rf.Name -match '[\x00-\x1F\?\<\>\|]' -or $rf.Name -match '[ \.]$') {
          [void]$hygieneFlags.Add([ordered]@{ kind = "weird-name"; path = $rf.FullName; note = "文件名含控制字符或尾随空格/点号，需 \\\\?\\ 前缀安全处置" })
        }
        if (-not ($anchorRootFiles -contains $rf.Name)) { [void]$looseFilesInRoot.Add($rf.Name) }
        Update-AgeSizeMatrix -MatrixBuckets $matrix -FileLength $rLen -LastWrite $rf.LastWriteTime -NowRef $nowTs
        if ($effLargeMinBytes -gt 0 -and $rLen -ge $effLargeMinBytes) {
          if (Test-FileMatchesFilter -FileObj $rf -MinBytes $effLargeMinBytes -MinAgeDaysVal $MinAgeDays -IncExts $incExts -ExcExts $excExts -NowTime $nowTs) {
            [void]$largePool.Add((Get-FilePhysicalDetail -FileObj $rf -NowTime $nowTs))
          }
        }
      }
    } catch {
      if ($overallScanStatus -ne "failed") { $overallScanStatus = "partial" }
      [void]$spaceRestrictions.Add([ordered]@{
        kind = "permission"; scope = $rNorm; note = "根目录直属文件枚举受限: $($_.Exception.Message)"; affects = @("02")
      })
    }
    $totalLogicalBytes += $rootFilesBytes
    $totalAllocBytes += $rootFilesAlloc
    $rootMeta[$r] = [ordered]@{ norm = $rNorm; root_files_bytes = $rootFilesBytes; root_files_count = $rootFilesCount; children_sum = 0L }

    $children = try {
      $rdiKids = New-Object System.IO.DirectoryInfo $rSafe
      @($rdiKids.EnumerateDirectories('*', [IO.SearchOption]::TopDirectoryOnly))
    } catch { @() }
    foreach ($c in $children) {
      if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      $cFullClean = if ($c.FullName.StartsWith('\\?\')) { $c.FullName.Substring(4) } else { $c.FullName }
      if ($c.Name -match '[\x00-\x1F\?\<\>\|]' -or $c.Name -match '[ \.]$') {
        [void]$hygieneFlags.Add([ordered]@{ kind = "weird-name"; path = $cFullClean; note = "目录名含控制字符或尾随空格/点号，须用 \\\\?\\ 前缀安全改名或清理" })
      }
      $cGitSafe = Get-WinLongSafePath (Join-Path $cFullClean ".git")
      if ((Test-Path -LiteralPath (Join-Path $cFullClean ".git")) -or [IO.Directory]::Exists($cGitSafe) -or [IO.File]::Exists($cGitSafe)) {
        $gitChildCount++
      }
      $skip = $false
      foreach ($xn in $ExcludeNames) {
        if ($c.Name -ieq $xn) { $skip = $true; break }
      }
      if (-not $skip) {
        foreach ($ep in $ExcludePaths) {
          if (-not [string]::IsNullOrWhiteSpace($ep) -and ((Resolve-WinCanonicalPath -Path $cFullClean) -ieq (Resolve-WinCanonicalPath -Path $ep))) { $skip = $true; break }
        }
      }
      if (-not $skip) {
        $pe = Test-PseudoEmptyAgentShell -DirPath $cFullClean
        if ($pe.is_pseudo_empty) {
          $hKind = if ($pe.is_timestamp_name) { "timestamp-shell" } else { "agent-pseudo-empty-shell" }
          [void]$hygieneFlags.Add([ordered]@{ kind = $hKind; path = $cFullClean; note = $pe.reason })
        }
        [void]$targetDirs.Add((Resolve-WinCanonicalPath -Path $cFullClean))
      }
    }
    if ($gitChildCount -ge 2 -and $looseFilesInRoot.Count -gt 0) {
      [void]$hygieneFlags.Add([ordered]@{ kind = "portfolio-loose-files"; path = $rNorm; note = "多项目容器根一级存在散落文件: $($looseFilesInRoot -join ', ')" })
    }
  }

  foreach ($td in $targetDirs) {
    $tdKey = (Resolve-WinCanonicalPath -Path "$td").ToLowerInvariant()
    if ($Resume -and $streamCompleted.ContainsKey($tdKey)) {
      $cached = $streamCompleted[$tdKey]
      $hasMatrix = ($null -ne $cached.PSObject.Properties["dir_matrix"] -and $null -ne $cached.dir_matrix)
      $compatOk = $hasMatrix -and (Test-StreamFilterCompatible -CachedFilters $cached.stream_filters -ReqMinBytes $effLargeMinBytes -ReqMinAgeDays $MinAgeDays -ReqIncExts $incExts -ReqExcExts $excExts)
      if ($compatOk) {
        $resumedCount++
        [void]$topDirItems.Add([ordered]@{
          path = "$($cached.path)"; bytes = [int64]$cached.bytes; files = [int]$cached.files; sampled = [bool]$cached.sampled
          scan_status = "$($cached.scan_status)"; owner_note = "待用户定性"
        })
        $totalLogicalBytes += [int64]$cached.bytes
        $totalAllocBytes += if ($null -ne $cached.PSObject.Properties["allocated_bytes"] -and $null -ne $cached.allocated_bytes) { [int64]$cached.allocated_bytes } else { [int64]$cached.bytes }
        Merge-AgeSizeMatrix -TargetMatrix $matrix -SourceMatrix $cached.dir_matrix
        if ($null -ne $cached.PSObject.Properties["dir_large_files"] -and $null -ne $cached.dir_large_files) {
          foreach ($clf in @($cached.dir_large_files)) {
            if ($null -eq $clf -or [int64]$clf.logical_bytes -lt $effLargeMinBytes) { continue }
            $cExt = [IO.Path]::GetExtension("$($clf.path)").ToLowerInvariant()
            if ($incExts.Count -gt 0 -and -not ($incExts -contains $cExt)) { continue }
            if ($excExts.Count -gt 0 -and ($excExts -contains $cExt)) { continue }
            if ($MinAgeDays -gt 0 -and [double]$clf.age_days -lt $MinAgeDays) { continue }
            [void]$largePool.Add($clf)
          }
        }
        foreach ($rk in @($rootMeta.Keys)) {
          $rn = $rootMeta[$rk].norm.TrimEnd('\')
          $mp = [IO.Path]::GetDirectoryName("$($cached.path)".TrimEnd('\'))
          if ($mp -and ($mp.TrimEnd('\') -ieq $rn)) {
            $rootMeta[$rk].children_sum += [int64]$cached.bytes
          }
        }
        continue
      } else {
        $streamBypassedCount++
      }
    }

    $dirMatrix = New-AgeSizeMatrix
    $dirLarge = New-Object System.Collections.ArrayList
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $m = Measure-DirSafe -TargetPath $td -LimitFiles $MaxFilesPerDir -SkipNames $ExcludeNames `
      -LargeMinBytes $effLargeMinBytes -MaxLargeKeep $TopLargeCount `
      -LargeCollector $dirLarge -MatrixBuckets $dirMatrix -NowRef $nowTs `
      -FilterMinAgeDays $MinAgeDays -FilterIncludeExts $incExts -FilterExcludeExts $excExts
    $sw.Stop()

    Merge-AgeSizeMatrix -TargetMatrix $matrix -SourceMatrix $dirMatrix
    foreach ($dl in $dirLarge) { [void]$largePool.Add($dl) }
    if ($TopLargeCount -gt 0 -and $largePool.Count -gt ($TopLargeCount * 4)) {
      $keptPool = @($largePool | Sort-Object { $_.logical_bytes } -Descending | Select-Object -First $TopLargeCount)
      $largePool.Clear()
      foreach ($kp in $keptPool) { [void]$largePool.Add($kp) }
    }
    $totalLogicalBytes += [int64]$m.bytes
    $totalAllocBytes += [int64]$m.allocated_bytes

    if ($m.scan_status -eq "failed") {
      $overallScanStatus = "failed"
      [void]$spaceRestrictions.Add([ordered]@{
        kind = "unknown"; scope = $m.path; note = "目录枚举失败: $($m.note)"; affects = @("02")
      })
    } elseif ($m.scan_status -eq "partial") {
      if ($overallScanStatus -ne "failed") { $overallScanStatus = "partial" }
      [void]$spaceRestrictions.Add([ordered]@{
        kind = "permission"; scope = $m.path; note = "部分采集（sampled=true）: $($m.note)"; affects = @("02")
      })
    }
    $entry = [ordered]@{
      path = $m.path; bytes = [int64]$m.bytes; files = [int]$m.files; sampled = [bool]$m.sampled
      scan_status = $m.scan_status; owner_note = "待用户定性"
    }
    [void]$topDirItems.Add($entry)

    if (-not [string]::IsNullOrWhiteSpace($StreamOut)) {
      $streamRec = [ordered]@{
        timestamp       = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
        path            = $m.path
        bytes           = [int64]$m.bytes
        allocated_bytes = [int64]$m.allocated_bytes
        files           = [int]$m.files
        sampled         = [bool]$m.sampled
        scan_status     = $m.scan_status
        elapsed_ms      = [int64]$sw.ElapsedMilliseconds
        stream_filters  = $appliedFilters
        dir_matrix      = $dirMatrix
        dir_large_files = @($dirLarge.ToArray())
      }
      $lineJson = ($streamRec | ConvertTo-Json -Depth 8 -Compress)
      $swOut = New-Object System.IO.StreamWriter($StreamOut, $true, $utf8NoBom)
      try { $swOut.WriteLine($lineJson); $swOut.Flush() } finally { $swOut.Dispose() }
    }

    foreach ($rk in @($rootMeta.Keys)) {
      $rn = $rootMeta[$rk].norm.TrimEnd('\')
      $mp = [IO.Path]::GetDirectoryName($m.path.TrimEnd('\'))
      if ($mp -and ($mp.TrimEnd('\') -ieq $rn)) {
        $rootMeta[$rk].children_sum += [int64]$m.bytes
      }
    }
  }

  $topLargeOut = @($largePool | Sort-Object { $_.logical_bytes } -Descending | Select-Object -First $TopLargeCount)
  $volReconcile = New-Object System.Collections.ArrayList
  foreach ($rk in $rootMeta.Keys) {
    $rm = $rootMeta[$rk]
    $enumTotal = [int64]$rm.children_sum + [int64]$rm.root_files_bytes
    if ($rm.norm -match '^([A-Za-z]:)\\$') {
      $drvId = $Matches[1].ToUpperInvariant()
      $vm = Get-VolumeMetrics $drvId
      if ($vm) {
        $usedBytes = [int64]$vm.size_bytes - [int64]$vm.free_bytes
        $unaccBytes = [math]::Max(0L, $usedBytes - $enumTotal)
        $unaccPct = if ($usedBytes -gt 0) { [math]::Round(($unaccBytes / $usedBytes) * 100, 1) } else { 0.0 }
        [void]$volReconcile.Add([ordered]@{
          root              = $rm.norm
          drive             = $drvId
          scope             = "drive-root"
          size_bytes        = $vm.size_bytes
          used_bytes        = $usedBytes
          enumerated_bytes  = $enumTotal
          root_files_bytes  = [int64]$rm.root_files_bytes
          unaccounted_bytes = $unaccBytes
          unaccounted_pct   = $unaccPct
          note              = "Unaccounted(<Unknown>) 含系统卷影(VSS)/System Volume Information/权限受限/硬链接/已排除项($($ExcludeNames -join ','))"
        })
      }
    } else {
      [void]$volReconcile.Add([ordered]@{
        root              = $rm.norm
        drive             = $null
        scope             = "directory-subtree"
        size_bytes        = $null
        used_bytes        = $null
        enumerated_bytes  = $enumTotal
        root_files_bytes  = [int64]$rm.root_files_bytes
        unaccounted_bytes = $null
        unaccounted_pct   = $null
        note              = "子目录树汇总（含一级子目录与根目录直属文件；跳过 ReparsePoint 与已排除项）"
      })
    }
  }

  $sparseSavings = [math]::Max(0L, ($totalLogicalBytes - $totalAllocBytes))
  $effScope = if (-not [string]::IsNullOrWhiteSpace($ScopeNote)) {
    $ScopeNote
  } elseif ($targetDirs.Count -eq 0 -and $spaceRestrictions.Count -eq 0) {
    "未传 -Roots/-TopDirs，top_dirs 为空"
  } else {
    $rNote = if ($resumedCount -gt 0) { "；断点续扫跳过已完成 $resumedCount 项" } else { "" }
    "受控目录采集: $($targetDirs.Count) 个顶层目录（跳过 ReparsePoint，单目录上限 $MaxFilesPerDir 文件$rNote）"
  }

  $recycleBinSummary = New-Object System.Collections.ArrayList
  foreach ($sDrv in ($scannedDrives | Sort-Object)) {
    $rbM = Get-RecycleBinMetrics $sDrv
    [void]$recycleBinSummary.Add([ordered]@{
      drive      = $sDrv
      exists     = [bool]$rbM.exists
      bytes      = [int64]$rbM.bytes
      files      = [int]$rbM.files
      restricted = [bool]$rbM.restricted
    })
  }

  $spaceDiagnostics = [ordered]@{
    generated_at                      = $genAt
    age_method                        = "LastWriteTime"
    large_file_min_bytes              = $effLargeMinBytes
    applied_filters                   = $appliedFilters
    total_logical_bytes               = $totalLogicalBytes
    total_allocated_bytes             = $totalAllocBytes
    sparse_or_compressed_savings_bytes = $sparseSavings
    resumed_from_stream_count         = $resumedCount
    stream_cache_bypassed_count       = $streamBypassedCount
    age_size_matrix                   = $matrix
    top_large_files                   = @($topLargeOut)
    volume_reconciliation             = @($volReconcile.ToArray())
    recycle_bin                       = @($recycleBinSummary.ToArray())
    hygiene_flags                     = @($hygieneFlags.ToArray())
  }

  if (-not [string]::IsNullOrWhiteSpace($Baseline)) {
    if (-not (Test-Path -LiteralPath $Baseline)) {
      Write-Host "FAIL  基线文件不存在: $Baseline" -ForegroundColor Red
      exit 1
    }
    $baseObj = Get-Content -LiteralPath $Baseline -Raw -Encoding UTF8 | ConvertFrom-Json
    $mergedRestrictions = New-Object System.Collections.ArrayList
    foreach ($er in @($baseObj.restrictions)) {
      if ($null -eq $er) { continue }
      $isSpaceR = ("$($er.note)" -like "部分采集（sampled=true）*" -or "$($er.note)" -like "目录枚举失败:*" -or "$($er.note)" -eq "指定扫描根目录不存在或离线")
      if (-not $isSpaceR) {
        [void]$mergedRestrictions.Add($er)
      }
    }
    foreach ($sr in $spaceRestrictions) { [void]$mergedRestrictions.Add($sr) }

    $metaOut = [ordered]@{
      run_id          = $baseObj.meta.run_id
      generated_at    = $baseObj.meta.generated_at
      skill_version   = $baseObj.meta.skill_version
      mode            = $baseObj.meta.mode
      scan_status     = $overallScanStatus
      previous_run_id = $baseObj.meta.previous_run_id
      scope_note      = $effScope
    }
    $snapsOut = [ordered]@{}
    if ($null -ne $baseObj.PSObject.Properties["snapshots"] -and $null -ne $baseObj.snapshots) {
      foreach ($p in $baseObj.snapshots.PSObject.Properties) {
        $snapsOut[$p.Name] = $p.Value
      }
    }
    $snapsOut["space"] = $spaceDiagnostics
    $snapsOut["fast_scanners"] = $fastTools

    $outBaseline = [ordered]@{
      schema_version = $baseObj.schema_version
      meta           = $metaOut
      environment    = $baseObj.environment
      drives         = @($baseObj.drives)
      top_dirs       = @($topDirItems.ToArray())
      persona        = $baseObj.persona
      domains        = $baseObj.domains
      restrictions   = @($mergedRestrictions.ToArray())
      snapshots      = $snapsOut
    }
    if ($null -ne $baseObj.PSObject.Properties["network"]) {
      $outBaseline.network = $baseObj.network
    }

    $targetJson = if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
      if (-not (Test-Path -LiteralPath $OutDir)) { [void][IO.Directory]::CreateDirectory($OutDir) }
      Join-Path $OutDir "baseline-$stamp.json"
    } else { $Baseline }

    [IO.File]::WriteAllText($targetJson, ($outBaseline | ConvertTo-Json -Depth 10), $utf8NoBom)
    Write-Host "已更新基线 top_dirs: $targetJson (scan_status=$overallScanStatus, top_dirs=$($topDirItems.Count), large_files=$($topLargeOut.Count))"
    if ($WriteMarkdown) {
      $mdTarget = [IO.Path]::ChangeExtension($targetJson, ".md")
      Write-BaselineMarkdown -MdPath $mdTarget -Stamp $stamp -BaselineObj $outBaseline
      Write-Host "已更新人读视图: $mdTarget"
    }
    return
  }

  $spaceResult = [ordered]@{
    generated_at                       = $genAt
    scan_status                        = $overallScanStatus
    scope_note                         = $effScope
    age_method                         = "LastWriteTime"
    large_file_min_bytes               = $effLargeMinBytes
    applied_filters                    = $appliedFilters
    total_logical_bytes                = $totalLogicalBytes
    total_allocated_bytes              = $totalAllocBytes
    sparse_or_compressed_savings_bytes = $sparseSavings
    fast_scanners                      = $fastTools
    resumed_from_stream_count          = $resumedCount
    stream_cache_bypassed_count        = $streamBypassedCount
    top_dirs                           = @($topDirItems.ToArray())
    age_size_matrix                    = $matrix
    top_large_files                    = @($topLargeOut)
    volume_reconciliation              = @($volReconcile.ToArray())
    recycle_bin                        = @($recycleBinSummary.ToArray())
    hygiene_flags                      = @($hygieneFlags.ToArray())
    restrictions                       = @($spaceRestrictions.ToArray())
  }
  $spaceJson = $spaceResult | ConvertTo-Json -Depth 10
  if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
    if (-not (Test-Path -LiteralPath $OutDir)) { [void][IO.Directory]::CreateDirectory($OutDir) }
    $spPath = Join-Path $OutDir "space-$stamp.json"
    [IO.File]::WriteAllText($spPath, $spaceJson, $utf8NoBom)
    Write-Host "已生成空间枚举 JSON: $spPath (scan_status=$overallScanStatus, top_dirs=$($topDirItems.Count), large_files=$($topLargeOut.Count))"
  } else {
    Write-Output $spaceJson
  }
}

function Invoke-DocsAction {
  $ErrorActionPreference = "SilentlyContinue"
  $targetRoots = if (-not $Roots -or $Roots.Count -eq 0) { @((Get-Location).Path) } else { $Roots }
  $exclude = @("node_modules", ".git", "dist", "build", ".next", ".venv", "venv", "__pycache__", ".cache", "target", ".turbo", "coverage")
  $exclRx = '(?i)\\(' + (($exclude | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(\\|$)'

  $report = New-Object System.Collections.Generic.List[string]
  $now = Get-Date
  $report.Add("# 文档卫生扫描")
  $report.Add("")
  $report.Add("- 采样时刻：$($now.ToString('yyyy-MM-dd HH:mm:ss'))")
  $report.Add("- 阈值：单目录 MD > $DirThreshold 份 / 单文件 > $FileLineThreshold 行 / 日志 $LogAgeDays 天 / 报告 $ReportAgeDays 天")
  $report.Add("- 性质：只读，未改动任何文件")
  $report.Add("")

  $totalAll = 0
  $rows = @()
  $seenMdPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

  foreach ($root in $targetRoots) {
    if (-not (Test-Path -LiteralPath $root)) { $report.Add("> 根目录不存在：$root"); continue }
    $report.Add("## $root")
    $report.Add("")
    $report.Add("| 目录 | MD 数 | 体量 | >${LogAgeDays}天 | >${ReportAgeDays}天 | 最大文件行数 | 判定 |")
    $report.Add("|---|---:|---:|---:|---:|---:|---|")

    $dirs = Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }
    foreach ($d in $dirs) {
      if ($exclude -contains $d.Name) { continue }
      $files = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Filter *.md -Force | Where-Object { $_.FullName -notmatch $exclRx -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
      if (-not $files -or $files.Count -eq 0) { continue }

      $bytes = ($files | Measure-Object Length -Sum).Sum
      if ($null -eq $bytes) { $bytes = 0 }
      $old30 = ($files | Where-Object { ($now - $_.LastWriteTime).TotalDays -gt $LogAgeDays }).Count
      $old90 = ($files | Where-Object { ($now - $_.LastWriteTime).TotalDays -gt $ReportAgeDays }).Count

      $maxLines = 0
      foreach ($f in ($files | Sort-Object Length -Descending | Select-Object -First 5)) {
        $n = (Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
        if ($n -gt $maxLines) { $maxLines = $n }
      }

      $verdict = "正常"
      if ($files.Count -gt $DirThreshold) { $verdict = "**硬触发：目录超 $DirThreshold 份**" }
      elseif ($maxLines -gt $FileLineThreshold) { $verdict = "**硬触发：单文件超 $FileLineThreshold 行**" }
      elseif ($old90 -gt ($files.Count * 0.6)) { $verdict = "建议归档（6 成以上超 90 天）" }
      elseif ($old30 -gt ($files.Count * 0.5)) { $verdict = "建议蒸馏（过半超 30 天）" }

      $rows += [PSCustomObject]@{ Dir=$d.Name; Root=$root; Count=$files.Count; Bytes=$bytes; Old30=$old30; Old90=$old90; MaxLines=$maxLines }
      $report.Add(("| {0} | {1} | {2:N1} MB | {3} | {4} | {5} | {6} |" -f $d.Name, $files.Count, ($bytes/1MB), $old30, $old90, $maxLines, $verdict))
      foreach ($mf in $files) {
        $mp = try { [IO.Path]::GetFullPath($mf.FullName) } catch { $mf.FullName }
        if ($seenMdPaths.Add($mp)) { $totalAll++ }
      }
    }
    $report.Add("")
  }

  $big = $rows | Where-Object { $_.Count -gt $DirThreshold } | Sort-Object Count -Descending
  $aged = $rows | Where-Object { $_.Old90 -gt ($_.Count * 0.6) } | Sort-Object Count -Descending

  $report.Add("## 汇总")
  $report.Add("")
  $report.Add("- 扫描范围内 MD 总数：**$totalAll**")
  $report.Add("- 越过目录阈值（>$DirThreshold）的目录：$(@($big).Count) 个")
  $report.Add("")

  if (@($big).Count -gt 0) {
    $report.Add("### 优先蒸馏（文件数超标）")
    $report.Add("")
    foreach ($r in $big) { $report.Add("- ``$($r.Dir)``：$($r.Count) 份 / $([math]::Round($r.Bytes/1MB,1)) MB") }
    $report.Add("")
  }
  if (@($aged).Count -gt 0) {
    $report.Add("### 优先归档（大面积超 90 天）")
    $report.Add("")
    foreach ($r in $aged) { $report.Add("- ``$($r.Dir)``：$($r.Old90)/$($r.Count) 份超期") }
    $report.Add("")
  }

  $report.Add("## 三档动作对照")
  $report.Add("")
  $report.Add("| 层 | 判据 | 动作 |")
  $report.Add("|---|---|---|")
  $report.Add("| L1 日志 | 超 $LogAgeDays 天 | 蒸馏进 MEMORY.md 后删除原文件 |")
  $report.Add("| L2 报告 | 超 $ReportAgeDays 天 | tar.xz 归档 + ARCHIVE-INDEX 留一行 |")
  $report.Add("| L4 草稿 | 会话结束 | 合并进正式产物，或直接删 |")
  $report.Add("| L3 沉淀 | 永久 | 只合并去重，不删除 |")
  $report.Add("")
  $report.Add("> 顺序：先蒸馏、后删除。报告类永不静默删除。")

  $text = $report -join ([Environment]::NewLine)
  if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $outDirP = [IO.Path]::GetDirectoryName($OutFile)
    if ($outDirP -and -not (Test-Path -LiteralPath $outDirP)) { New-Item -ItemType Directory -Path $outDirP -Force | Out-Null }
    [IO.File]::WriteAllText($OutFile, $text, $utf8Bom)
    Write-Host "已写出：$OutFile"
  } else {
    Write-Output $text
  }
}

function Invoke-DeltaAction {
  $ErrorActionPreference = "Stop"
  if ([string]::IsNullOrWhiteSpace($Drive)) {
    Write-Host "FAIL  delta 动作必须指定 -Drive（例如 E:）" -ForegroundColor Red
    exit 1
  }
  $dNorm = Test-DriveNorm $Drive
  if (-not $dNorm) {
    Write-Host "FAIL  非法盘符: $Drive（请传如 E:）" -ForegroundColor Red
    exit 1
  }

  $effDelta = if (-not [string]::IsNullOrWhiteSpace($DeltaMode)) {
    $DeltaMode
  } elseif (-not [string]::IsNullOrWhiteSpace($BeforeFile)) { "Compare" } else { "Snapshot" }

  $vol = Get-VolumeMetrics $dNorm
  if (-not $vol) {
    Write-Host "FAIL  无法读取卷信息: $dNorm" -ForegroundColor Red
    exit 1
  }
  $rb = Get-RecycleBinMetrics $dNorm
  $ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")

  if ($effDelta -eq "Snapshot") {
    $snap = [ordered]@{
      timestamp          = $ts
      drive              = $dNorm
      size_bytes         = $vol.size_bytes
      free_bytes         = $vol.free_bytes
      recycle_bytes      = $rb.bytes
      recycle_files      = $rb.files
      recycle_restricted = $rb.restricted
    }
    $j = $snap | ConvertTo-Json -Depth 4
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
      $dirP = [IO.Path]::GetDirectoryName($OutFile)
      if ($dirP -and -not (Test-Path -LiteralPath $dirP)) { New-Item -ItemType Directory -Path $dirP -Force | Out-Null }
      [IO.File]::WriteAllText($OutFile, $j, $utf8NoBom)
      Write-Host "快照已保存: $OutFile (Free=$([math]::Round($vol.free_bytes/1GB,2)) GB, RecycleBin=$([math]::Round($rb.bytes/1GB,2)) GB, Restricted=$($rb.restricted))"
    } else {
      Write-Output $j
    }
    exit 0
  }

  if ([string]::IsNullOrWhiteSpace($BeforeFile) -or -not (Test-Path -LiteralPath $BeforeFile)) {
    Write-Host "FAIL  Compare 模式必须提供存在的 -BeforeFile: $BeforeFile" -ForegroundColor Red
    exit 1
  }
  $before = Get-Content -LiteralPath $BeforeFile -Raw -Encoding UTF8 | ConvertFrom-Json
  if ("$($before.drive)" -ne $dNorm) {
    Write-Host "FAIL  快照盘符($($before.drive))与当前盘符($dNorm)不一致" -ForegroundColor Red
    exit 1
  }

  $freeDeltaBytes = [int64]$vol.free_bytes - [int64]$before.free_bytes
  $rbDeltaBytes = [int64]$rb.bytes - [int64]$before.recycle_bytes

  $logicalGB = [math]::Round($LogicalBytes / 1GB, 3)
  $measuredGB = [math]::Round($freeDeltaBytes / 1GB, 3)
  $recycleGB = [math]::Round($rbDeltaBytes / 1GB, 3)
  $estDiffBytes = $freeDeltaBytes - $LogicalBytes
  $estDiffGB = [math]::Round($estDiffBytes / 1GB, 3)

  $verdict = "partial-or-contested"
  $verdictZh = "差额待查（受回收站或并发写入影响）"

  if ($QuarantineMode) {
    if ($rbDeltaBytes -le 0) {
      $verdict = "quarantine-pending"
      $verdictZh = "已进隔离区（宽限期内可用空间暂不增加，属正确行为）"
    } else {
      $verdict = "trapped-in-recycle-bin"
      $verdictZh = "部分流入回收站"
    }
  } else {
    $minRel = [math]::Max(1048576L, [int64]($LogicalBytes * 0.5))
    $minTrap = [math]::Max(1048576L, [int64]($LogicalBytes * 0.5))
    if ($LogicalBytes -gt 0 -and $rbDeltaBytes -ge $minTrap -and $freeDeltaBytes -lt $minRel) {
      $verdict = "trapped-in-recycle-bin"
      $verdictZh = "未释放，空间在回收站"
    } elseif ($LogicalBytes -gt 0 -and $freeDeltaBytes -ge ([int64]($LogicalBytes * 0.85))) {
      $verdict = "released"
      $verdictZh = "已释放"
    } elseif ($LogicalBytes -eq 0 -and $freeDeltaBytes -gt 0 -and $rbDeltaBytes -le 0) {
      $verdict = "released"
      $verdictZh = "已释放"
    }
  }

  $threeCol = "逻辑释放 {0} GB / 实测释放 {1} GB / 回收站 {2} GB" -f $logicalGB, $measuredGB, $recycleGB
  $estVsAct = "预估 {0} GB / 实测释放 {1} GB / 回收站滞留 {2} GB（偏差 {3} GB）" -f $logicalGB, $measuredGB, $recycleGB, $estDiffGB
  $res = [ordered]@{
    timestamp                      = $ts
    drive                          = $dNorm
    logical_bytes                  = $LogicalBytes
    measured_free_delta            = $freeDeltaBytes
    recycle_delta                  = $rbDeltaBytes
    logical_released_gb            = $logicalGB
    measured_free_delta_gb         = $measuredGB
    recycle_delta_gb               = $recycleGB
    estimated_vs_actual_diff_bytes = $estDiffBytes
    estimated_vs_actual_summary    = $estVsAct
    recycle_restricted             = ($rb.restricted -or $before.recycle_restricted)
    summary_three_col              = $threeCol
    verdict                        = $verdict
    verdict_zh                     = $verdictZh
  }
  $outJson = $res | ConvertTo-Json -Depth 4
  if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    [IO.File]::WriteAllText($OutFile, $outJson, $utf8NoBom)
  }
  Write-Output $outJson
  exit 0
}

function Invoke-RulesAction {
  $ErrorActionPreference = "Continue"
  $repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
  $effRulesPath = if ([string]::IsNullOrWhiteSpace($RulesFile)) {
    Join-Path $repoRoot "assets\cleanup-rules.json"
  } else { $RulesFile }

  if (-not (Test-Path -LiteralPath $effRulesPath)) {
    Write-Host "FAIL  清理规则文件不存在: $effRulesPath" -ForegroundColor Red
    exit 1
  }

  $cfg = Get-Content -LiteralPath $effRulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $allRules = @($cfg.rules)
  $matchedList = New-Object System.Collections.ArrayList
  [int64]$estTotalBytes = 0
  [int64]$estTotalAllocBytes = 0
  $ruleFileLimit = if ($MaxFilesPerDir -eq 200000) { 50000 } else { $MaxFilesPerDir }

  foreach ($rule in $allRules) {
    if ($RuleIds.Count -gt 0 -and -not ($RuleIds -contains "$($rule.id)")) { continue }

    $cmdHit = $true
    if ($null -ne $rule.probe -and $null -ne $rule.probe.commands -and @($rule.probe.commands).Count -gt 0) {
      $cmdHit = $false
      foreach ($c in @($rule.probe.commands)) {
        if (Get-Command $c -EA SilentlyContinue) { $cmdHit = $true; break }
      }
    }

    $foundPaths = New-Object System.Collections.ArrayList
    $pathDetails = New-Object System.Collections.ArrayList
    [int64]$ruleBytes = 0
    [int64]$ruleAllocBytes = 0
    [int]$ruleFiles = 0
    [int]$partialPaths = 0
    [int]$failedPaths = 0

    if ($null -ne $rule.probe -and $null -ne $rule.probe.paths_env) {
      foreach ($rawP in @($rule.probe.paths_env)) {
        $exp = [Environment]::ExpandEnvironmentVariables("$rawP")
        if ($exp -match '%[A-Za-z0-9_]+%') { continue }
        $isExcl = $false
        foreach ($ep in $ExcludePaths) {
          if (-not [string]::IsNullOrWhiteSpace($ep) -and ($exp.TrimEnd('\') -like ($ep.TrimEnd('\') + '*'))) { $isExcl = $true; break }
        }
        if ($isExcl) { continue }
        if (Test-Path -LiteralPath $exp) {
          [void]$foundPaths.Add($exp)
          $m = Measure-DirSafe -TargetPath $exp -LimitFiles $ruleFileLimit -SkipNames @()
          $ruleBytes += [int64]$m.bytes
          $ruleAllocBytes += [int64]$m.allocated_bytes
          $ruleFiles += [int]$m.files
          if ($m.scan_status -eq "failed") { $failedPaths++ }
          elseif ($m.scan_status -eq "partial") { $partialPaths++ }
          [void]$pathDetails.Add([ordered]@{
            path            = $exp
            bytes           = [int64]$m.bytes
            allocated_bytes = [int64]$m.allocated_bytes
            files           = [int]$m.files
            scan_status     = $m.scan_status
            note            = $m.note
          })
        }
      }
    }

    if ($foundPaths.Count -gt 0) {
      $ruleStatus = if ($failedPaths -eq $foundPaths.Count) {
        "failed"
      } elseif ($failedPaths -gt 0 -or $partialPaths -gt 0) {
        "partial"
      } else { "ok" }
      $estTotalBytes += $ruleBytes
      $estTotalAllocBytes += $ruleAllocBytes
      [void]$matchedList.Add([ordered]@{
        id                        = $rule.id
        category                  = $rule.category
        title                     = $rule.title
        risk                      = $rule.risk
        execution_mode            = $rule.execution_mode
        preferred_command         = $rule.preferred_command
        needs_owner_confirm       = [bool]$rule.needs_owner_confirm
        probe_command_hit         = [bool]$cmdHit
        estimated_bytes           = $ruleBytes
        estimated_gb              = [math]::Round($ruleBytes / 1GB, 3)
        estimated_allocated_bytes = $ruleAllocBytes
        estimated_allocated_gb    = [math]::Round($ruleAllocBytes / 1GB, 3)
        estimated_files           = $ruleFiles
        scan_status               = $ruleStatus
        matched_paths             = @($foundPaths.ToArray())
        path_details              = @($pathDetails.ToArray())
        does_not_touch            = @($rule.does_not_touch)
        reason                    = $rule.reason
      })
    }
  }

  $res = [ordered]@{
    generated_at                    = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    rules_file                      = $effRulesPath
    rules_total                     = $allRules.Count
    rules_matched                   = $matchedList.Count
    estimated_total_bytes           = $estTotalBytes
    estimated_total_gb              = [math]::Round($estTotalBytes / 1GB, 3)
    estimated_total_allocated_bytes = $estTotalAllocBytes
    estimated_total_allocated_gb    = [math]::Round($estTotalAllocBytes / 1GB, 3)
    matched                         = @($matchedList.ToArray())
  }
  $json = $res | ConvertTo-Json -Depth 10
  if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $dirP = [IO.Path]::GetDirectoryName($OutFile)
    if ($dirP -and -not (Test-Path -LiteralPath $dirP)) { New-Item -ItemType Directory -Path $dirP -Force | Out-Null }
    [IO.File]::WriteAllText($OutFile, $json, $utf8NoBom)
    Write-Host "已匹配规则 $($matchedList.Count) / $($allRules.Count)，估算可回收 $([math]::Round($estTotalBytes/1GB,3)) GB -> $OutFile"
  } else {
    Write-Output $json
  }
  exit 0
}

function Get-FilePartialSha256 {
  param([string]$Path, [int64]$Length)
  $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $safeP = Get-WinLongSafePath -Path $Path
  $fs = $null
  $sha = $null
  try {
    $fs = [IO.File]::Open($safeP, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    if ($Length -le 8192) {
      $hBytes = $sha.ComputeHash($fs)
      return [BitConverter]::ToString($hBytes).Replace('-', '').ToLowerInvariant()
    }
    $buf = New-Object byte[] 8192
    $tot = 0
    while ($tot -lt 4096) {
      $n = $fs.Read($buf, $tot, 4096 - $tot)
      if ($n -le 0) { break }
      $tot += $n
    }
    [void]$fs.Seek(($Length - 4096), [IO.SeekOrigin]::Begin)
    $tailRead = 0
    while ($tailRead -lt 4096) {
      $n = $fs.Read($buf, ($tot + $tailRead), (4096 - $tailRead))
      if ($n -le 0) { break }
      $tailRead += $n
    }
    $hBytes = $sha.ComputeHash($buf, 0, ($tot + $tailRead))
    return [BitConverter]::ToString($hBytes).Replace('-', '').ToLowerInvariant()
  } finally {
    if ($null -ne $sha) { $sha.Dispose() }
    if ($null -ne $fs) { $fs.Dispose() }
  }
}

function Get-FileFullSha256 {
  param([string]$Path)
  $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $safeP = Get-WinLongSafePath -Path $Path
  $fs = $null
  $sha = $null
  try {
    $fs = [IO.File]::Open($safeP, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hBytes = $sha.ComputeHash($fs)
    return [BitConverter]::ToString($hBytes).Replace('-', '').ToLowerInvariant()
  } finally {
    if ($null -ne $sha) { $sha.Dispose() }
    if ($null -ne $fs) { $fs.Dispose() }
  }
}

function Invoke-DupesAction {
  $ErrorActionPreference = "Continue"
  $nowTs = Get-Date
  $genAt = $nowTs.ToString("yyyy-MM-ddTHH:mm:sszzz")
  $scanInputs = @($Roots) + @($TopDirs)
  $cleanRoots = New-Object System.Collections.ArrayList
  foreach ($sr in $scanInputs) {
    if (-not [string]::IsNullOrWhiteSpace($sr)) { [void]$cleanRoots.Add($sr) }
  }
  if ($cleanRoots.Count -eq 0) {
    Write-Host "FAIL  dupes 动作必须指定 -Roots 或 -TopDirs（禁止默认扫全盘）" -ForegroundColor Red
    exit 1
  }

  $effMinBytes = Get-EffectiveMinSizeBytes -DefaultBytes 10485760L
  $incExts = Normalize-ExtList -Exts $IncludeExt
  $excExts = Normalize-ExtList -Exts $ExcludeExt
  $appliedFilters = [ordered]@{
    min_size_bytes = $effMinBytes
    min_age_days   = $MinAgeDays
    include_ext    = @($incExts)
    exclude_ext    = @($excExts)
  }

  $seenFilePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $sizeBuckets = @{}
  $dupeRestrictions = New-Object System.Collections.ArrayList
  $scanStatus = "ok"

  [int]$filesEnum = 0
  [int]$passedFilter = 0
  [int]$skipZero = 0
  [int]$skipReparse = 0
  [int]$skipCloud = 0
  [int]$skipFilter = 0

  foreach ($r in $cleanRoots) {
    $rCanon = Resolve-WinCanonicalPath -Path $r
    $rSafe = Get-WinLongSafePath -Path $rCanon
    if (-not ((Test-Path -LiteralPath $rCanon) -or [IO.Directory]::Exists($rSafe))) {
      $scanStatus = "failed"
      [void]$dupeRestrictions.Add([ordered]@{ kind = "offline"; scope = $r; note = "指定查重根目录不存在或离线" })
      continue
    }
    $rootDi = New-Object System.IO.DirectoryInfo $rSafe
    if ($rootDi.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      $skipReparse++
      continue
    }

    $stack = New-Object System.Collections.Stack
    $stack.Push($rootDi)
    $rootVisited = 0
    $hitLimit = $false
    while ($stack.Count -gt 0) {
      $di = $stack.Pop()
      for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $scanDi = if ($attempt -eq 0) { $di } else {
          New-Object System.IO.DirectoryInfo (Get-WinLongSafePath -Path $di.FullName)
        }
        try {
          foreach ($e in $scanDi.EnumerateFileSystemInfos('*', [IO.SearchOption]::TopDirectoryOnly)) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipReparse++; continue }
            if ($e -is [IO.DirectoryInfo]) {
              $skip = $false
              foreach ($xn in $ExcludeNames) {
                if ($e.Name -ieq $xn) { $skip = $true; break }
              }
              if (-not $skip) {
                foreach ($ep in $ExcludePaths) {
                  if (-not [string]::IsNullOrWhiteSpace($ep) -and ($e.FullName.TrimEnd('\') -ieq $ep.TrimEnd('\'))) { $skip = $true; break }
                }
              }
              if (-not $skip) { $stack.Push($e) }
            } else {
              $normP = try { [IO.Path]::GetFullPath($e.FullName) } catch { $e.FullName }
              if (-not $seenFilePaths.Add($normP)) { continue }

              $filesEnum++
              $rootVisited++
              $fLen = [int64]$e.Length
              if ($fLen -eq 0) {
                $skipZero++
              } elseif (([int]$e.Attributes -band (0x1000 -bor 0x00040000 -bor 0x00400000)) -ne 0) {
                $skipCloud++
              } elseif (-not (Test-FileMatchesFilter -FileObj $e -MinBytes $effMinBytes -MinAgeDaysVal $MinAgeDays -IncExts $incExts -ExcExts $excExts -NowTime $nowTs)) {
                $skipFilter++
              } else {
                $passedFilter++
                $sKey = [string]$fLen
                if (-not $sizeBuckets.ContainsKey($sKey)) {
                  $sizeBuckets[$sKey] = New-Object System.Collections.ArrayList
                }
                [void]$sizeBuckets[$sKey].Add([pscustomobject]@{
                  path       = $normP
                  size       = $fLen
                  last_write = $e.LastWriteTime
                  attributes = [int]$e.Attributes
                })
              }

              if ($MaxFilesPerDir -gt 0 -and $rootVisited -ge $MaxFilesPerDir) {
                $hitLimit = $true
                if ($scanStatus -eq "ok") { $scanStatus = "partial" }
                [void]$dupeRestrictions.Add([ordered]@{ kind = "permission"; scope = $r; note = "查重到达单根上限 $MaxFilesPerDir 文件，已截断（sampled/partial）" })
                break
              }
            }
          }
          break
        } catch {
          if ($attempt -eq 0 -and (Get-WinLongSafePath -Path $di.FullName) -ne $di.FullName) { continue }
          if ($di.FullName -eq $rootDi.FullName) { $scanStatus = "failed" }
          elseif ($scanStatus -eq "ok") { $scanStatus = "partial" }
          [void]$dupeRestrictions.Add([ordered]@{ kind = "permission"; scope = $di.FullName; note = "读取失败: $($_.Exception.Message)" })
          break
        }
      }
      if ($hitLimit) { break }
    }
  }

  # Stage 1: Exact Size + NTFS Hardlink Separation
  $stage1SizeBuckets = 0
  $stage1PhysicalCandidates = 0
  $hardlinkCollapsed = 0
  $hardlinkClusters = New-Object System.Collections.ArrayList
  $stage2Input = New-Object System.Collections.ArrayList

  foreach ($sKey in $sizeBuckets.Keys) {
    $grp = $sizeBuckets[$sKey]
    if ($grp.Count -lt 2) { continue }
    $stage1SizeBuckets++

    $byPhysical = @{}
    $anonIdx = 0
    foreach ($item in $grp) {
      $idKey = if ($script:hasNativeSize) { [MaFileNativeV2]::GetFileIdentityKey($item.path) } else { $null }
      if ($idKey) {
        $parts = $idKey.Split(':')
        $physKey = "$($parts[0]):$($parts[1])"
        $nLinks = [int]$parts[2]
      } else {
        $anonIdx++
        $physKey = "UNID:$anonIdx"
        $nLinks = 1
      }
      if (-not $byPhysical.ContainsKey($physKey)) {
        $byPhysical[$physKey] = [ordered]@{
          physical_id = $physKey
          n_links     = $nLinks
          items       = New-Object System.Collections.ArrayList
        }
      }
      [void]$byPhysical[$physKey].items.Add($item)
    }

    $physicalReps = New-Object System.Collections.ArrayList
    foreach ($pk in $byPhysical.Keys) {
      $cluster = $byPhysical[$pk]
      $cItems = $cluster.items
      if ($cItems.Count -gt 1) {
        $hardlinkCollapsed += ($cItems.Count - 1)
        [void]$hardlinkClusters.Add([ordered]@{
          physical_id        = $pk
          size_bytes         = [int64]$cItems[0].size
          link_count_total   = $cluster.n_links
          paths              = @($cItems | ForEach-Object { $_.path })
          reclaimable_bytes  = 0L
          note               = "NTFS 硬链接共用同一物理数据块，删除其中一个通常不释放物理空间"
        })
      }
      $rep = $cItems[0]
      [void]$physicalReps.Add([pscustomobject]@{
        path           = $rep.path
        size           = [int64]$rep.size
        last_write     = $rep.last_write
        attributes     = $rep.attributes
        n_links        = $cluster.n_links
        hardlink_paths = @($cItems | ForEach-Object { $_.path })
      })
    }

    if ($physicalReps.Count -ge 2) {
      $stage1PhysicalCandidates += $physicalReps.Count
      foreach ($rItem in $physicalReps) { [void]$stage2Input.Add($rItem) }
    }
  }

  # Stage 2: Partial Hash (First 4KB + Last 4KB SHA256)
  $partialBuckets = @{}
  [int]$stage2Hashed = 0
  foreach ($rep in $stage2Input) {
    try {
      $ph = Get-FilePartialSha256 -Path $rep.path -Length $rep.size
      $stage2Hashed++
      $pKey = "$($rep.size)|$ph"
      if (-not $partialBuckets.ContainsKey($pKey)) {
        $partialBuckets[$pKey] = New-Object System.Collections.ArrayList
      }
      [void]$partialBuckets[$pKey].Add($rep)
    } catch {
      [void]$dupeRestrictions.Add([ordered]@{ kind = "permission"; scope = $rep.path; note = "局部哈希读取受限: $($_.Exception.Message)" })
    }
  }

  $stage2Survivors = New-Object System.Collections.ArrayList
  [int]$stage2CollidingBuckets = 0
  foreach ($pk in $partialBuckets.Keys) {
    if ($partialBuckets[$pk].Count -ge 2) {
      $stage2CollidingBuckets++
      foreach ($s in $partialBuckets[$pk]) { [void]$stage2Survivors.Add($s) }
    }
  }

  # Stage 3: Full Streaming SHA256 Confirmation
  $fullBuckets = @{}
  [int]$stage3Hashed = 0
  foreach ($rep in $stage2Survivors) {
    try {
      $fh = Get-FileFullSha256 -Path $rep.path
      $stage3Hashed++
      $fKey = "$($rep.size)|$fh"
      if (-not $fullBuckets.ContainsKey($fKey)) {
        $fullBuckets[$fKey] = [ordered]@{ size = [int64]$rep.size; sha256 = $fh; items = New-Object System.Collections.ArrayList }
      }
      [void]$fullBuckets[$fKey].items.Add($rep)
    } catch {
      [void]$dupeRestrictions.Add([ordered]@{ kind = "permission"; scope = $rep.path; note = "全量哈希读取受限: $($_.Exception.Message)" })
    }
  }

  $dupeGroups = New-Object System.Collections.ArrayList
  [int64]$reclaimLogicalTotal = 0L
  [int64]$reclaimAllocTotal = 0L
  [int]$extraFilesTotal = 0

  foreach ($fk in $fullBuckets.Keys) {
    $fg = $fullBuckets[$fk]
    if ($fg.items.Count -lt 2) { continue }

    $sortedCopies = @($fg.items | Sort-Object { $_.last_write })
    $copyList = New-Object System.Collections.ArrayList
    foreach ($cp in $sortedCopies) {
      $allocB = if ($script:hasNativeSize) { [MaFileNativeV2]::GetAllocatedBytes($cp.path, $fg.size) } else { $fg.size }
      [void]$copyList.Add([ordered]@{
        path                     = $cp.path
        allocated_bytes          = $allocB
        is_sparse                = (($cp.attributes -band 0x0200) -ne 0)
        last_write               = $cp.last_write.ToString("yyyy-MM-ddTHH:mm:sszzz")
        age_days                 = [math]::Round(($nowTs - $cp.last_write).TotalDays, 1)
        n_links                  = $cp.n_links
        external_hardlink_notice = ($cp.n_links -gt $cp.hardlink_paths.Count)
      })
    }

    $extHlPresent = $false
    $recKeepPath = $copyList[0].path
    foreach ($cpObj in $copyList) {
      if ($cpObj.external_hardlink_notice) {
        $extHlPresent = $true
        $recKeepPath = $cpObj.path
        break
      }
    }

    [int64]$reclaimLog = 0L
    [int64]$reclaimAlloc = 0L
    [int]$extraCount = 0
    foreach ($cpObj in $copyList) {
      if ($cpObj.path -eq $recKeepPath) { continue }
      $extraCount++
      if (-not $cpObj.external_hardlink_notice) {
        $reclaimLog += [int64]$fg.size
        $reclaimAlloc += [int64]$cpObj.allocated_bytes
      }
    }

    $reclaimLogicalTotal += $reclaimLog
    $reclaimAllocTotal += $reclaimAlloc
    $extraFilesTotal += $extraCount

    [void]$dupeGroups.Add([ordered]@{
      sha256                      = $fg.sha256
      size_bytes                  = $fg.size
      copy_count                  = $copyList.Count
      reclaimable_logical_bytes   = $reclaimLog
      reclaimable_allocated_bytes = $reclaimAlloc
      external_hardlink_present   = $extHlPresent
      recommended_keep_path       = $recKeepPath
      oldest_path                 = $copyList[0].path
      newest_path                 = $copyList[$copyList.Count - 1].path
      copies                      = @($copyList.ToArray())
    })
  }

  $topDupes = @($dupeGroups | Sort-Object @{Expression={ $_.reclaimable_allocated_bytes }; Descending=$true}, @{Expression={ $_.reclaimable_logical_bytes }; Descending=$true} | Select-Object -First $TopDupesCount)

  $res = [ordered]@{
    generated_at     = $genAt
    scan_status      = $scanStatus
    age_method       = "LastWriteTime"
    roots            = @($cleanRoots.ToArray())
    applied_filters  = $appliedFilters
    funnel_stats     = [ordered]@{
      files_enumerated             = $filesEnum
      passed_filter                = $passedFilter
      skipped_zero_bytes           = $skipZero
      skipped_reparse              = $skipReparse
      skipped_cloud_placeholders   = $skipCloud
      skipped_filtered_out         = $skipFilter
      hardlink_clusters_collapsed  = $hardlinkCollapsed
      stage1_size_buckets          = $stage1SizeBuckets
      stage1_physical_candidates   = $stage1PhysicalCandidates
      stage2_partial_hashed_files  = $stage2Hashed
      stage2_colliding_buckets     = $stage2CollidingBuckets
      stage3_full_hashed_files     = $stage3Hashed
      duplicate_groups_count       = $dupeGroups.Count
      duplicate_extra_files        = $extraFilesTotal
      reclaimable_logical_bytes    = $reclaimLogicalTotal
      reclaimable_allocated_bytes  = $reclaimAllocTotal
      reclaimable_allocated_gb     = [math]::Round($reclaimAllocTotal / 1GB, 3)
    }
    duplicate_groups  = @($topDupes)
    hardlink_clusters = @($hardlinkClusters.ToArray())
    restrictions      = @($dupeRestrictions.ToArray())
  }

  $json = $res | ConvertTo-Json -Depth 10
  if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $dirP = [IO.Path]::GetDirectoryName($OutFile)
    if ($dirP -and -not (Test-Path -LiteralPath $dirP)) { New-Item -ItemType Directory -Path $dirP -Force | Out-Null }
    [IO.File]::WriteAllText($OutFile, $json, $utf8NoBom)
    Write-Host "查重完成: $($dupeGroups.Count) 组重复（可回收 $([math]::Round($reclaimAllocTotal/1GB,3)) GB） -> $OutFile"
  } else {
    Write-Output $json
  }
  exit 0
}

switch ($Action) {
  "env"   { Invoke-EnvAction }
  "space" { Invoke-SpaceAction }
  "docs"  { Invoke-DocsAction }
  "delta" { Invoke-DeltaAction }
  "rules" { Invoke-RulesAction }
  "dupes" { Invoke-DupesAction }
}
