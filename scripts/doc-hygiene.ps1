<#
.SYNOPSIS
  doc-hygiene.ps1 - 文档卫生扫描 v1.0（只读）
.DESCRIPTION
  按 references/memory-hygiene.md 的五层模型扫描 Markdown 文档膨胀情况：
  统计每个顶层目录的 .md 数量/体量/年龄分布，标出越过阈值的目录，并给出
  「蒸馏 / 归档 / 退役」三档建议。

  **只读**：不移动、不删除、不修改任何文件；输出仅到控制台或 -OutFile。

  阈值默认取自 memory-hygiene.md §3：单目录 > 200 份为硬触发。
用法:
  .\doc-hygiene.ps1 -Roots "D:\MyProjects" -OutFile ".\hygiene.md"
  .\doc-hygiene.ps1                       # 无 -Roots 时扫描当前目录
#>
param(
  [string[]]$Roots = @(),
  [int]$DirThreshold = 200,
  [int]$FileLineThreshold = 3000,
  [int]$LogAgeDays = 30,
  [int]$ReportAgeDays = 90,
  [string]$OutFile = ""
)

$ErrorActionPreference = "SilentlyContinue"
if (-not $Roots -or $Roots.Count -eq 0) { $Roots = @((Get-Location).Path) }

$exclude = @("node_modules", ".git", "dist", "build", ".next", ".venv", "venv", "__pycache__", ".cache", "target", ".turbo", "coverage")

function Get-MdFiles([string]$path) {
  Get-ChildItem -LiteralPath $path -Recurse -File -Filter *.md -Force |
    Where-Object {
      $p = $_.FullName
      -not ($exclude | Where-Object { $p -match [regex]::Escape("\$_\(\\|$)") })
    }
}

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

foreach ($root in $Roots) {
  if (-not (Test-Path -LiteralPath $root)) { $report.Add("> 根目录不存在：$root"); continue }
  $report.Add("## $root")
  $report.Add("")
  $report.Add("| 目录 | MD 数 | 体量 | >${LogAgeDays}天 | >${ReportAgeDays}天 | 最大文件行数 | 判定 |")
  $report.Add("|---|---:|---:|---:|---:|---:|---|")

  $dirs = Get-ChildItem -LiteralPath $root -Directory -Force
  foreach ($d in $dirs) {
    if ($exclude -contains $d.Name) { continue }
    $files = Get-MdFiles $d.FullName
    if (-not $files -or $files.Count -eq 0) { continue }

    $bytes = ($files | Measure-Object Length -Sum).Sum
    if ($null -eq $bytes) { $bytes = 0 }
    $old30 = ($files | Where-Object { ($now - $_.LastWriteTime).TotalDays -gt $LogAgeDays }).Count
    $old90 = ($files | Where-Object { ($now - $_.LastWriteTime).TotalDays -gt $ReportAgeDays }).Count

    $maxLines = 0; $maxName = ""
    foreach ($f in ($files | Sort-Object Length -Descending | Select-Object -First 5)) {
      $n = (Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
      if ($n -gt $maxLines) { $maxLines = $n; $maxName = $f.Name }
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

# 汇总与建议
$big = $rows | Where-Object { $_.Count -gt $DirThreshold } | Sort-Object Count -Descending
$aged = $rows | Where-Object { $_.Old90 -gt ($_.Count * 0.6) } | Sort-Object Count -Descending

$report.Add("## 汇总")
$report.Add("")
$report.Add("- 扫描范围内 MD 总数：**$totalAll**")
$report.Add("- 越过目录阈值（>$DirThreshold）的目录：$($big.Count) 个")
$report.Add("")

if ($big.Count -gt 0) {
  $report.Add("### 优先蒸馏（文件数超标）")
  $report.Add("")
  foreach ($r in $big) { $report.Add("- ``$($r.Dir)``：$($r.Count) 份 / $([math]::Round($r.Bytes/1MB,1)) MB") }
  $report.Add("")
}
if ($aged.Count -gt 0) {
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
if ($OutFile) {
  $utf8bom = New-Object System.Text.UTF8Encoding($true)
  [IO.File]::WriteAllText($OutFile, $text, $utf8bom)
  Write-Host "已写出：$OutFile"
} else {
  Write-Output $text
}
