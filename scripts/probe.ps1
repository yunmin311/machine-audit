<#
.SYNOPSIS
  probe.ps1 - 整机审查统一只读探测工具 v1.0（PS 5.1 兼容，-Action env|space|docs|delta）
.DESCRIPTION
  通过 -Action 选择四项只读测量之一（绝不修改被测目录或删除文件）：
  - env   : 按 references/stage-00-bootstrap.md 与 assets/baseline.schema.json (1.2) 采集
            环境档位、权限/KFM/杀软与卷级空间账目，输出标准基线 JSON（top_dirs 为空，可选写 MD）。
  - space : 按 references/stage-02-disk.md 安全枚举 -Roots/-TopDirs（跳过 ReparsePoint，
            -MaxFilesPerDir 限流防卡死，失败显式标 failed）；传 -Baseline 时合并更新基线 JSON。
  - docs  : 按 references/memory-hygiene.md 五层模型扫描 Markdown 文档数量/体量/陈旧度，
            给出蒸馏/归档/退役建议（严格只读）。
  - delta : 实现 references/execution-safety.md §删除的验收口径 与 docs/design/execution-safety.md §7，
            在批前后采样卷 FreeSpace 与 <盘>:\$Recycle.Bin，输出「逻辑/实测/回收站」三栏判定。
用法:
  powershell.exe -NoProfile -Command "& '.\scripts\probe.ps1' -Action env -OutDir '.\out' -WriteMarkdown"
  powershell.exe -NoProfile -Command "& '.\scripts\probe.ps1' -Action space -Roots @('D:\ProjA','E:\ProjB') -Baseline '.\out\baseline-20261117.json'"
  powershell.exe -NoProfile -Command "& '.\scripts\probe.ps1' -Action docs -Roots @('D:\ProjA') -OutFile '.\hygiene.md'"
  .\scripts\probe.ps1 -Action delta -DeltaMode Snapshot -Drive E: -OutFile "$env:TEMP\before.json"
  .\scripts\probe.ps1 -Action delta -DeltaMode Compare -Drive E: -BeforeFile "$env:TEMP\before.json" -LogicalBytes 52428800
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("env","space","docs","delta")]
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
  [string[]]$AntivirusProcesses = @("360tray","HipsTray","QQPCTray","avp","MsMpEng","ekrn"),
  [string[]]$Roles = @("production-code"),
  [string[]]$DomainPacks = @(),
  [string]$ScopeNote = "",
  [switch]$WriteMarkdown,

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

$SKILL_VERSION = "0.9.0"
$SCHEMA_VERSION = "1.2"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

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
  [IO.File]::WriteAllText($MdPath, ($mdLines -join "`r`n"), $utf8Bom)
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
  }

  $jsonText = $baselineObj | ConvertTo-Json -Depth 10
  if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
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
  $genAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
  $spaceRestrictions = New-Object System.Collections.ArrayList

  $targetDirs = New-Object System.Collections.ArrayList
  foreach ($td in $TopDirs) {
    if (-not [string]::IsNullOrWhiteSpace($td)) { [void]$targetDirs.Add($td) }
  }
  foreach ($r in $Roots) {
    if ([string]::IsNullOrWhiteSpace($r)) { continue }
    if (-not (Test-Path -LiteralPath $r)) {
      [void]$spaceRestrictions.Add([ordered]@{
        kind = "offline"; scope = $r; note = "指定扫描根目录不存在或离线"; affects = @("02")
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
      [void]$spaceRestrictions.Add([ordered]@{
        kind = "unknown"; scope = $m.path; note = "目录枚举失败: $($m.note)"; affects = @("02")
      })
    } elseif ($m.scan_status -eq "partial") {
      if ($overallScanStatus -ne "failed") { $overallScanStatus = "partial" }
      [void]$spaceRestrictions.Add([ordered]@{
        kind = "permission"; scope = $m.path; note = "部分采集（sampled=true）: $($m.note)"; affects = @("02")
      })
    }
    [void]$topDirItems.Add([ordered]@{
      path = $m.path; bytes = [int64]$m.bytes; files = [int]$m.files; sampled = [bool]$m.sampled
      scan_status = $m.scan_status; owner_note = "待用户定性"
    })
  }

  $effScope = if (-not [string]::IsNullOrWhiteSpace($ScopeNote)) {
    $ScopeNote
  } elseif ($targetDirs.Count -eq 0 -and $spaceRestrictions.Count -eq 0) {
    "未传 -Roots/-TopDirs，top_dirs 为空"
  } else {
    "受控目录采集: $($targetDirs.Count) 个顶层目录（跳过 ReparsePoint，单目录上限 $MaxFilesPerDir 文件）"
  }

  if (-not [string]::IsNullOrWhiteSpace($Baseline)) {
    if (-not (Test-Path -LiteralPath $Baseline)) {
      Write-Host "FAIL  基线文件不存在: $Baseline" -ForegroundColor Red
      exit 1
    }
    $baseObj = Get-Content -LiteralPath $Baseline -Raw -Encoding UTF8 | ConvertFrom-Json
    # Rebuild ordered map so single-element arrays stay arrays in PS 5.1 ConvertTo-Json
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
    $outBaseline = [ordered]@{
      schema_version = $baseObj.schema_version
      meta           = $metaOut
      environment    = $baseObj.environment
      drives         = @($baseObj.drives)
      top_dirs       = @($topDirItems.ToArray())
      persona        = $baseObj.persona
      domains        = $baseObj.domains
      restrictions   = @($mergedRestrictions.ToArray())
    }
    if ($null -ne $baseObj.PSObject.Properties["snapshots"]) {
      $outBaseline.snapshots = $baseObj.snapshots
    }
    if ($null -ne $baseObj.PSObject.Properties["network"]) {
      $outBaseline.network = $baseObj.network
    }

    $targetJson = if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
      if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
      Join-Path $OutDir "baseline-$stamp.json"
    } else { $Baseline }

    [IO.File]::WriteAllText($targetJson, ($outBaseline | ConvertTo-Json -Depth 10), $utf8NoBom)
    Write-Host "已更新基线 top_dirs: $targetJson (scan_status=$overallScanStatus, top_dirs=$($topDirItems.Count))"
    if ($WriteMarkdown) {
      $mdTarget = [IO.Path]::ChangeExtension($targetJson, ".md")
      Write-BaselineMarkdown -MdPath $mdTarget -Stamp $stamp -BaselineObj $outBaseline
      Write-Host "已更新人读视图: $mdTarget"
    }
    return
  }

  $spaceResult = [ordered]@{
    generated_at = $genAt
    scan_status  = $overallScanStatus
    scope_note   = $effScope
    top_dirs     = @($topDirItems.ToArray())
    restrictions = @($spaceRestrictions.ToArray())
  }
  $spaceJson = $spaceResult | ConvertTo-Json -Depth 10
  if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $spPath = Join-Path $OutDir "space-$stamp.json"
    [IO.File]::WriteAllText($spPath, $spaceJson, $utf8NoBom)
    Write-Host "已生成空间枚举 JSON: $spPath (scan_status=$overallScanStatus, top_dirs=$($topDirItems.Count))"
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

  foreach ($root in $targetRoots) {
    if (-not (Test-Path -LiteralPath $root)) { $report.Add("> 根目录不存在：$root"); continue }
    $report.Add("## $root")
    $report.Add("")
    $report.Add("| 目录 | MD 数 | 体量 | >${LogAgeDays}天 | >${ReportAgeDays}天 | 最大文件行数 | 判定 |")
    $report.Add("|---|---:|---:|---:|---:|---:|---|")

    $dirs = Get-ChildItem -LiteralPath $root -Directory -Force
    foreach ($d in $dirs) {
      if ($exclude -contains $d.Name) { continue }
      $files = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Filter *.md -Force | Where-Object { $_.FullName -notmatch $exclRx })
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
      $totalAll += $files.Count
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
  $res = [ordered]@{
    timestamp              = $ts
    drive                  = $dNorm
    logical_bytes          = $LogicalBytes
    measured_free_delta    = $freeDeltaBytes
    recycle_delta          = $rbDeltaBytes
    logical_released_gb    = $logicalGB
    measured_free_delta_gb = $measuredGB
    recycle_delta_gb       = $recycleGB
    recycle_restricted     = ($rb.restricted -or $before.recycle_restricted)
    summary_three_col      = $threeCol
    verdict                = $verdict
    verdict_zh             = $verdictZh
  }
  $outJson = $res | ConvertTo-Json -Depth 4
  if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    [IO.File]::WriteAllText($OutFile, $outJson, $utf8NoBom)
  }
  Write-Output $outJson
  exit 0
}

switch ($Action) {
  "env"   { Invoke-EnvAction }
  "space" { Invoke-SpaceAction }
  "docs"  { Invoke-DocsAction }
  "delta" { Invoke-DeltaAction }
}
