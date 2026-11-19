# tests/test-agent-helpers.ps1 — probe.ps1 六动作与公开边缘刑具回归测试（v0.9.5，PS 5.1 兼容）
# 覆盖：-Action env / space / docs / delta / rules / dupes + 方括号通配符/云占位/超长路径(MAX_PATH)刑具
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
try { $WorkRoot = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\') } catch { }

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
  Assert ($bjEnv.schema_version -eq "1.2" -and $bjEnv.meta.skill_version -eq "1.0.1" -and @($bjEnv.top_dirs).Count -eq 0) "env 输出 schema_version=1.2, skill_version=1.0.1, top_dirs=[]"
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

  # 3b: 重叠父子 -Roots 去重（不双计 MD 总数）
  $docOutOverlap = Join-Path $WorkRoot "hygiene-overlap.md"
  & $hostExe -NoProfile -NonInteractive -Command "& '$probe' -Action docs -Roots @('$docRoot','$docSub') -DirThreshold 2 -OutFile '$docOutOverlap'" | Out-Null
  $docMd2 = Get-Content -LiteralPath $docOutOverlap -Raw -Encoding UTF8
  Assert ($LASTEXITCODE -eq 0 -and $docMd2 -match '扫描范围内 MD 总数：\*\*3\*\*') "docs 重叠父子根目录精确去重汇总（唯一 MD=3，不翻倍）"

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

  # 4e: 预估 vs 实际回收对比字段（容忍系统盘并发 IO 波动，不硬卡 0 字节）
  $relObj = $relOut | ConvertFrom-Json
  Assert ($null -ne $relObj.estimated_vs_actual_diff_bytes -and [math]::Abs([int64]$relObj.estimated_vs_actual_diff_bytes) -le 10485760 -and $relObj.estimated_vs_actual_summary -match '预估.*实测释放.*偏差') "delta: 输出 estimated_vs_actual_diff_bytes 与 summary（实测偏差=$($relObj.estimated_vs_actual_diff_bytes)B <= 10MB）"

  # ---- 5. assets/cleanup-rules.json 规则库校验 + probe -Action rules ----
  $rulesAsset = Join-Path $repoRoot "assets\cleanup-rules.json"
  Assert (Test-Path -LiteralPath $rulesAsset) "assets/cleanup-rules.json 存在"
  $rulesRaw = Get-Content -LiteralPath $rulesAsset -Raw -Encoding UTF8
  $rulesCfg = $rulesRaw | ConvertFrom-Json
  $allIds = @($rulesCfg.rules | ForEach-Object { $_.id })
  $uniqIds = @($allIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  $validRisks = @($rulesCfg.rules | Where-Object { $_.risk -in @("low","medium","high") -and $_.execution_mode -in @("native-command","quarantine","empty-recycle-bin") })
  $hasTouchBoundary = @($rulesCfg.rules | Where-Object { @($_.does_not_touch).Count -ge 1 -and -not [string]::IsNullOrWhiteSpace("$($_.does_not_touch[0])") })
  $bareRootPat = '^(?:[A-Za-z]:\\?|%SystemDrive%\\?|%USERPROFILE%\\?)$'
  $hasBareRoot = @($rulesCfg.rules | ForEach-Object { @($_.probe.paths_env) } | Where-Object { "$_".Trim() -match $bareRootPat })
  $badUserLit = 'C:' + '\\Users\\(?!Public)'
  $badTmpLit = 'AppData' + '\\Local\\' + 'Temp'
  Assert ($rulesCfg.schema_version -eq "1.0" -and $allIds.Count -ge 18 -and $uniqIds.Count -eq $allIds.Count) "cleanup-rules.json 含 >=18 条规则且 id 唯一（实际 $($allIds.Count)）"
  Assert ($validRisks.Count -eq $allIds.Count -and $hasTouchBoundary.Count -eq $allIds.Count -and $hasBareRoot.Count -eq 0) "cleanup-rules.json 每条均含合规 risk/execution_mode 与非空 does_not_touch，且无盘根/用户根"
  Assert (-not ($rulesRaw -match $badUserLit) -and -not ($rulesRaw -match $badTmpLit)) "cleanup-rules.json 零个人目录或硬编码 Temp 绝对路径"

  # 5b: -Action rules 在默认规则库按不存在 RuleIds 快速只读空匹配（不误扫宿主真实大缓存）
  $rEmpty = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action rules -RuleIds @("nonexistent-rule-id") | Out-String | ConvertFrom-Json
  Assert ($LASTEXITCODE -eq 0 -and $rEmpty.rules_total -eq $allIds.Count -and $rEmpty.rules_matched -eq 0) "probe -Action rules 成功载入默认规则库 ($($rEmpty.rules_total) 条)"

  # 5c: -Action rules 使用合成临时规则验证 %ENV% 展开、精确估算、部分失败聚合与只读边界
  $mockRuleDir = Join-Path $WorkRoot "mock-cache-dir"
  New-Item -ItemType Directory -Path $mockRuleDir -Force | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $mockRuleDir "cache-item.bin"), (New-Object byte[] 524288))
  $mockBadFilePath = Join-Path $WorkRoot "mock-file-not-dir.txt"
  [IO.File]::WriteAllText($mockBadFilePath, "not-a-dir", (New-Object System.Text.UTF8Encoding($false)))
  $env:MA_RULE_TEST_DIR = $mockRuleDir
  $env:MA_RULE_BAD_FILE = $mockBadFilePath
  $mockRulesObj = @{
    schema_version = "1.0"
    rules = @(
      @{
        id = "mock-cache"
        category = "package-manager"
        title = "Mock Cache"
        risk = "low"
        execution_mode = "native-command"
        preferred_command = "mock cache clean"
        needs_owner_confirm = $false
        probe = @{ commands = @(); paths_env = @("%MA_RULE_TEST_DIR%", "%MA_RULE_BAD_FILE%") }
        does_not_touch = @("Mock workspace sources")
        reason = "Synthetic test"
      },
      @{
        id = "mock-missing"
        category = "browser"
        title = "Mock Missing"
        risk = "low"
        execution_mode = "quarantine"
        preferred_command = $null
        needs_owner_confirm = $false
        probe = @{ commands = @(); paths_env = @("%MA_RULE_TEST_DIR%\\not-here", "%MA_UNSET_VAR_XYZ%\\cache") }
        does_not_touch = @("Mock user profile")
        reason = "Should not match"
      }
    )
  }
  $mockRulesJson = Join-Path $WorkRoot "mock-rules.json"
  $mockRulesOut = Join-Path $WorkRoot "mock-rules-out.json"
  [IO.File]::WriteAllText($mockRulesJson, ($mockRulesObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action rules -RulesFile $mockRulesJson -OutFile $mockRulesOut | Out-Null
  Assert ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $mockRulesOut)) "probe -Action rules 自定义规则退出码 0 并写出报告"
  $rMock = Get-Content -LiteralPath $mockRulesOut -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($rMock.rules_matched -eq 1 -and $rMock.estimated_total_bytes -eq 524288 -and $rMock.estimated_total_allocated_bytes -ge 524288 -and $rMock.matched[0].id -eq "mock-cache") "rules: 精确命中 mock-cache，忽略未命中与未展开变量，估算=524288"
  Assert ($rMock.matched[0].scan_status -eq "partial" -and @($rMock.matched[0].path_details).Count -eq 2 -and $rMock.matched[0].path_details[0].scan_status -eq "ok" -and $rMock.matched[0].path_details[1].scan_status -eq "failed") "rules: 多路径部分成功聚合为 partial 且在 path_details 明晰逐路径状态"
  Assert (@($rMock.matched[0].does_not_touch).Count -eq 1 -and $rMock.matched[0].preferred_command -eq "mock cache clean" -and (Test-Path -LiteralPath (Join-Path $mockRuleDir "cache-item.bin"))) "rules: 透传 does_not_touch 与 preferred_command 且被测目录严格只读"

  # ---- 6. -Action space Batch 1 增强：3x3 年龄x体量矩阵 + Top-N 物理占盘 + 卷/子树对账 + MD 段落 ----
  $fixB1 = Join-Path $WorkRoot "fix-b1"
  $subB1 = Join-Path $fixB1 "age-buckets"
  New-Item -ItemType Directory -Path $subB1 -Force | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $fixB1 "root-note.bin"), (New-Object byte[] 64))
  $pFresh = Join-Path $subB1 "fresh-2mb.bin"
  $pMid = Join-Path $subB1 "mid-small.txt"
  $pOld = Join-Path $subB1 "old-1mb.bin"
  [IO.File]::WriteAllBytes($pFresh, (New-Object byte[] 2097152))
  [IO.File]::WriteAllBytes($pMid, (New-Object byte[] 128))
  [IO.File]::WriteAllBytes($pOld, (New-Object byte[] 1048576))
  (Get-Item -LiteralPath $pMid).LastWriteTime = (Get-Date).AddDays(-60)
  (Get-Item -LiteralPath $pOld).LastWriteTime = (Get-Date).AddDays(-220)

  $outB1 = Join-Path $WorkRoot "out-b1"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action env -OutDir $outB1 | Out-Null
  $bJsonB1 = Join-Path $outB1 "baseline-$stamp.json"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action space -Roots $fixB1 -Baseline $bJsonB1 -LargeFileMinBytes 524288 -TopLargeCount 10 -WriteMarkdown | Out-Null
  Assert ($LASTEXITCODE -eq 0) "space Batch 1 扩展扫描退出码 0（实际 $LASTEXITCODE）"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $checker -Path $bJsonB1 | Out-Null
  Assert ($LASTEXITCODE -eq 0) "含 snapshots.space 扩展数据的基线仍通过 baseline-check.ps1（实际 exit=$LASTEXITCODE）"

  $bjB1 = Get-Content -LiteralPath $bJsonB1 -Raw -Encoding UTF8 | ConvertFrom-Json
  $mx = $bjB1.snapshots.space.age_size_matrix
  Assert ($mx.lt_30d.mb1_to_100.files -eq 1 -and $mx.d30_to_180.lt_1mb.files -eq 1 -and $mx.gt_180d.mb1_to_100.files -eq 1 -and $mx.gt_180d.mb1_to_100.bytes -eq 1048576) "space 3x3 矩阵精确分桶 (<30d / 30-180d / >180d)"
  $tl = @($bjB1.snapshots.space.top_large_files)
  Assert ($tl.Count -eq 2 -and $tl[0].logical_bytes -eq 2097152 -and $tl[0].allocated_bytes -ge 2097152 -and $tl[0].is_sparse -eq $false -and $tl[0].is_cloud_placeholder -eq $false -and $tl[1].age_days -ge 219) "space Top-N 按大小降序输出物理占盘与标志位"
  $vr = @($bjB1.snapshots.space.volume_reconciliation)
  Assert ($vr.Count -eq 1 -and $vr[0].scope -eq "directory-subtree" -and $vr[0].root_files_bytes -eq 64 -and $vr[0].enumerated_bytes -eq (64 + 2097152 + 128 + 1048576)) "space 子树对账精确汇总直属文件与一级子目录总字节"
  $bMdB1 = Get-Content -LiteralPath (Join-Path $outB1 "baseline-$stamp.md") -Raw -Encoding UTF8
  Assert ($bMdB1 -match '## §SpaceBreakdown' -and $bMdB1 -match '大文件 \(>=Threshold\)' -and $bMdB1 -match 'fresh-2mb\.bin' -and $bMdB1 -match '未归账') "space -WriteMarkdown 输出 §SpaceBreakdown（矩阵/Top 大文件/未归账对账）"

  # ---- 7. Batch 2: 结构化筛选 (-MinSizeMB / -MinAgeDays / -IncludeExt) 与流式断点 (-StreamOut / -Resume) ----
  $spFilt = & $hostExe -NoProfile -Command "& '$probe' -Action space -Roots @('$fixB1') -MinSizeMB 0.5 -MinAgeDays 180 -IncludeExt @('.bin')" | Out-String | ConvertFrom-Json
  Assert ($LASTEXITCODE -eq 0 -and @($spFilt.top_large_files).Count -eq 1 -and $spFilt.top_large_files[0].path -like '*old-1mb.bin') "space 结构化筛选精准锁定 >=0.5MB & >=180d & .bin（仅 old-1mb.bin）"
  Assert ($spFilt.age_size_matrix.lt_30d.mb1_to_100.files -eq 1 -and $spFilt.top_dirs[0].files -eq 3 -and $spFilt.applied_filters.min_age_days -eq 180) "space 筛选仅作用于候选大文件，目录与 3x3 账目完全不失真"

  $fixStream = Join-Path $WorkRoot "fix-stream"
  $sDirA = Join-Path $fixStream "dir-a"
  $sDirB = Join-Path $fixStream "dir-b"
  New-Item -ItemType Directory -Path $sDirA, $sDirB -Force | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $fixStream "root-big.bin"), (New-Object byte[] 600000))
  [IO.File]::WriteAllBytes((Join-Path $sDirA "a.bin"), (New-Object byte[] 100))
  [IO.File]::WriteAllBytes((Join-Path $sDirA "a-big.bin"), (New-Object byte[] 700000))
  [IO.File]::WriteAllBytes((Join-Path $sDirB "b.bin"), (New-Object byte[] 200))
  $streamFile = Join-Path $WorkRoot "space-stream.jsonl"
  & $hostExe -NoProfile -Command "& '$probe' -Action space -TopDirs @('$sDirA') -MinSizeMB 0.5 -StreamOut '$streamFile'" | Out-Null
  $streamLines1 = @(Get-Content -LiteralPath $streamFile -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  Assert ($LASTEXITCODE -eq 0 -and $streamLines1.Count -eq 1) "space -StreamOut 实时写出已完成目录 JSONL（首批 1 行）"

  $spResumed = & $hostExe -NoProfile -Command "& '$probe' -Action space -Roots @('$fixStream') -MinSizeMB 0.5 -StreamOut '$streamFile' -Resume" | Out-String | ConvertFrom-Json
  $streamLines2 = @(Get-Content -LiteralPath $streamFile -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  Assert ($LASTEXITCODE -eq 0 -and $spResumed.resumed_from_stream_count -eq 1 -and $spResumed.stream_cache_bypassed_count -eq 0 -and @($spResumed.top_dirs).Count -eq 2 -and $streamLines2.Count -eq 2) "space -Resume 跳过已完成目录(resumed=1)并续扫补齐剩余目录"
  Assert (@($spResumed.top_large_files).Count -eq 2 -and $spResumed.age_size_matrix.lt_30d.lt_1mb.files -eq 4) "space 根目录直属大文件(root-big.bin)与续扫目录(a-big.bin)均完整纳入矩阵与 Top 大文件"

  # 7b: 续扫传入比缓存更宽松阈值(-MinSizeBytes 150 < 原先 0.5MB)时自动绕过陈旧流缓存，避免静音漏报
  $spBroad = & $hostExe -NoProfile -Command "& '$probe' -Action space -Roots @('$fixStream') -MinSizeBytes 150 -StreamOut '$streamFile' -Resume" | Out-String | ConvertFrom-Json
  Assert ($LASTEXITCODE -eq 0 -and $spBroad.stream_cache_bypassed_count -eq 2 -and @($spBroad.top_large_files).Count -eq 3) "space -Resume 发现更宽条件时自动绕过流缓存重扫并检出 b.bin(200B)"

  # ---- 8. Batch 2: -Action dupes 四级漏斗查重 + NTFS 硬链接保护 + 重叠根去重 ----
  $dupeRoot = Join-Path $WorkRoot "dupe-root"
  $df1 = Join-Path $dupeRoot "folder-1"
  $df2 = Join-Path $dupeRoot "folder-2"
  New-Item -ItemType Directory -Path $df1, $df2 -Force | Out-Null

  # Pair A: 20480B 真重复（含年龄差）
  $bufA = New-Object byte[] 20480
  for ($bi = 0; $bi -lt $bufA.Length; $bi++) { $bufA[$bi] = [byte](($bi * 7 + 13) % 251) }
  $pa1 = Join-Path $df1 "copy1.iso"
  $pa2 = Join-Path $df2 "copy2.iso"
  [IO.File]::WriteAllBytes($pa1, $bufA)
  [IO.File]::WriteAllBytes($pa2, $bufA)
  (Get-Item -LiteralPath $pa1).LastWriteTime = (Get-Date).AddDays(-10)

  # Pair B: 24576B 仅首字节不同（必须在第 2 关局部哈希即被淘汰，不进第 3 关）
  $bufB1 = New-Object byte[] 24576
  $bufB2 = New-Object byte[] 24576
  $bufB1[0] = 0xAA; $bufB2[0] = 0xBB
  [IO.File]::WriteAllBytes((Join-Path $df1 "head-diff-1.bin"), $bufB1)
  [IO.File]::WriteAllBytes((Join-Path $df2 "head-diff-2.bin"), $bufB2)

  # Pair C: 28672B 首尾 4KB 全同，仅正中间 1 字节不同（进第 3 关全量 SHA256 后判非重复）
  $bufC1 = New-Object byte[] 28672
  $bufC2 = New-Object byte[] 28672
  $bufC1[14000] = 0x11; $bufC2[14000] = 0x22
  [IO.File]::WriteAllBytes((Join-Path $df1 "mid-diff-1.bin"), $bufC1)
  [IO.File]::WriteAllBytes((Join-Path $df2 "mid-diff-2.bin"), $bufC2)

  # Pair D: 0 字节 + 低于 MinSize 的小文件 + 忽略扩展名文件
  [IO.File]::WriteAllBytes((Join-Path $df1 "zero1.iso"), (New-Object byte[] 0))
  [IO.File]::WriteAllBytes((Join-Path $df2 "zero2.iso"), (New-Object byte[] 0))
  [IO.File]::WriteAllBytes((Join-Path $df1 "small.iso"), (New-Object byte[] 1024))
  [IO.File]::WriteAllBytes((Join-Path $df1 "skip1.txt"), $bufA)
  [IO.File]::WriteAllBytes((Join-Path $df2 "skip2.txt"), $bufA)

  # Hardlink pair: 32768B NTFS 硬链接（必须被归入 hardlink_clusters 且不进第 2 关）
  $bufHL = New-Object byte[] 32768
  $bufHL[10] = 0x55
  $hlSrc = Join-Path $df1 "hl-shared.bin"
  $hlDst = Join-Path $df2 "hl-shared-link.bin"
  [IO.File]::WriteAllBytes($hlSrc, $bufHL)
  $hlMade = $false
  try {
    cmd /c mklink /H "$hlDst" "$hlSrc" >$null 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $hlDst)) { $hlMade = $true }
  } catch { $hlMade = $false }

  $dupesJson = Join-Path $WorkRoot "dupes-out.json"
  & $hostExe -NoProfile -Command "& '$probe' -Action dupes -Roots @('$dupeRoot','$df1') -MinSizeBytes 16384 -IncludeExt @('.iso','.bin') -OutFile '$dupesJson'" | Out-Null
  Assert ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $dupesJson)) "dupes 四级漏斗退出码 0 并写出报告（含重叠根测试）"
  $dp = Get-Content -LiteralPath $dupesJson -Raw -Encoding UTF8 | ConvertFrom-Json
  $fs = $dp.funnel_stats
  Assert ($fs.skipped_zero_bytes -eq 2 -and $fs.skipped_filtered_out -ge 3) "dupes 第 0 关跳过 0 字节(2)与扩展名/阈值过滤文件"
  Assert ($fs.stage2_partial_hashed_files -eq 6 -and $fs.stage3_full_hashed_files -eq 4) "dupes 第 2/3 关漏斗逐级收敛正确（仅 6 件做头尾 4KB 哈希，仅 4 件进全量 SHA256；hlMade=$hlMade）"
  Assert ($fs.duplicate_groups_count -eq 1 -and $dp.duplicate_groups[0].reclaimable_logical_bytes -eq 20480 -and $dp.duplicate_groups[0].oldest_path -eq $pa1 -and $dp.duplicate_groups[0].newest_path -eq $pa2) "dupes 精确确认仅 Pair A 重复，可释放 20480B 并区分最旧/最新路径"
  if ($hlMade) {
    Assert ($fs.hardlink_clusters_collapsed -eq 1 -and @($dp.hardlink_clusters).Count -eq 1 -and $dp.hardlink_clusters[0].reclaimable_bytes -eq 0) "dupes 正确识别 NTFS 硬链接簇并标记可回收空间为 0"
  } else {
    Assert $true "dupes 硬链接用例在非 NTFS 卷跳过（hlMade=False）"
  }
  Assert ((Test-Path -LiteralPath $pa1) -and (Test-Path -LiteralPath $pa2)) "dupes 严格只读（未改动或删除任何测试副本）"

  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action dupes 2>$null | Out-Null
  Assert ($LASTEXITCODE -eq 1) "dupes 未传 -Roots/-TopDirs 拒绝执行（退出码 1，防误扫全盘）"

  # 8b: dupes 含外部硬链接副本的重复组推荐保留与可回收口径校验
  $dupeExtScan = Join-Path $WorkRoot "dupe-ext-scan"
  $dupeExtOut = Join-Path $WorkRoot "dupe-ext-outside"
  New-Item -ItemType Directory -Path $dupeExtScan, $dupeExtOut -Force | Out-Null
  $bufExt = New-Object byte[] 24576
  for ($bi = 0; $bi -lt $bufExt.Length; $bi++) { $bufExt[$bi] = [byte](($bi * 11 + 3) % 251) }
  $extOutsideFile = Join-Path $dupeExtOut "outside-anchor.bin"
  $extLinkedCopy = Join-Path $dupeExtScan "linked-newer.bin"
  $extSoloOlder = Join-Path $dupeExtScan "solo-older.bin"
  [IO.File]::WriteAllBytes($extOutsideFile, $bufExt)
  [IO.File]::WriteAllBytes($extSoloOlder, $bufExt)
  (Get-Item -LiteralPath $extSoloOlder).LastWriteTime = (Get-Date).AddDays(-5)
  $extHlMade = $false
  try {
    cmd /c mklink /H "$extLinkedCopy" "$extOutsideFile" >$null 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $extLinkedCopy)) { $extHlMade = $true }
  } catch { $extHlMade = $false }
  if ($extHlMade) {
    $dpExt = & $hostExe -NoProfile -Command "& '$probe' -Action dupes -Roots @('$dupeExtScan') -MinSizeBytes 16384" | Out-String | ConvertFrom-Json
    $gExt = $dpExt.duplicate_groups[0]
    Assert ($dpExt.funnel_stats.duplicate_groups_count -eq 1 -and $gExt.external_hardlink_present -eq $true -and $gExt.recommended_keep_path -eq $extLinkedCopy -and $gExt.reclaimable_logical_bytes -eq 24576) "dupes 有外部硬链接时推荐保留外链副本，且单删独立旧副本仍精准可收 24576B"
  } else {
    Assert $true "dupes 外部硬链接用例在非 NTFS 卷跳过（extHlMade=False）"
  }

  # ---- 9. Torture 测试集：特殊字符/通配符陷阱 · 云盘占位符(Offline) · MAX_PATH > 260 ----
  # 9a: 通配符括号 [v1] + $ + 中文路径（probe space/dupes 与 project-doctor -OutDir/-Roots）
  $tortureSpecial = Join-Path $WorkRoot 'torture-[v1] $中文'
  $tsSubA = Join-Path $tortureSpecial 'sub-[a]'
  $tsSubB = Join-Path $tortureSpecial 'sub-[b]'
  [void][IO.Directory]::CreateDirectory($tsSubA)
  [void][IO.Directory]::CreateDirectory($tsSubB)
  $bufTS = New-Object byte[] 20480
  for ($bi = 0; $bi -lt $bufTS.Length; $bi++) { $bufTS[$bi] = [byte](($bi * 11 + 5) % 251) }
  [IO.File]::WriteAllBytes((Join-Path $tsSubA 'sample-[1].bin'), $bufTS)
  [IO.File]::WriteAllBytes((Join-Path $tsSubB 'sample-[2].bin'), $bufTS)

  $sp9a = & $hostExe -NoProfile -Command "& '$probe' -Action space -Roots @('$tortureSpecial') -MinSizeBytes 16384" | Out-String | ConvertFrom-Json
  Assert ($LASTEXITCODE -eq 0 -and @($sp9a.top_dirs).Count -eq 2 -and $sp9a.age_size_matrix.lt_30d.lt_1mb.files -eq 2 -and @($sp9a.top_large_files).Count -eq 2) "Torture-9a: [v1] \$中文 路径下 space 正常统计 2 子目录与 2 件文件(40960B)"

  $dupes9aJson = Join-Path $WorkRoot 'dupes-9a-[v1].json'
  & $hostExe -NoProfile -Command "& '$probe' -Action dupes -Roots @('$tortureSpecial') -MinSizeBytes 16384 -OutFile '$dupes9aJson'" | Out-Null
  $dp9a = Get-Content -LiteralPath $dupes9aJson -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($LASTEXITCODE -eq 0 -and $dp9a.funnel_stats.duplicate_groups_count -eq 1 -and $dp9a.duplicate_groups[0].reclaimable_logical_bytes -eq 20480) "Torture-9a: [v1] 路径下 dupes 准确检出 1 组重复并写出 [v1] 报告"

  $docScript = Join-Path $repoRoot 'scripts\project-doctor.ps1'
  $docOut9a = Join-Path $tortureSpecial 'doc-out-[v1]'
  & $hostExe -NoProfile -Command "& '$docScript' -Roots @('$tortureSpecial') -OutDir '$docOut9a'" | Out-Null
  $docCsv9a = @(Get-ChildItem -LiteralPath $docOut9a -Filter '*.csv' -EA SilentlyContinue)
  $docMd9a = @(Get-ChildItem -LiteralPath $docOut9a -Filter '*.md' -EA SilentlyContinue)
  Assert ($LASTEXITCODE -eq 0 -and $docCsv9a.Count -ge 1 -and $docMd9a.Count -ge 1) "Torture-9a: project-doctor 在含 [v1] 的 -Roots 与 -OutDir 下零崩溃输出 CSV 与 MD"

  # 9b: 云盘占位符（FileAttributes.Offline）免触发下载保护（dupes 必须跳过；space 必须标出 is_cloud_placeholder）
  $cloudRoot = Join-Path $WorkRoot 'torture-cloud'
  $cloudA = Join-Path $cloudRoot 'od-a'
  $cloudB = Join-Path $cloudRoot 'od-b'
  [void][IO.Directory]::CreateDirectory($cloudA)
  [void][IO.Directory]::CreateDirectory($cloudB)
  $bufCloud = New-Object byte[] 24576
  for ($bi = 0; $bi -lt $bufCloud.Length; $bi++) { $bufCloud[$bi] = [byte](($bi * 13 + 3) % 251) }
  $cFile1 = Join-Path $cloudA 'cloud-1.bin'
  $cFile2 = Join-Path $cloudB 'cloud-2.bin'
  [IO.File]::WriteAllBytes($cFile1, $bufCloud)
  [IO.File]::WriteAllBytes($cFile2, $bufCloud)
  $offlineFlags = [IO.FileAttributes]::Archive -bor [IO.FileAttributes]::Offline
  [IO.File]::SetAttributes($cFile1, $offlineFlags)
  [IO.File]::SetAttributes($cFile2, $offlineFlags)

  $sp9b = & $hostExe -NoProfile -Command "& '$probe' -Action space -Roots @('$cloudRoot') -MinSizeBytes 16384" | Out-String | ConvertFrom-Json
  $cloudFlagged = @($sp9b.top_large_files | Where-Object { $_.is_cloud_placeholder -eq $true }).Count
  Assert ($LASTEXITCODE -eq 0 -and $cloudFlagged -eq 2) "Torture-9b: space 对 Offline 云盘占位符零水合标出 is_cloud_placeholder=true (2件)"

  $dupes9bJson = Join-Path $WorkRoot 'dupes-9b.json'
  & $hostExe -NoProfile -Command "& '$probe' -Action dupes -Roots @('$cloudRoot') -MinSizeBytes 16384 -OutFile '$dupes9bJson'" | Out-Null
  $dp9b = Get-Content -LiteralPath $dupes9bJson -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($LASTEXITCODE -eq 0 -and $dp9b.funnel_stats.skipped_cloud_placeholders -eq 2 -and $dp9b.funnel_stats.duplicate_groups_count -eq 0) "Torture-9b: dupes 跳过 2 件 Offline 占位符不哈希、不触发下载(duplicate_groups_count=0)"

  # 9c: 超长路径 MAX_PATH > 260（\\?\ 兜底遍历与局部/全量哈希无 PathTooLongException）
  $deepRoot = Join-Path $WorkRoot 'torture-deep'
  $seg = 'segment_padding_1234567890_abcdefghij'
  $deepDir1 = Join-Path $deepRoot "branch-one\$seg\$seg\$seg\$seg\$seg"
  $deepDir2 = Join-Path $deepRoot "branch-two\$seg\$seg\$seg\$seg\$seg"
  [void][IO.Directory]::CreateDirectory("\\?\$deepDir1")
  [void][IO.Directory]::CreateDirectory("\\?\$deepDir2")
  $deepFile1 = "$deepDir1\deep-copy-1.bin"
  $deepFile2 = "$deepDir2\deep-copy-2.bin"
  $bufDeep = New-Object byte[] 20480
  for ($bi = 0; $bi -lt $bufDeep.Length; $bi++) { $bufDeep[$bi] = [byte](($bi * 17 + 7) % 251) }
  [IO.File]::WriteAllBytes("\\?\$deepFile1", $bufDeep)
  [IO.File]::WriteAllBytes("\\?\$deepFile2", $bufDeep)

  $sp9c = & $hostExe -NoProfile -Command "& '$probe' -Action space -Roots @('$deepRoot') -MinSizeBytes 16384" | Out-String | ConvertFrom-Json
  Assert ($LASTEXITCODE -eq 0 -and $deepFile1.Length -gt 260 -and $sp9c.age_size_matrix.lt_30d.lt_1mb.files -eq 2 -and $sp9c.age_size_matrix.lt_30d.lt_1mb.bytes -eq 40960) "Torture-9c: MAX_PATH=$($deepFile1.Length)>260 下 space 正常递归统计 2 件(40960B)"

  $dupes9cJson = Join-Path $WorkRoot 'dupes-9c.json'
  & $hostExe -NoProfile -Command "& '$probe' -Action dupes -Roots @('$deepRoot') -MinSizeBytes 16384 -OutFile '$dupes9cJson'" | Out-Null
  $dp9c = Get-Content -LiteralPath $dupes9cJson -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ($LASTEXITCODE -eq 0 -and $dp9c.funnel_stats.duplicate_groups_count -eq 1 -and $dp9c.duplicate_groups[0].reclaimable_logical_bytes -eq 20480) "Torture-9c: MAX_PATH>260 下 dupes via \\?\ 准确哈希并检出 1 组重复(20480B)"

  # 9d: 缺失 -Roots 必须显式标 failed 并被 baseline-check 拦截（对齐 -TopDirs 契约），且 -OutDir [v1] 创建安全
  $out9d = Join-Path $WorkRoot 'out-9d'
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $probe -Action env -OutDir $out9d | Out-Null
  $bJson9d = Join-Path $out9d "baseline-$stamp.json"
  $missingRoot9d = Join-Path $WorkRoot 'NO_SUCH_ROOT_9D'
  & $hostExe -NoProfile -Command "& '$probe' -Action space -Roots @('$missingRoot9d') -Baseline '$bJson9d'" | Out-Null
  $bj9d = Get-Content -LiteralPath $bJson9d -Raw -Encoding UTF8 | ConvertFrom-Json
  $hasOff9d = @($bj9d.restrictions | Where-Object { $_.kind -eq 'offline' -and $_.scope -eq $missingRoot9d }).Count -ge 1
  Assert ($bj9d.meta.scan_status -eq 'failed' -and @($bj9d.top_dirs).Count -eq 1 -and $bj9d.top_dirs[0].scan_status -eq 'failed' -and $hasOff9d) "Torture-9d: -Roots 缺失路径显式输出 meta/top_dirs scan_status=failed 与 offline 受限记录"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $checker -Path $bJson9d -Quiet | Out-Null
  Assert ($LASTEXITCODE -eq 1) "Torture-9d: 含缺失 -Roots 的基线被 baseline-check.ps1 拒绝（实际 exit=$LASTEXITCODE）"

  $spOut9d = Join-Path $tortureSpecial 'space-out-[v1]'
  & $hostExe -NoProfile -Command "& '$probe' -Action space -Roots @('$tortureSpecial') -MinSizeBytes 16384 -OutDir '$spOut9d'" | Out-Null
  $spJsonFiles9d = @(Get-ChildItem -LiteralPath $spOut9d -Filter 'space-*.json' -EA SilentlyContinue)
  Assert ($LASTEXITCODE -eq 0 -and $spJsonFiles9d.Count -eq 1) "Torture-9d: probe -Action space 在含 [v1] 的 -OutDir 下正常创建并写出 space JSON"

  # 9e: Windows 8.3 短路径（如 RUNNER~1 / LONGNA~1）与长路径混用时 space 对账与 -Resume 命中不失真
  $root83 = Join-Path $WorkRoot 'LongNameFolderFor83Test'
  $sub83 = Join-Path $root83 'SubFolder83'
  [void][IO.Directory]::CreateDirectory($sub83)
  [IO.File]::WriteAllBytes((Join-Path $root83 'r83.bin'), (New-Object byte[] 64))
  [IO.File]::WriteAllBytes((Join-Path $sub83 's83.bin'), (New-Object byte[] 20480))
  $shortRoot83 = $root83
  $shortSub83 = $sub83
  try {
    $fso83 = New-Object -ComObject Scripting.FileSystemObject
    $shortRoot83 = $fso83.GetFolder($root83).ShortPath
    $shortSub83 = $fso83.GetFolder($sub83).ShortPath
  } catch { }
  $stream83 = Join-Path $WorkRoot 'stream-83.jsonl'
  & $hostExe -NoProfile -Command "& '$probe' -Action space -TopDirs @('$shortSub83') -StreamOut '$stream83'" | Out-Null
  $sp83 = & $hostExe -NoProfile -Command "& '$probe' -Action space -Roots @('$shortRoot83') -StreamOut '$stream83' -Resume" | Out-String | ConvertFrom-Json
  Assert ($LASTEXITCODE -eq 0 -and $sp83.resumed_from_stream_count -eq 1 -and @($sp83.volume_reconciliation).Count -eq 1 -and $sp83.volume_reconciliation[0].enumerated_bytes -eq 20544) "Torture-9e: 8.3 短路径 ($shortRoot83) 下 -Resume 命中(1)且子树对账精准(20544B)"

  # ---- 10. 工作区总根卫生、伪空壳、异常名与 $Recycle.Bin 摘要（v1.0.1）----
  $hygSp = Join-Path $WorkRoot 'hyg-space-root'
  [void][IO.Directory]::CreateDirectory((Join-Path $hygSp 'repo-a\.git'))
  [void][IO.Directory]::CreateDirectory((Join-Path $hygSp 'repo-b\.git'))
  $tsHygDir = Join-Path $hygSp '2026-11-19-13-21-31\.workbuddy\memory'
  [void][IO.Directory]::CreateDirectory($tsHygDir)
  [IO.File]::WriteAllText((Join-Path $tsHygDir '2026-11-19.md'), '# session log', (New-Object System.Text.UTF8Encoding($false)))
  $metaShellDir = Join-Path $hygSp 'meta-only\.codex'
  [void][IO.Directory]::CreateDirectory($metaShellDir)
  [IO.File]::WriteAllText((Join-Path $metaShellDir 'state.json'), '{}', (New-Object System.Text.UTF8Encoding($false)))
  [void][IO.Directory]::CreateDirectory("\\?\$hygSp\bad-trail ")
  [IO.File]::WriteAllText((Join-Path $hygSp 'AGENTS.md'), '# anchor', (New-Object System.Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $hygSp 'stray-report.md'), '# stray', (New-Object System.Text.UTF8Encoding($false)))

  $sp10 = & $hostExe -NoProfile -Command "& '$probe' -Action space -Roots @('$hygSp')" | Out-String | ConvertFrom-Json
  Assert ($LASTEXITCODE -eq 0 -and @($sp10.recycle_bin).Count -ge 1 -and $null -ne $sp10.recycle_bin[0].bytes) "space 输出所扫卷的 recycle_bin 积压快照"
  $tsFlag = @($sp10.hygiene_flags | Where-Object { $_.kind -eq 'timestamp-shell' -and $_.path -like '*2026-11-19-13-21-31' }).Count
  $agFlag = @($sp10.hygiene_flags | Where-Object { $_.kind -eq 'agent-pseudo-empty-shell' -and $_.path -like '*meta-only' }).Count
  Assert ($tsFlag -eq 1 -and $agFlag -eq 1) "space 精准捕获含 2KB 元数据的 timestamp-shell 与 agent-pseudo-empty-shell"
  $wdFlag = @($sp10.hygiene_flags | Where-Object { $_.kind -eq 'weird-name' -and $_.path -like '*bad-trail*' }).Count
  Assert ($wdFlag -eq 1) "space 捕获尾随空格畸形目录名 weird-name"
  $pfItem = $sp10.hygiene_flags | Where-Object { $_.kind -eq 'portfolio-loose-files' } | Select-Object -First 1
  Assert ($null -ne $pfItem -and $pfItem.note -match 'stray-report\.md' -and ($pfItem.note -notmatch 'AGENTS\.md')) "space 捕获多项目总根散件 stray-report.md 且放行 AGENTS.md"

  Write-Host ""
  if ($script:pass) { Write-Host "全部通过" -ForegroundColor Green } else { Write-Host "存在失败断言" -ForegroundColor Red }
} finally {
  Remove-Item Env:MA_RULE_TEST_DIR -EA SilentlyContinue
  Remove-Item Env:MA_RULE_BAD_FILE -EA SilentlyContinue
  if ($junctionMade -and $jLink -and (Test-Path -LiteralPath $jLink)) {
    cmd /c rmdir "$jLink" 2>$null
  }
  if ($hygSp) { try { [IO.Directory]::Delete("\\?\$hygSp\bad-trail ", $true) } catch {} }
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force -EA SilentlyContinue
  if (Test-Path -LiteralPath $WorkRoot) {
    try { [IO.Directory]::Delete("\\?\$WorkRoot", $true) } catch {}
  }
  if (Test-Path -LiteralPath $WorkRoot) {
    $script:pass = $false
    Write-Host "FAIL  临时区未清理: $WorkRoot" -ForegroundColor Red
  } else {
    Write-Host "PASS  临时区已清理: $WorkRoot" -ForegroundColor Green
  }
}

if ($script:pass) { exit 0 } else { exit 1 }
