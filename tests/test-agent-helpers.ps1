# tests/test-agent-helpers.ps1 — bootstrap-probe 与 measure-space-delta 回归测试（v0.8.1 新增，PS 5.1 兼容）
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-agent-helpers.ps1
param([string]$WorkRoot)
$ErrorActionPreference = "Continue"
$here = $PSScriptRoot
$repoRoot = Split-Path $here -Parent
$probe = Join-Path $repoRoot "scripts\bootstrap-probe.ps1"
$checker = Join-Path $repoRoot "scripts\baseline-check.ps1"
$measurer = Join-Path $repoRoot "scripts\measure-space-delta.ps1"

if (-not (Test-Path -LiteralPath $probe)) { Write-Host "FAIL  缺少 $probe" -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $measurer)) { Write-Host "FAIL  缺少 $measurer" -ForegroundColor Red; exit 1 }

if (-not $WorkRoot) { $WorkRoot = Join-Path $env:TEMP ("ma-helpers-" + [guid]::NewGuid().ToString("N").Substring(0,8)) }
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

$script:pass = $true
function Assert($cond, $msg) {
  if ($cond) { Write-Host "PASS  $msg" -ForegroundColor Green }
  else { $script:pass = $false; Write-Host "FAIL  $msg" -ForegroundColor Red }
}

$hostExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = "pwsh" }

$jLink = $null
$junctionMade = $false

try {
  # ---- 1. bootstrap-probe 正例（1MB 文件 + 空目录 + junction 跳过 + baseline-check PASS）----
  $fix = Join-Path $WorkRoot "fix"
  $d1 = Join-Path $fix "sub-1mb"
  $d2 = Join-Path $fix "sub-empty"
  $d3 = Join-Path $fix "sub-three"
  $jTarget = Join-Path $WorkRoot "ext-junc-target"
  $out1 = Join-Path $WorkRoot "out1"
  New-Item -ItemType Directory -Path $d1, $d2, $d3, $jTarget, $out1 -Force | Out-Null

  [IO.File]::WriteAllBytes((Join-Path $d1 "one.bin"), (New-Object byte[] 1048576))
  [IO.File]::WriteAllBytes((Join-Path $jTarget "two.bin"), (New-Object byte[] 2097152))
  1..3 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $d3 "f$_.txt"), "x", (New-Object System.Text.UTF8Encoding($false))) }

  $jLink = Join-Path $d1 "link-ext"
  try {
    New-Item -ItemType Junction -Path $jLink -Target $jTarget -EA Stop | Out-Null
    $junctionMade = $true
  } catch { $junctionMade = $false }

  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Roots $fix -OutDir $out1 -WriteMarkdown | Out-Null
  Assert ($LASTEXITCODE -eq 0) "bootstrap-probe 正例退出码 0（实际 $LASTEXITCODE）"

  $stamp = Get-Date -Format "yyyyMMdd"
  $bJsonPath = Join-Path $out1 "baseline-$stamp.json"
  $bMdPath = Join-Path $out1 "baseline-$stamp.md"
  Assert (Test-Path -LiteralPath $bJsonPath) "bootstrap-probe 写出 baseline JSON"
  Assert (Test-Path -LiteralPath $bMdPath) "bootstrap-probe -WriteMarkdown 写出基线 MD"

  $chkOut = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $checker -Path $bJsonPath 2>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0) "bootstrap-probe 产物直接通过 baseline-check.ps1（实际 exit=$LASTEXITCODE）"

  $bj = Get-Content -LiteralPath $bJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $row1 = $bj.top_dirs | Where-Object { $_.path -eq $d1 }
  $row2 = $bj.top_dirs | Where-Object { $_.path -eq $d2 }
  Assert ($row1.bytes -eq 1048576 -and $row1.files -eq 1 -and $row1.scan_status -eq "ok") "sub-1mb 体量=1048576, files=1（junction 未被计入，junctionMade=$junctionMade）"
  Assert ($row2.bytes -eq 0 -and $row2.files -eq 0 -and $row2.scan_status -eq "ok") "sub-empty 体量=0, files=0, scan_status=ok"

  # ---- 2. bootstrap-probe 单目录限流截断（partial + sampled=true）----
  $out2 = Join-Path $WorkRoot "out2"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -TopDirs $d3 -OutDir $out2 -MaxFilesPerDir 2 | Out-Null
  $bJson2 = Join-Path $out2 "baseline-$stamp.json"
  $bj2 = Get-Content -LiteralPath $bJson2 -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($bj2.top_dirs[0].sampled -eq $true -and $bj2.top_dirs[0].scan_status -eq "partial") "达到 MaxFilesPerDir=2 时标记 sampled=true, scan_status=partial"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $checker -Path $bJson2 | Out-Null
  Assert ($LASTEXITCODE -eq 0) "partial + sampled=true 的基线通过 baseline-check.ps1（实际 exit=$LASTEXITCODE）"

  # ---- 3. bootstrap-probe 缺失路径显式失败且被 baseline-check 拦截 ----
  $out3 = Join-Path $WorkRoot "out3"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -TopDirs (Join-Path $WorkRoot "nope-dir") -OutDir $out3 | Out-Null
  $bJson3 = Join-Path $out3 "baseline-$stamp.json"
  $bj3 = Get-Content -LiteralPath $bJson3 -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($bj3.meta.scan_status -eq "failed" -and $bj3.top_dirs[0].scan_status -eq "failed") "缺失目录显式产出 scan_status=failed"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $checker -Path $bJson3 | Out-Null
  Assert ($LASTEXITCODE -eq 1) "含 failed 采集的基线被 baseline-check.ps1 拒绝（实际 exit=$LASTEXITCODE）"

  # ---- 4. measure-space-delta 快照与三栏判定 ----
  $testDrive = if (Test-Path -LiteralPath "E:\") { "E:" } else { "C:" }
  $snapPath = Join-Path $WorkRoot "snap-test.json"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $measurer -Action Snapshot -Drive $testDrive -OutFile $snapPath | Out-Null
  Assert ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $snapPath)) "measure-space-delta Snapshot 成功写出快照 ($testDrive)"
  $snapObj = Get-Content -LiteralPath $snapPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($snapObj.free_bytes -gt 0 -and $snapObj.size_bytes -gt 0) "快照含有效 free_bytes 与 size_bytes"

  # 4a: QuarantineMode（空间未变且未进回收站 → 宽限期正常状态）
  $qOut = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $measurer -Action Compare -Drive $testDrive -BeforeFile $snapPath -LogicalBytes 52428800 -QuarantineMode | Out-String
  Assert ($qOut -match '"verdict":\s*"quarantine-pending"') "QuarantineMode 判 quarantine-pending"

  # 4b: 负对照（模拟 50MB 进了 $Recycle.Bin、FreeSpace 未变 → 必须判未释放）
  $mockRecycle = $snapObj | Select-Object *
  $mockRecycle.recycle_bytes = [int64]$snapObj.recycle_bytes - 52428800L
  $mockRecPath = Join-Path $WorkRoot "mock-recycle.json"
  [IO.File]::WriteAllText($mockRecPath, ($mockRecycle | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  $rOut = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $measurer -Action Compare -Drive $testDrive -BeforeFile $mockRecPath -LogicalBytes 52428800 | Out-String
  Assert ($rOut -match '"verdict":\s*"trapped-in-recycle-bin"' -and $rOut -match '未释放，空间在回收站') "50MB 进回收站负对照 → 判未释放，空间在回收站"

  # 4c: 正对照（现拍快照后模拟 FreeSpace 实增 500MB 且回收站不变 → 判已释放，避免测试期间后台盘读写干扰）
  $snapPath4c = Join-Path $WorkRoot "snap-4c.json"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $measurer -Action Snapshot -Drive $testDrive -OutFile $snapPath4c | Out-Null
  $snap4c = Get-Content -LiteralPath $snapPath4c -Raw -Encoding UTF8 | ConvertFrom-Json
  $mockFree = $snap4c | Select-Object *
  $mockFree.free_bytes = [int64]$snap4c.free_bytes - 524288000L
  $mockFreePath = Join-Path $WorkRoot "mock-released.json"
  [IO.File]::WriteAllText($mockFreePath, ($mockFree | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  $relOut = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $measurer -Action Compare -Drive $testDrive -BeforeFile $mockFreePath -LogicalBytes 524288000 | Out-String
  Assert ($relOut -match '"verdict":\s*"released"' -and $relOut -match '已释放') "500MB 空间实增正对照 → 判已释放"

  # 4d: 非法盘符
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $measurer -Action Snapshot -Drive "INVALID" 2>$null | Out-Null
  Assert ($LASTEXITCODE -eq 1) "非法盘符 → 退出码 1（实际 $LASTEXITCODE）"

  Write-Host ""
  if ($script:pass) { Write-Host "全部通过" -ForegroundColor Green } else { Write-Host "存在失败断言" -ForegroundColor Red }
} finally {
  if ($junctionMade -and $jLink -and (Test-Path -LiteralPath $jLink)) {
    cmd /c rmdir "$jLink" 2>$null
  }
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force -EA SilentlyContinue
  if (Test-Path -LiteralPath $WorkRoot) {
    $script:pass = $false
    Write-Host "FAIL  临时区未清理: $WorkRoot" -ForegroundColor Red
  } else {
    Write-Host "PASS  临时区已清理: $WorkRoot" -ForegroundColor Green
  }
}

if ($script:pass) { exit 0 } else { exit 1 }
