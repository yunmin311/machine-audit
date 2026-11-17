# tests/test-agent-helpers.ps1 — probe.ps1 四动作回归测试（v0.9.0，PS 5.1 兼容）
# 覆盖：-Action env / space / docs / delta
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-agent-helpers.ps1
param([string]$WorkRoot)
$ErrorActionPreference = "Continue"
$here = $PSScriptRoot
$repoRoot = Split-Path $here -Parent
$probe = Join-Path $repoRoot "scripts\probe.ps1"
$checker = Join-Path $repoRoot "scripts\baseline-check.ps1"

if (-not (Test-Path -LiteralPath $probe)) { Write-Host "FAIL  缺少 $probe" -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $checker)) { Write-Host "FAIL  缺少 $checker" -ForegroundColor Red; exit 1 }

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
  $stamp = Get-Date -Format "yyyyMMdd"

  # ---- 1. -Action env（环境与卷采集 + schema 1.2 + baseline-check PASS）----
  $out1 = Join-Path $WorkRoot "out1"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action env -OutDir $out1 -WriteMarkdown | Out-Null
  Assert ($LASTEXITCODE -eq 0) "probe -Action env 退出码 0（实际 $LASTEXITCODE）"

  $bJsonPath = Join-Path $out1 "baseline-$stamp.json"
  $bMdPath = Join-Path $out1 "baseline-$stamp.md"
  Assert (Test-Path -LiteralPath $bJsonPath) "probe -Action env 写出 baseline JSON"
  Assert (Test-Path -LiteralPath $bMdPath) "probe -Action env -WriteMarkdown 写出基线 MD"

  $bjEnv = Get-Content -LiteralPath $bJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($bjEnv.schema_version -eq "1.2" -and $bjEnv.meta.skill_version -eq "0.9.0" -and @($bjEnv.top_dirs).Count -eq 0) "env 输出 schema_version=1.2, skill_version=0.9.0, top_dirs=[]"
  Assert (($null -ne $bjEnv.environment.os) -and ($null -ne $bjEnv.environment.privilege) -and ($null -ne $bjEnv.environment.cloud_redirection) -and (@($bjEnv.drives).Count -gt 0)) "env 输出含 os/privilege/cloud_redirection/drives 全部约定字段"

  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $checker -Path $bJsonPath | Out-Null
  Assert ($LASTEXITCODE -eq 0) "probe -Action env 产物直接通过 baseline-check.ps1（实际 exit=$LASTEXITCODE）"

  # ---- 2. -Action space（1MB 文件 + 空目录 + junction 跳过 + 合并入基线 PASS）----
  $fix = Join-Path $WorkRoot "fix"
  $d1 = Join-Path $fix "sub-1mb"
  $d2 = Join-Path $fix "sub-empty"
  $d3 = Join-Path $fix "sub-three"
  $jTarget = Join-Path $WorkRoot "ext-junc-target"
  New-Item -ItemType Directory -Path $d1, $d2, $d3, $jTarget -Force | Out-Null

  [IO.File]::WriteAllBytes((Join-Path $d1 "one.bin"), (New-Object byte[] 1048576))
  [IO.File]::WriteAllBytes((Join-Path $jTarget "two.bin"), (New-Object byte[] 2097152))
  1..3 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $d3 "f$_.txt"), "x", (New-Object System.Text.UTF8Encoding($false))) }

  $jLink = Join-Path $d1 "link-ext"
  try {
    New-Item -ItemType Junction -Path $jLink -Target $jTarget -EA Stop | Out-Null
    $junctionMade = $true
  } catch { $junctionMade = $false }

  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action space -Roots $fix -Baseline $bJsonPath -WriteMarkdown | Out-Null
  Assert ($LASTEXITCODE -eq 0) "probe -Action space -Baseline 退出码 0（实际 $LASTEXITCODE）"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $checker -Path $bJsonPath | Out-Null
  Assert ($LASTEXITCODE -eq 0) "space 合并后的基线通过 baseline-check.ps1（实际 exit=$LASTEXITCODE）"

  $bjSpace = Get-Content -LiteralPath $bJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $row1 = $bjSpace.top_dirs | Where-Object { $_.path -eq $d1 }
  $row2 = $bjSpace.top_dirs | Where-Object { $_.path -eq $d2 }
  Assert ($row1.bytes -eq 1048576 -and $row1.files -eq 1 -and $row1.scan_status -eq "ok") "space: sub-1mb 体量=1048576, files=1（junction 未被计入，junctionMade=$junctionMade）"
  Assert ($row2.bytes -eq 0 -and $row2.files -eq 0 -and $row2.scan_status -eq "ok") "space: sub-empty 体量=0, files=0, scan_status=ok"

  # 2b: standalone -Action space（不传 -Baseline，直接输出 JSON）
  $spStandalone = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action space -TopDirs $d1 | Out-String | ConvertFrom-Json
  Assert ($spStandalone.scan_status -eq "ok" -and @($spStandalone.top_dirs).Count -eq 1 -and $spStandalone.top_dirs[0].bytes -eq 1048576) "space 独立调用正确返回 top_dirs JSON"

  # 2c: 单目录限流截断（partial + sampled=true）
  $out2 = Join-Path $WorkRoot "out2"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action env -OutDir $out2 | Out-Null
  $bJson2 = Join-Path $out2 "baseline-$stamp.json"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action space -TopDirs $d3 -Baseline $bJson2 -MaxFilesPerDir 2 | Out-Null
  $bj2 = Get-Content -LiteralPath $bJson2 -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($bj2.top_dirs[0].sampled -eq $true -and $bj2.top_dirs[0].scan_status -eq "partial") "space: 达到 MaxFilesPerDir=2 时标记 sampled=true, scan_status=partial"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $checker -Path $bJson2 | Out-Null
  Assert ($LASTEXITCODE -eq 0) "partial + sampled=true 的基线通过 baseline-check.ps1（实际 exit=$LASTEXITCODE）"

  # 2d: 缺失路径显式失败且被 baseline-check 拦截
  $out3 = Join-Path $WorkRoot "out3"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action env -OutDir $out3 | Out-Null
  $bJson3 = Join-Path $out3 "baseline-$stamp.json"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action space -TopDirs (Join-Path $WorkRoot "nope-dir") -Baseline $bJson3 | Out-Null
  $bj3 = Get-Content -LiteralPath $bJson3 -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($bj3.meta.scan_status -eq "failed" -and $bj3.top_dirs[0].scan_status -eq "failed") "space: 缺失目录显式产出 scan_status=failed"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $checker -Path $bJson3 | Out-Null
  Assert ($LASTEXITCODE -eq 1) "含 failed 采集的基线被 baseline-check.ps1 拒绝（实际 exit=$LASTEXITCODE）"

  # ---- 3. -Action docs（文档卫生只读扫描 + 硬触发阈值判定）----
  $docRoot = Join-Path $WorkRoot "doc-root"
  $docSub = Join-Path $docRoot "bloated-topic"
  $docNodeMod = Join-Path $docSub "node_modules"
  New-Item -ItemType Directory -Path $docSub, $docNodeMod -Force | Out-Null
  1..3 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $docSub "note-$_.md"), "# note $_", (New-Object System.Text.UTF8Encoding($false))) }
  1..5 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $docNodeMod "ignored-$_.md"), "# skip", (New-Object System.Text.UTF8Encoding($false))) }
  $docOut = Join-Path $WorkRoot "hygiene.md"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action docs -Roots $docRoot -DirThreshold 2 -OutFile $docOut | Out-Null
  Assert ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $docOut)) "probe -Action docs 退出码 0 并写出报告"
  $docMd = Get-Content -LiteralPath $docOut -Raw -Encoding UTF8
  Assert ($docMd -match '\| bloated-topic \| 3 \|' -and $docMd -match '硬触发：目录超 2 份') "docs 跳过 node_modules 且精确命中超阈值目录 (3 > 2)"
  Assert ((Get-ChildItem -LiteralPath $docSub -Filter *.md -File).Count -eq 3) "docs 严格只读（未改动被扫目录文件）"

  # ---- 4. -Action delta（快照与三栏判定）----
  $testDrive = if (Test-Path -LiteralPath "E:\") { "E:" } else { "C:" }
  $snapPath = Join-Path $WorkRoot "snap-test.json"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action delta -DeltaMode Snapshot -Drive $testDrive -OutFile $snapPath | Out-Null
  Assert ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $snapPath)) "probe -Action delta Snapshot 成功写出快照 ($testDrive)"
  $snapObj = Get-Content -LiteralPath $snapPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($snapObj.free_bytes -gt 0 -and $snapObj.size_bytes -gt 0) "delta 快照含有效 free_bytes 与 size_bytes"

  # 4a: QuarantineMode
  $qOut = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action delta -DeltaMode Compare -Drive $testDrive -BeforeFile $snapPath -LogicalBytes 52428800 -QuarantineMode | Out-String
  Assert ($qOut -match '"verdict":\s*"quarantine-pending"') "delta: QuarantineMode 判 quarantine-pending"

  # 4b: 负对照（50MB 进回收站 → 判未释放）
  $mockRecycle = $snapObj | Select-Object *
  $mockRecycle.recycle_bytes = [int64]$snapObj.recycle_bytes - 52428800L
  $mockRecPath = Join-Path $WorkRoot "mock-recycle.json"
  [IO.File]::WriteAllText($mockRecPath, ($mockRecycle | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  $rOut = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action delta -DeltaMode Compare -Drive $testDrive -BeforeFile $mockRecPath -LogicalBytes 52428800 | Out-String
  Assert ($rOut -match '"verdict":\s*"trapped-in-recycle-bin"' -and $rOut -match '未释放，空间在回收站') "delta: 50MB 进回收站负对照 → 判未释放，空间在回收站"

  # 4c: 正对照（现拍快照后模拟 FreeSpace 实增 500MB → 判已释放）
  $snapPath4c = Join-Path $WorkRoot "snap-4c.json"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action delta -DeltaMode Snapshot -Drive $testDrive -OutFile $snapPath4c | Out-Null
  $snap4c = Get-Content -LiteralPath $snapPath4c -Raw -Encoding UTF8 | ConvertFrom-Json
  $mockFree = $snap4c | Select-Object *
  $mockFree.free_bytes = [int64]$snap4c.free_bytes - 524288000L
  $mockFreePath = Join-Path $WorkRoot "mock-released.json"
  [IO.File]::WriteAllText($mockFreePath, ($mockFree | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  $relOut = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action delta -DeltaMode Compare -Drive $testDrive -BeforeFile $mockFreePath -LogicalBytes 524288000 | Out-String
  Assert ($relOut -match '"verdict":\s*"released"' -and $relOut -match '已释放') "delta: 500MB 空间实增正对照 → 判已释放"

  # 4d: 非法盘符
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action delta -DeltaMode Snapshot -Drive "INVALID" 2>$null | Out-Null
  Assert ($LASTEXITCODE -eq 1) "delta: 非法盘符 → 退出码 1（实际 $LASTEXITCODE）"

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
