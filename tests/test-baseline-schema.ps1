# tests/test-baseline-schema.ps1 — 基线与 overlay 结构门的回归测试（v0.8 新增）
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-baseline-schema.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-baseline-schema.ps1 -CheckerPath <路径>
#
# 为什么要有这个测试：baseline-check.ps1 是"结构不许漂"的唯一机械门。
# 它本身若写错（例如把断言写成恒真、或遇到字符串 free_pct 直接抛异常中断），
# 门就形同虚设——和一个从不失败的 CI 一样有害。所以这里逐条构造反例，
# 要求"该 FAIL 的必须 FAIL，且报错定位到具体字段"。
param([string]$CheckerPath, [string]$WorkRoot)
$ErrorActionPreference = "Continue"
$here = $PSScriptRoot
if (-not $CheckerPath) { $CheckerPath = Join-Path (Split-Path $here -Parent) "scripts\baseline-check.ps1" }
if (-not (Test-Path -LiteralPath $CheckerPath)) { Write-Host "FAIL  校验脚本不存在: $CheckerPath" -ForegroundColor Red; exit 1 }
if (-not $WorkRoot) { $WorkRoot = Join-Path $env:TEMP ("ma-baseline-" + [guid]::NewGuid().ToString("N").Substring(0,8)) }
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

$script:pass = $true
function Assert($cond, $msg) {
  if ($cond) { Write-Host "PASS  $msg" -ForegroundColor Green }
  else { $script:pass = $false; Write-Host "FAIL  $msg" -ForegroundColor Red }
}

# 用子进程跑被测脚本：它内部有 exit，直接 & 调用会把本测试进程一起结束。
$hostExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = "pwsh" }

function Invoke-Checker([string]$jsonPath, [string[]]$ExtraArgs = @()) {
  $out = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $CheckerPath -Path $jsonPath @ExtraArgs 2>&1 | Out-String
  return [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
}

function Write-Case([string]$name, [string]$content) {
  $p = Join-Path $WorkRoot "$name.json"
  [IO.File]::WriteAllText($p, $content, (New-Object System.Text.UTF8Encoding($true)))
  return $p
}

try {
  # 结构完整的正例（六节齐 + 带时区时间 + 数值 free_pct + 采样口径 + 归属定性）
  $good = @'
{
  "schema_version": "1.1",
  "meta": { "run_id": "20261116-181200123", "generated_at": "2026-11-16T18:12:00+08:00", "skill_version": "0.8.1", "mode": "full" },
  "environment": {
    "os": { "caption": "Windows 11 Pro", "build": "22631", "locale": "zh-CN" },
    "user": { "name": "u" },
    "privilege": { "admin": true, "language_mode": "FullLanguage", "ps_version": "5.1" },
    "antivirus": []
  },
  "drives": [
    { "id": "C:", "size_bytes": 476000000000, "free_bytes": 80400000000, "free_pct": 16.9, "online": true, "redline": "ok" }
  ],
  "top_dirs": [
    { "path": "C:\\Users", "bytes": 120000000000, "files": 300000, "sampled": false, "owner_note": "用户数据" }
  ],
  "persona": { "roles": ["production-code"] },
  "domains": { "packs": ["dev"] },
  "restrictions": []
}
'@

  # ---- 1. 正例必须过 ----
  $p = Write-Case "good" $good
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 0) "正例 → 通过（实际 exit=$($r.Exit)）"
  Assert ($r.Out -match "PASS") "正例 → 输出含 PASS"

  # ---- 2. free_pct 写成字符串（最危险：比较会按字符串走，红线永远不出 P1）----
  $p = Write-Case "pct-string" ($good -replace '"free_pct": 16.9', '"free_pct": "16.9%"')
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 1) "free_pct 字符串 → 拒绝（实际 exit=$($r.Exit)）"
  Assert ($r.Out -match "free_pct 为数值") "free_pct 字符串 → 报错定位到 free_pct"

  # ---- 3. owner_note 留空（归属未定性却当成已定性）----
  $p = Write-Case "note-empty" ($good -replace '"owner_note": "用户数据"', '"owner_note": ""')
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 1) "owner_note 空 → 拒绝（实际 exit=$($r.Exit)）"
  Assert ($r.Out -match "owner_note") "owner_note 空 → 报错定位到 owner_note"

  # ---- 4. 缺节（restrictions 被整个删掉）----
  $p = Write-Case "missing-sec" ($good -replace '"restrictions": \[\]', '"zzz": []')
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 1) "缺 restrictions 节 → 拒绝（实际 exit=$($r.Exit)）"
  Assert ($r.Out -match "存在必填节 restrictions") "缺节 → 报错指出是哪一节"

  # ---- 5. run_id 不是毫秒级（同一天两次采集无法排序）----
  $p = Write-Case "runid" ($good -replace '20261116-181200123', '20261116')
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 1) "run_id 无毫秒 → 拒绝（实际 exit=$($r.Exit)）"
  Assert ($r.Out -match "run_id") "run_id 格式错 → 报错定位"

  # ---- 6. redline 与 free_pct 不一致（20% 却标 critical）----
  $p = Write-Case "redline" ($good -replace '"free_pct": 16.9', '"free_pct": 20.0' -replace '"free_bytes": 80400000000', '"free_bytes": 95200000000' -replace '"redline": "ok"', '"redline": "critical"')
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 1) "redline 与 free_pct 不一致 → 拒绝（实际 exit=$($r.Exit)）"
  Assert ($r.Out -match "redline 与 free_pct 一致") "redline 矛盾 → 报错指出应为 ok"

  # ---- 7. 非管理员却没登记任何受限（等于宣称"受限下一切正常"）----
  $p = Write-Case "nonadmin" ($good -replace '"admin": true', '"admin": false')
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 1) "非管理员 + 无受限登记 → 拒绝（实际 exit=$($r.Exit)）"
  Assert ($r.Out -match "受限必须落地") "非管理员无受限 → 报错说明原因"

  # ---- 8. 文件不存在 ----
  $r = Invoke-Checker (Join-Path $WorkRoot "nope.json")
  Assert ($r.Exit -eq 1) "文件不存在 → 退出码 1（实际 $($r.Exit)）"
  Assert ($r.Out -match "不存在") "文件不存在 → 明确报错"

  # ---- 9. S-2：全量枚举却 files=0 且 bytes>0（替代恒真 files>=0 断言）----
  $p = Write-Case "zero-files-nonzero-bytes" ($good -replace '"bytes": 120000000000, "files": 300000', '"bytes": 1048576, "files": 0')
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 1) "sampled=false 且 files=0, bytes>0 → 拒绝（实际 exit=$($r.Exit)）"
  Assert (($r.Out -match "Users") -and ($r.Out -match "采集可疑")) "files=0 且 bytes>0 → 报错指向目录并提示采集可疑"

  # ---- 10. S-2：scan_status=failed 整份不判 PASS ----
  $p = Write-Case "topdir-scan-failed" ($good -replace '"owner_note": "用户数据"', '"scan_status": "failed", "owner_note": "用户数据"')
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 1) "top_dirs scan_status=failed → 拒绝（实际 exit=$($r.Exit)）"
  Assert ($r.Out -match "采集失败不得判 PASS") "top_dirs scan_status=failed → 明确采集失败不得判 PASS"

  $p = Write-Case "meta-scan-failed" ($good -replace '"mode": "full"', '"mode": "full", "scan_status": "failed"')
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 1) "meta scan_status=failed → 拒绝（实际 exit=$($r.Exit)）"
  Assert ($r.Out -match "采集失败不得判 PASS") "meta scan_status=failed → 明确采集失败不得判 PASS"

  # ---- 11. S-2：scan_status=partial 但 sampled=false ----
  $p = Write-Case "partial-not-sampled" ($good -replace '"sampled": false', '"sampled": false, "scan_status": "partial"')
  $r = Invoke-Checker $p
  Assert ($r.Exit -eq 1) "scan_status=partial 且 sampled=false → 拒绝（实际 exit=$($r.Exit)）"
  Assert ($r.Out -match "必须 sampled=true") "scan_status=partial 且 sampled=false → 报错要求 sampled=true"

  # ---- 12. S-2：自定义阈值 -CritPct 20 对 free_pct=18 生效 ----
  $p = Write-Case "custom-crit-pct" ($good -replace '"free_pct": 16\.9', '"free_pct": 18.0' -replace '"free_bytes": 80400000000', '"free_bytes": 85680000000')
  $r = Invoke-Checker $p @("-CritPct", "20")
  Assert ($r.Exit -eq 1) "-CritPct 20 且 free_pct=18, redline=ok → 拒绝（实际 exit=$($r.Exit)）"
  Assert (($r.Out -match "redline 与 free_pct 一致") -and ($r.Out -match "应为 critical")) "-CritPct 20 → 报错指出应为 critical"

  Write-Host ""
  if ($script:pass) { Write-Host "全部通过" -ForegroundColor Green } else { Write-Host "存在失败断言" -ForegroundColor Red }
} finally {
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force -EA SilentlyContinue
  if (Test-Path -LiteralPath $WorkRoot) {
    $script:pass = $false
    Write-Host "FAIL  临时区未清理: $WorkRoot" -ForegroundColor Red
  } else {
    Write-Host "PASS  临时区已清理: $WorkRoot" -ForegroundColor Green
  }
}

if ($script:pass) { exit 0 } else { exit 1 }
