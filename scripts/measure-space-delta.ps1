<#
.SYNOPSIS
  measure-space-delta.ps1 - 删除验收三栏空间增量测量工具 v1.0（只读，PS 5.1 兼容）
.DESCRIPTION
  实现 references/execution-safety.md §删除的验收口径 与 docs/design/execution-safety.md §7：
  在批次执行前后分别采样卷可用空间与 <盘>:\$Recycle.Bin 体量，输出固定三栏与判定：
    逻辑释放 X GB / 实测释放 Y GB / 回收站 Z GB
  从而拦截"文件进回收站后原路径消失、但磁盘空间未释放"的假成功。

  只读边界：只读 Win32_LogicalDisk 与当前用户可读的 $Recycle.Bin；不删文件、不清回收站。
用法:
  .\measure-space-delta.ps1 -Action Snapshot -Drive E: -OutFile "$env:TEMP\before.json"
  # ... 执行删除或移动批 ...
  .\measure-space-delta.ps1 -Action Compare -Drive E: -BeforeFile "$env:TEMP\before.json" -LogicalBytes 52428800
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet("Snapshot","Compare")][string]$Action,
  [Parameter(Mandatory = $true)][string]$Drive,
  [string]$OutFile = "",
  [string]$BeforeFile = "",
  [int64]$LogicalBytes = 0,
  [switch]$QuarantineMode
)

$ErrorActionPreference = "Continue"
$drv = $Drive.Trim().TrimEnd('\')
if ($drv -match '^[A-Za-z]$') { $drv = "$drv`:" }
if ($drv -notmatch '^[A-Za-z]:$') {
  Write-Error "无效盘符: $Drive（期望形如 C: 或 E:）"
  exit 1
}

function Get-DriveSnapshot([string]$d) {
  $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$d'" -EA SilentlyContinue
  if (-not $vol) {
    throw "卷不存在或不可访问: $d"
  }
  $rbRoot = Join-Path ($d + '\') '$Recycle.Bin'
  $rbBytes = 0L
  $rbCount = 0
  $rbRestricted = $false
  $rbNotes = New-Object System.Collections.ArrayList

  if (Test-Path -LiteralPath $rbRoot) {
    $stack = New-Object System.Collections.Stack
    $stack.Push((New-Object System.IO.DirectoryInfo $rbRoot))
    while ($stack.Count -gt 0) {
      $di = $stack.Pop()
      try {
        foreach ($e in $di.EnumerateFileSystemInfos('*', [IO.SearchOption]::TopDirectoryOnly)) {
          if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
          if ($e -is [IO.DirectoryInfo]) { $stack.Push($e) }
          else { $rbBytes += $e.Length; $rbCount++ }
        }
      } catch {
        $rbRestricted = $true
        [void]$rbNotes.Add($di.FullName)
      }
    }
  }

  return [ordered]@{
    drive              = $d
    captured_at        = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    free_bytes         = [int64]$vol.FreeSpace
    size_bytes         = [int64]$vol.Size
    recycle_bytes      = [int64]$rbBytes
    recycle_files      = [int]$rbCount
    recycle_restricted = [bool]$rbRestricted
    restricted_paths   = @($rbNotes.ToArray())
  }
}

try {
  $snap = Get-DriveSnapshot -d $drv
} catch {
  Write-Error $_.Exception.Message
  exit 1
}

if ($Action -eq "Snapshot") {
  $json = $snap | ConvertTo-Json -Depth 6
  if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $parent = [IO.Path]::GetDirectoryName($OutFile)
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已写入空间快照: $OutFile (drive=$drv, free_bytes=$($snap.free_bytes), recycle_bytes=$($snap.recycle_bytes))"
  } else {
    Write-Output $json
  }
  exit 0
}

# ---- Compare 模式 ----
if ([string]::IsNullOrWhiteSpace($BeforeFile) -or -not (Test-Path -LiteralPath $BeforeFile)) {
  Write-Error "缺少前置快照文件: $BeforeFile"
  exit 1
}
$before = Get-Content -LiteralPath $BeforeFile -Raw -Encoding UTF8 | ConvertFrom-Json

$yBytes = [int64]$snap.free_bytes - [int64]$before.free_bytes
$zBytes = [int64]$snap.recycle_bytes - [int64]$before.recycle_bytes
$xBytes = [int64]$LogicalBytes

$xGB = [math]::Round($xBytes / 1GB, 4)
$yGB = [math]::Round($yBytes / 1GB, 4)
$zGB = [math]::Round($zBytes / 1GB, 4)

$tol = [math]::Max(2097152L, [int64]([math]::Abs($xBytes) * 0.01))
$accountDiff = [math]::Abs($xBytes - ($yBytes + $zBytes))
$aligned = ($accountDiff -le $tol)

$verdict = "mismatch"
$verdictText = "账目不平（可能存在外部读写或回收站 SID 权限受限）"

if ($QuarantineMode -and ([math]::Abs($yBytes) -le $tol) -and ([math]::Abs($zBytes) -le $tol)) {
  $verdict = "quarantine-pending"
  $verdictText = "隔离区同盘保留中（宽限期内未释放属正确行为）"
} elseif ($xBytes -gt 0 -and $zBytes -ge ($xBytes * 0.9) -and $yBytes -lt ($xBytes * 0.1)) {
  $verdict = "trapped-in-recycle-bin"
  $verdictText = "未释放，空间在回收站"
} elseif ($xBytes -gt 0 -and $yBytes -ge ($xBytes * 0.9) -and $aligned) {
  $verdict = "released"
  $verdictText = "已释放"
} elseif ($xBytes -eq 0 -and ([math]::Abs($yBytes) -le $tol) -and ([math]::Abs($zBytes) -le $tol)) {
  $verdict = "no-op"
  $verdictText = "零变动"
}

$result = [ordered]@{
  drive              = $drv
  logical_bytes      = $xBytes
  free_delta_bytes   = $yBytes
  recycle_delta_bytes= $zBytes
  logical_gb         = $xGB
  free_delta_gb      = $yGB
  recycle_delta_gb   = $zGB
  account_aligned    = $aligned
  recycle_restricted = ($snap.recycle_restricted -or $before.recycle_restricted)
  verdict            = $verdict
  verdict_text       = $verdictText
  summary_line       = ("逻辑释放 {0} GB / 实测释放 {1} GB / 回收站 {2} GB → 判「{3}」" -f $xGB, $yGB, $zGB, $verdictText)
}

Write-Host $result.summary_line
$result | ConvertTo-Json -Depth 6
