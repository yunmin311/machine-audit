<#
.SYNOPSIS
  baseline-check.ps1 - 基线文件的机械校验（PS 5.1 可用）
.DESCRIPTION
  校验 baseline-YYYYMMDD.json 是否满足 assets/baseline.schema.json 的结构约定。

  为什么不用 Test-Json：它是 PowerShell 6.1+ 才有，本技能最低公分母是 5.1。
  也不需要引第三方 JSON Schema 库——schema 里真正会出错的只有十几处，
  逐条写成断言比引依赖更可靠，且能在失败时给出"哪一节哪个字段"的具体位置。

  为什么必须机械校验：基线一旦结构漂了，下一轮的 diff 会静默算错（例如
  free_pct 被写成字符串 "16.9%"，比较时按字符串走，红线判定永远不出 P1）。
  这类错误肉眼看不出来——必须让脚本说 PASS/FAIL。

  退出码：0 = 全部通过；1 = 有断言失败。
  用法:
    .\baseline-check.ps1 -Path "<归档路径>\baseline-20261116.json"
    .\baseline-check.ps1 -Path .\baseline.json -WarnPct 15 -CritPct 10   # 从 overlay thresholds 传入
    .\baseline-check.ps1 -Path .\baseline.json -Quiet      # 只输出汇总行
#>
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [double]$WarnPct = 15,   # 从 overlay thresholds.disk_free_pct_p1 传入（默认 15）
  [double]$CritPct = 10,   # 从 overlay thresholds.disk_free_pct_p0 传入（默认 10）
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Path)) {
  Write-Host "FAIL  基线文件不存在: $Path" -ForegroundColor Red
  exit 1
}

try {
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $b = $raw | ConvertFrom-Json
} catch {
  Write-Host "FAIL  JSON 解析失败: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

$script:pass = 0
$script:fail = 0
$script:fails = @()

function Assert-That {
  param([bool]$Cond, [string]$Msg)
  if ($Cond) {
    $script:pass++
    if (-not $Quiet) { Write-Host "  ok    $Msg" -ForegroundColor DarkGray }
  } else {
    $script:fail++
    $script:fails += $Msg
    Write-Host "  FAIL  $Msg" -ForegroundColor Red
  }
}

function Has-Prop {
  param($Obj, [string]$Name)
  return ($null -ne $Obj) -and ($null -ne $Obj.PSObject.Properties[$Name])
}

# ConvertFrom-Json 会把 ISO 时间字符串自动转成 [datetime]，偏移量就看不到了。
# 因此 generated_at 的写法校验必须回到原始文本做，不能读解析后的对象。
function Test-Numeric {
  param($v)
  return ($v -is [int]) -or ($v -is [long]) -or ($v -is [double]) -or ($v -is [decimal]) -or ($v -is [single])
}

if (-not $Quiet) { Write-Host "基线校验: $Path`n" -ForegroundColor Cyan }

# ---- 顶层 ----
if (-not $Quiet) { Write-Host "[顶层]" }
foreach ($k in @("schema_version","meta","environment","drives","top_dirs","persona","domains","restrictions")) {
  Assert-That (Has-Prop $b $k) "存在必填节 $k"
}
Assert-That ("$($b.schema_version)" -match '^[0-9]+\.[0-9]+$') "schema_version 形如 1.x（实际: $($b.schema_version)）"
Assert-That ($b.schema_version -match '^1\.') "schema_version 主版本为 1（主版本变化需升技能版本）"

# ---- meta ----
if (-not $Quiet) { Write-Host "[meta]" }
Assert-That (Has-Prop $b.meta "run_id") "meta.run_id 存在"
Assert-That ("$($b.meta.run_id)" -match '^[0-9]{8}-[0-9]{6}[0-9]{3}$') "meta.run_id 为毫秒级运行 ID（实际: $($b.meta.run_id)）"
Assert-That (Has-Prop $b.meta "generated_at") "meta.generated_at 存在"
$genRaw = $null
if ($raw -match '"generated_at"\s*:\s*"([^"]+)"') { $genRaw = $Matches[1] }
Assert-That (-not [string]::IsNullOrWhiteSpace($genRaw)) "meta.generated_at 在 JSON 里是字符串（不是裸数字/日期对象）"
$tsOk = $false
if ($genRaw) {
  try { [void][datetimeoffset]::Parse($genRaw, [Globalization.CultureInfo]::InvariantCulture); $tsOk = $true } catch { $tsOk = $false }
}
Assert-That $tsOk "meta.generated_at 可解析为带时区时间（实际: $genRaw）"
Assert-That ($genRaw -match '(Z|[+-][0-9]{2}:[0-9]{2})$') "meta.generated_at 带时区偏移（禁止只写日期）"
Assert-That ((Has-Prop $b.meta "mode") -and ("$($b.meta.mode)" -in @("bootstrap","quick","full","maintain"))) "meta.mode 合法（实际: $($b.meta.mode)）"
Assert-That (Has-Prop $b.meta "skill_version") "meta.skill_version 存在"
if (Has-Prop $b.meta "scan_status") {
  $ms = "$($b.meta.scan_status)"
  Assert-That ($ms -in @("ok","partial","failed")) "meta.scan_status 合法（实际: $ms）"
  Assert-That ($ms -ne "failed") "meta.scan_status 不为 failed（采集失败不得判 PASS）"
  if ($ms -eq "partial") {
    $anySampled = (@($b.top_dirs | Where-Object { $_.sampled -eq $true }).Count -gt 0)
    Assert-That $anySampled "meta.scan_status=partial 时 top_dirs 须至少一项 sampled=true"
  }
}

# ---- environment ----
if (-not $Quiet) { Write-Host "[environment]" }
$envr = $b.environment
Assert-That (Has-Prop $envr "os") "environment.os 存在"
Assert-That ((Has-Prop $envr.os "caption") -and (Has-Prop $envr.os "build") -and (Has-Prop $envr.os "locale")) "environment.os 三字段齐（caption/build/locale）"
Assert-That (Has-Prop $envr "user") "environment.user 存在"
Assert-That (Has-Prop $envr.user "name") "environment.user.name 存在"
Assert-That (Has-Prop $envr "privilege") "environment.privilege 存在"
Assert-That ((Has-Prop $envr.privilege "admin") -and ($envr.privilege.admin -is [bool])) "environment.privilege.admin 为布尔（不是字符串）"
Assert-That ((Has-Prop $envr.privilege "language_mode") -and ("$($envr.privilege.language_mode)" -in @("FullLanguage","ConstrainedLanguage","RestrictedLanguage","Unknown"))) "environment.privilege.language_mode 合法（实际: $($envr.privilege.language_mode)）"
Assert-That (Has-Prop $envr "antivirus") "environment.antivirus 存在（无杀软则为空数组）"
if ($envr.privilege.admin -eq $false) {
  Assert-That ((@($b.restrictions).Count -gt 0) -or (-not [string]::IsNullOrWhiteSpace("$($b.meta.scope_note)"))) "非管理员运行时，restrictions 非空或 meta.scope_note 已声明（受限必须落地，不许默认一切正常）"
}

# ---- drives ----
if (-not $Quiet) { Write-Host "[drives]" }
Assert-That ($b.drives -is [array]) "drives 为数组"
Assert-That (@($b.drives).Count -gt 0) "drives 至少一条"
$di = 0
foreach ($d in @($b.drives)) {
  $di++
  $tag = "drives[$di] $(if ($d.id) { $d.id } else { '(无盘符)' })"
  Assert-That ("$($d.id)" -match '^[A-Za-z]:$') "$tag · id 形如 C:（实际: $($d.id)）"
  Assert-That ($d.size_bytes -is [long] -or $d.size_bytes -is [int]) "$tag · size_bytes 为整数"
  Assert-That ($d.free_bytes -is [long] -or $d.free_bytes -is [int]) "$tag · free_bytes 为整数"
  Assert-That (Test-Numeric $d.free_pct) "$tag · free_pct 为数值（不是 '16.9%' 这种字符串；实际: $($d.free_pct)）"
  if (Test-Numeric $d.free_pct) {
    Assert-That (($d.free_pct -ge 0) -and ($d.free_pct -le 100)) "$tag · free_pct 在 0-100（实际: $($d.free_pct)）"
  } else {
    Assert-That $false "$tag · free_pct 非数值，范围无法判定"
  }
  Assert-That ($d.online -is [bool]) "$tag · online 为布尔"
  # 关键一致性：free_pct 必须与 free_bytes/size_bytes 对得上（容差 1 个百分点，容忍四舍五入）
  if (($d.size_bytes -gt 0) -and (Test-Numeric $d.free_pct)) {
    $calc = [math]::Round(($d.free_bytes / $d.size_bytes) * 100, 1)
    $diff = [math]::Abs($calc - [double]$d.free_pct)
    Assert-That ($diff -le 1.0) "$tag · free_pct 与 free/size 自洽（算得 $calc，记录 $($d.free_pct)）"
  }
  if (Has-Prop $d "redline") {
    Assert-That ("$($d.redline)" -in @("ok","warn","critical")) "$tag · redline 合法（实际: $($d.redline)）"
  }
  # 红线与阈值的一致性（默认 15/10；自定义阈值时从 overlay thresholds 传入 -WarnPct / -CritPct）
  if ($d.online -and (Test-Numeric $d.free_pct) -and (Has-Prop $d "redline")) {
    $expect = if ($d.free_pct -lt $CritPct) { "critical" } elseif ($d.free_pct -lt $WarnPct) { "warn" } else { "ok" }
    Assert-That ("$($d.redline)" -eq $expect) "$tag · redline 与 free_pct 一致（$($d.free_pct)%，阈值 warn<$WarnPct% / crit<$CritPct% → 应为 $expect）"
  }
}

# ---- top_dirs ----
if (-not $Quiet) { Write-Host "[top_dirs]" }
Assert-That ($b.top_dirs -is [array]) "top_dirs 为数组"
$ti = 0
foreach ($t in @($b.top_dirs)) {
  $ti++
  $tag = "top_dirs[$ti] $(if ($t.path) { Split-Path $t.path -Leaf } else { '(无路径)' })"
  Assert-That (-not [string]::IsNullOrWhiteSpace("$($t.path)")) "$tag · path 非空"
  Assert-That ($t.bytes -is [long] -or $t.bytes -is [int]) "$tag · bytes 为整数"
  Assert-That ($t.files -is [long] -or $t.files -is [int]) "$tag · files 为整数"
  Assert-That ($t.sampled -is [bool]) "$tag · sampled 为布尔（采样口径必须显式）"
  Assert-That (-not [string]::IsNullOrWhiteSpace("$($t.owner_note)")) "$tag · owner_note 已填（未知写'待用户定性'，不许留空）"
  if ($t.sampled -eq $false) {
    Assert-That (-not ($t.files -eq 0 -and $t.bytes -gt 0)) "$tag · 全量枚举却 files=0 但 bytes=$($t.bytes)>0，采集可疑"
  }
  if (Has-Prop $t "scan_status") {
    $ts = "$($t.scan_status)"
    Assert-That ($ts -in @("ok","partial","failed")) "$tag · scan_status 合法（实际: $ts）"
    Assert-That ($ts -ne "failed") "$tag · scan_status 不为 failed（采集失败不得判 PASS）"
    if ($ts -eq "partial") {
      Assert-That ($t.sampled -eq $true) "$tag · scan_status=partial 时必须 sampled=true"
    }
  }
}

# ---- persona ----
if (-not $Quiet) { Write-Host "[persona]" }
Assert-That (Has-Prop $b.persona "roles") "persona.roles 存在"
$allowedRoles = @(
  "production-code","production-doc","production-media","production-ml","production-design","production-notes",
  "consume-game","consume-stream","consume-read","consume-download",
  "host-db","host-service","host-sync-hub","host-remote-access",
  "connect-multidevice","connect-vpn","connect-lan-share","connect-remote-work",
  "govern-personal","govern-family","govern-org","govern-pending-verify","govern-pending-migrate"
)
foreach ($r in @($b.persona.roles)) {
  Assert-That ("$r" -in $allowedRoles) "persona.roles 内合法原语: $r"
}

# ---- domains ----
if (-not $Quiet) { Write-Host "[domains]" }
Assert-That (Has-Prop $b.domains "packs") "domains.packs 存在（空数组合法）"
Assert-That ($b.domains.packs -is [array]) "domains.packs 为数组"

# ---- restrictions ----
if (-not $Quiet) { Write-Host "[restrictions]" }
Assert-That ($b.restrictions -is [array]) "restrictions 为数组（无受限项时为空数组，不是 null）"
$ri = 0
foreach ($r in @($b.restrictions)) {
  $ri++
  Assert-That ("$($r.kind)" -in @("permission","policy","antivirus","offline","clm","long-path","encoding","unknown")) "restrictions[$ri] · kind 合法（实际: $($r.kind)）"
  Assert-That (-not [string]::IsNullOrWhiteSpace("$($r.scope)")) "restrictions[$ri] · scope 非空（写清哪些盘/目录/操作）"
  Assert-That (-not [string]::IsNullOrWhiteSpace("$($r.note)")) "restrictions[$ri] · note 非空（写清具体表现）"
}

# ---- snapshots（可选）----
if (Has-Prop $b "snapshots") {
  if (-not $Quiet) { Write-Host "[snapshots]" }
  if (Has-Prop $b.snapshots "doctor") {
    Assert-That (Has-Prop $b.snapshots.doctor "run_id") "snapshots.doctor.run_id 存在"
    Assert-That (Has-Prop $b.snapshots.doctor "repos") "snapshots.doctor.repos 存在（供 -Baseline 做趋势比较）"
  }
}

# ---- network（可选，schema 1.2 / stage-16 §8 链路基线）----
if (Has-Prop $b "network") {
  if (-not $Quiet) { Write-Host "[network]" }
  $net = $b.network
  $spOk = ($null -ne $net) -and (Has-Prop $net "samples_per_target") -and (($net.samples_per_target -is [int]) -or ($net.samples_per_target -is [long])) -and ($net.samples_per_target -ge 1)
  Assert-That $spOk "network.samples_per_target 为正整数"
  $tgOk = ($null -ne $net) -and (Has-Prop $net "targets") -and ($net.targets -is [array]) -and (@($net.targets).Count -gt 0)
  Assert-That $tgOk "network.targets 为非空数组"
  if ($tgOk) {
    $ni = 0
    foreach ($nt in @($net.targets)) {
      $ni++
      $ntTag = "network.targets[$ni]"
      Assert-That (-not [string]::IsNullOrWhiteSpace("$($nt.target)")) "$ntTag · target 非空"
      $lossOk = (Has-Prop $nt "loss_pct") -and (Test-Numeric $nt.loss_pct) -and ($nt.loss_pct -ge 0) -and ($nt.loss_pct -le 100)
      Assert-That $lossOk "$ntTag · loss_pct 为 0-100 数值"
      $latOk = (Has-Prop $nt "latency_p50_ms") -and (($null -eq $nt.latency_p50_ms) -or ((Test-Numeric $nt.latency_p50_ms) -and ($nt.latency_p50_ms -ge 0)))
      Assert-That $latOk "$ntTag · latency_p50_ms 为非负数值或 null"
      $dnsOk = (Has-Prop $nt "dns_ms") -and (($null -eq $nt.dns_ms) -or ((Test-Numeric $nt.dns_ms) -and ($nt.dns_ms -ge 0)))
      Assert-That $dnsOk "$ntTag · dns_ms 为非负数值或 null"
    }
  }
}

# ---- 汇总 ----
$total = $script:pass + $script:fail
Write-Host ""
if ($script:fail -eq 0) {
  Write-Host "PASS  $total 条断言全部通过" -ForegroundColor Green
  exit 0
} else {
  Write-Host "FAIL  $($script:fail) / $total 条断言失败:" -ForegroundColor Red
  foreach ($f in $script:fails) { Write-Host "  - $f" -ForegroundColor Red }
  exit 1
}
