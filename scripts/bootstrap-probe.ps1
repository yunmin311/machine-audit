<#
.SYNOPSIS
  bootstrap-probe.ps1 - 只读环境与目录基线采集辅助脚本 v1.0（PS 5.1 兼容）
.DESCRIPTION
  按 references/stage-00-bootstrap.md 与 assets/baseline.schema.json (1.1) 自动采集：
  - 环境档位（OS / 用户 / 管理员权限 / LanguageMode / KFM 云重定向 / 杀软进程）
  - 卷级空间账目（size_bytes / free_bytes / free_pct / redline）
  - 指定根目录的 PS 5.1 安全枚举（跳过 ReparsePoint，支持 -MaxFilesPerDir 限流防卡死，失败显式记 failed）
  - 自动生成受限清单（非管理员 / 杀软 / 限流抽样 / 枚举失败）

  只读边界：绝不修改被测目录或注册表；仅当传入 -OutDir 时写入 baseline-YYYYMMDD.json（或 stdout 输出 JSON）。
  安全限制：不提供默认全盘扫描；未传 -Roots 且未传 -TopDirs 时只采集环境与卷账目，top_dirs 为空数组。
用法:
  .\bootstrap-probe.ps1 -Roots "D:\MyProjects" -OutDir "D:\AuditOut"
  powershell.exe -NoProfile -Command "& '.\scripts\bootstrap-probe.ps1' -Roots @('D:\ProjA','E:\ProjB') -OutDir '.\out'"
#>
param(
  [string[]]$Roots = @(),
  [string[]]$TopDirs = @(),
  [string]$OutDir = "",
  [ValidateSet("bootstrap","quick","full","maintain")][string]$Mode = "bootstrap",
  [string]$PreviousRunId = "",
  [double]$WarnPct = 15,
  [double]$CritPct = 10,
  [int]$MaxFilesPerDir = 200000,
  [string[]]$ExcludeNames = @("node_modules",".git","$Recycle.Bin","System Volume Information"),
  [string[]]$AntivirusProcesses = @("360tray","HipsTray","QQPCTray","avp","MsMpEng","ekrn"),
  [string[]]$Roles = @("production-code"),
  [string[]]$DomainPacks = @(),
  [string]$ScopeNote = "",
  [switch]$WriteMarkdown
)

$ErrorActionPreference = "Continue"
$runId = Get-Date -Format "yyyyMMdd-HHmmssfff"
$stamp = Get-Date -Format "yyyyMMdd"
$genAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")

$restrictions = New-Object System.Collections.ArrayList

# ---- 1. 权限与环境 ----
$psVer = "$($PSVersionTable.PSVersion)"
$langMode = "$($ExecutionContext.SessionState.LanguageMode)"
$isAdmin = $false
try {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
  $isAdmin = $false
}

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
} catch {
  $avHits = @()
}

if (-not $isAdmin) {
  [void]$restrictions.Add([ordered]@{
    kind = "permission"
    scope = "非管理员运行"
    note = "未提权运行，系统目录、服务与部分 ACL 检查受限"
    affects = @("02","07","08","15")
  })
}
if ($langMode -ne "FullLanguage") {
  [void]$restrictions.Add([ordered]@{
    kind = "clm"
    scope = "PowerShell LanguageMode=$langMode"
    note = "受限语言模式下部分 .NET 检查不可用"
    affects = @("00","02","15")
  })
}
if ($avHits.Count -gt 0) {
  [void]$restrictions.Add([ordered]@{
    kind = "antivirus"
    scope = "检测到杀软/EDR进程: $($avHits -join ',')"
    note = "安全软件驻留时枚举与行为检测可能不完整"
    affects = @("02","07","15")
  })
}

# ---- 2. 卷级空间账目 ----
$drives = New-Object System.Collections.ArrayList
$vols = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -EA SilentlyContinue)
foreach ($v in $vols) {
  if (-not $v.Size -or [int64]$v.Size -le 0) { continue }
  $sz = [int64]$v.Size
  $fr = [int64]$v.FreeSpace
  $pct = [math]::Round(($fr / $sz) * 100, 1)
  $red = if ($pct -lt $CritPct) { "critical" } elseif ($pct -lt $WarnPct) { "warn" } else { "ok" }
  $dObj = [ordered]@{
    id         = "$($v.DeviceID)"
    size_bytes = $sz
    free_bytes = $fr
    free_pct   = [double]$pct
    online     = $true
    redline    = $red
  }
  if (-not [string]::IsNullOrWhiteSpace("$($v.VolumeName)")) {
    $dObj.label = "$($v.VolumeName)".Trim()
  }
  [void]$drives.Add($dObj)
}

# ---- 3. PS 5.1 安全目录枚举（跳过 ReparsePoint，防卡死与假 0）----
function Measure-DirSafe {
  param([string]$TargetPath, [int]$LimitFiles, [string[]]$SkipNames)
  if (-not (Test-Path -LiteralPath $TargetPath)) {
    return [pscustomobject]@{
      path = $TargetPath; bytes = 0L; files = 0; sampled = $false; scan_status = "failed"
      note = "路径不存在"
    }
  }
  $rootDi = New-Object System.IO.DirectoryInfo $TargetPath
  if ($rootDi.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    return [pscustomobject]@{
      path = $TargetPath; bytes = 0L; files = 0; sampled = $false; scan_status = "ok"
      note = "重解析点（已跳过）"
    }
  }
  $sum = 0L; $cnt = 0; $rootFailed = $false; $partialErr = $false; $hitLimit = $false
  $stack = New-Object System.Collections.Stack
  $stack.Push($rootDi)
  while ($stack.Count -gt 0) {
    $di = $stack.Pop()
    try {
      foreach ($e in $di.EnumerateFileSystemInfos('*', [IO.SearchOption]::TopDirectoryOnly)) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($e -is [IO.DirectoryInfo]) {
          $skip = $false
          foreach ($xn in $SkipNames) {
            if ($e.Name -ieq $xn) { $skip = $true; break }
          }
          if (-not $skip) { $stack.Push($e) }
        } else {
          $sum += $e.Length
          $cnt++
          if ($LimitFiles -gt 0 -and $cnt -ge $LimitFiles) {
            $hitLimit = $true
            break
          }
        }
      }
    } catch {
      if ($di.FullName -eq $rootDi.FullName) { $rootFailed = $true }
      else { $partialErr = $true }
    }
    if ($hitLimit) { break }
  }
  if ($rootFailed) {
    return [pscustomobject]@{
      path = $TargetPath; bytes = 0L; files = 0; sampled = $false; scan_status = "failed"
      note = "根目录读取失败"
    }
  }
  if ($hitLimit -or $partialErr) {
    $why = if ($hitLimit) { "达到单目录上限 $LimitFiles 文件，已截断采样" } else { "部分子目录无权限或读取失败" }
    return [pscustomobject]@{
      path = $TargetPath; bytes = $sum; files = $cnt; sampled = $true; scan_status = "partial"
      note = $why
    }
  }
  return [pscustomobject]@{
    path = $TargetPath; bytes = $sum; files = $cnt; sampled = $false; scan_status = "ok"
    note = ""
  }
}

$targetDirs = New-Object System.Collections.ArrayList
foreach ($td in $TopDirs) {
  if (-not [string]::IsNullOrWhiteSpace($td)) { [void]$targetDirs.Add($td) }
}
foreach ($r in $Roots) {
  if ([string]::IsNullOrWhiteSpace($r)) { continue }
  if (-not (Test-Path -LiteralPath $r)) {
    [void]$restrictions.Add([ordered]@{
      kind = "offline"
      scope = $r
      note = "指定扫描根目录不存在或离线"
      affects = @("02")
    })
    continue
  }
  $children = @(Get-ChildItem -LiteralPath $r -Directory -Force -EA SilentlyContinue)
  foreach ($c in $children) {
    $skip = $false
    foreach ($xn in $ExcludeNames) {
      if ($c.Name -ieq $xn) { $skip = $true; break }
    }
    if (-not $skip) { [void]$targetDirs.Add($c.FullName) }
  }
}

$topDirItems = New-Object System.Collections.ArrayList
$overallScanStatus = "ok"
foreach ($td in $targetDirs) {
  $m = Measure-DirSafe -TargetPath $td -LimitFiles $MaxFilesPerDir -SkipNames $ExcludeNames
  if ($m.scan_status -eq "failed") {
    $overallScanStatus = "failed"
    [void]$restrictions.Add([ordered]@{
      kind = "unknown"
      scope = $m.path
      note = "目录枚举失败: $($m.note)"
      affects = @("02")
    })
  } elseif ($m.scan_status -eq "partial") {
    if ($overallScanStatus -ne "failed") { $overallScanStatus = "partial" }
    [void]$restrictions.Add([ordered]@{
      kind = "permission"
      scope = $m.path
      note = "部分采集（sampled=true）: $($m.note)"
      affects = @("02")
    })
  }
  [void]$topDirItems.Add([ordered]@{
    path        = $m.path
    bytes       = [int64]$m.bytes
    files       = [int]$m.files
    sampled     = [bool]$m.sampled
    scan_status = $m.scan_status
    owner_note  = "待用户定性"
  })
}

if ([string]::IsNullOrWhiteSpace($ScopeNote)) {
  if ($targetDirs.Count -eq 0) {
    $ScopeNote = "仅环境与卷账目（未传 -Roots/-TopDirs）"
  } else {
    $ScopeNote = "受控目录采集: $($targetDirs.Count) 个顶层目录（跳过 ReparsePoint，单目录上限 $MaxFilesPerDir 文件）"
  }
}

$metaObj = [ordered]@{
  run_id          = $runId
  generated_at    = $genAt
  skill_version   = "0.8.1"
  mode            = $Mode
  scan_status     = $overallScanStatus
  previous_run_id = if ([string]::IsNullOrWhiteSpace($PreviousRunId)) { $null } else { $PreviousRunId }
  scope_note      = $ScopeNote
}

$envObj = [ordered]@{
  os = [ordered]@{
    caption = $caption
    build   = $build
    locale  = $locale
  }
  user = [ordered]@{
    name         = "$env:USERNAME"
    profile_path = "$env:USERPROFILE"
  }
  privilege = [ordered]@{
    admin         = [bool]$isAdmin
    language_mode = $langMode
    ps_version    = $psVer
  }
  antivirus = @($avHits)
  cloud_redirection = [ordered]@{
    kfm_active = [bool]$kfm
    desktop    = $desk
    personal   = $pers
    pictures   = $pics
  }
}

$baseline = [ordered]@{
  schema_version = "1.1"
  meta           = $metaObj
  environment    = $envObj
  drives         = @($drives.ToArray())
  top_dirs       = @($topDirItems.ToArray())
  persona        = [ordered]@{ roles = @($Roles) }
  domains        = [ordered]@{ packs = @($DomainPacks) }
  restrictions   = @($restrictions.ToArray())
}

$jsonText = $baseline | ConvertTo-Json -Depth 10

if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
  if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
  $jsonPath = Join-Path $OutDir "baseline-$stamp.json"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($jsonPath, $jsonText, $utf8NoBom)
  Write-Host "已生成基线 JSON: $jsonPath (scan_status=$overallScanStatus, top_dirs=$($topDirItems.Count))"
  if ($WriteMarkdown) {
    $mdPath = Join-Path $OutDir "baseline-$stamp.md"
    $avLabel = if ($avHits.Count -gt 0) { $avHits -join ',' } else { '未检出' }
    $mdLines = @(
      "# baseline-$stamp · 本机基线（由 bootstrap-probe.ps1 生成）",
      "",
      ("- ``schema_version``: 1.1 | ``run_id``: {0} | ``generated_at``: {1} | ``scan_status``: {2}" -f $runId, $genAt, $overallScanStatus),
      ("- ``admin``: {0} | ``LanguageMode``: {1} | ``PS``: {2} | ``AV``: {3}" -f $isAdmin, $langMode, $psVer, $avLabel),
      ("- ``scope_note``: {0}" -f $ScopeNote),
      "",
      "## §Drives",
      "",
      "| 盘 | 总量(GB) | 剩余(GB) | 剩余% | 红线 |",
      "|---|---:|---:|---:|---|"
    )
    foreach ($d in $drives) {
      $mdLines += "| $($d.id) | $([math]::Round($d.size_bytes/1GB,2)) | $([math]::Round($d.free_bytes/1GB,2)) | $($d.free_pct)% | $($d.redline) |"
    }
    $mdLines += @("", "## §TopDirs", "", "| 路径 | 体量(MB) | 文件数 | 采样 | 采集状态 | 归属定性 |", "|---|---:|---:|---|---|---|")
    foreach ($t in $topDirItems) {
      $mdLines += "| $($t.path) | $([math]::Round($t.bytes/1MB,2)) | $($t.files) | $($t.sampled) | $($t.scan_status) | $($t.owner_note) |"
    }
    [IO.File]::WriteAllText($mdPath, ($mdLines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "已生成人读视图: $mdPath"
  }
} else {
  Write-Output $jsonText
}
