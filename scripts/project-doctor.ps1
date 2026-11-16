<#
.SYNOPSIS
  project-doctor.ps1 - 只读项目健康巡检 v1.9
.DESCRIPTION
  扫描项目根目录，对每个 git 仓计算健康分（备份40+活跃30+洁净20+文档10），
  对非 git 目录标记为 X。对项目零写入；唯一输出是 -OutDir 下的登记表与巡检报告。

  备份事实链（v1.7 历史修订）：
  - 上游目标按 git 官方定义解析（branch.<name>.remote + merge），远端名支持非 origin。
  - 目标引用整名大小写敏感比较（-ceq）；目标缺失 → D（其他分支存在不能替代）。
  - 独立副本判定收敛为身份解析：所有本地形态（"." "./" ".git" "../name" 绝对路径
    file:///…）统一解析为绝对路径后，与自身 git-common-dir 比较。路径比较按平台语义：
    Windows 不区分大小写、类 Unix 区分大小写。身份未知 → 封顶 C，不得健康。
  - 读取失败（退出码非零）→ D，不当干净。
  - 差异字段分来源：AheadLive/BehindLive = 与核验目标实时 SHA 比对（算不出=未知）；
    CachedAhead/CachedBehind = status 缓存（明确命名）。external-in-sync 的同步分
    不读取缓存（缓存新鲜度不影响等级）。
  - 无上游时不得捏造"未发布 N 个"——只能与核验目标比较后如实标注，比较不了标未知。

  已知限制（如实声明）：全局 SilentlyContinue 丢弃部分 git stderr；ls-remote 用
  Start-Job 15s 进程级超时；多远端只核验上游远端并标注其余；本表只评 git 同步，
  资产备份归阶段 11；符号链接/挂载别名等路径同一性未穷举（按路径语义如实标注未知）。
  基线趋势（v1.9）：-Baseline 传一份完整基线 JSON（assets/baseline.schema.json 约束），
  本脚本只读其中的 snapshots.doctor.repos 做"新出现/已消失/升级/降级"比较；
  基线不存在或没有 doctor 快照时，报告里显式写「无基线，本轮不判趋势」，
  绝不凭印象说变好变坏。-SaveBaseline 只补写 snapshots.doctor 一段，
  不代造六节基线（那是 bootstrap 的职责）。
  用法:
    .\project-doctor.ps1 -Roots "D:\MyProjects","E:\Code" -OutDir ".\reports"   # 指定项目根
    .\project-doctor.ps1                                                        # 无 -Roots 时巡检当前目录
    .\project-doctor.ps1 -Roots "D:\MyProjects" -Baseline ".\baseline-20261116.json"        # 带趋势
    .\project-doctor.ps1 -Roots "D:\MyProjects" -Baseline ".\baseline-20261116.json" `
                         -SaveBaseline ".\baseline-20261123.json"                            # 同时落新快照
#>
param(
  [string[]]$Roots = @(),   # 项目根目录；为空则巡检当前目录（可传多个）
  [string]$OutDir = "$PSScriptRoot\reports",
  [string]$Baseline = "",   # 上轮基线 JSON（完整六节）；空 = 不判趋势
  [string]$SaveBaseline = "" # 写回 doctor 快照的基线 JSON（须已存在，只补 snapshots.doctor）
)
$ErrorActionPreference = "SilentlyContinue"
if (-not $Roots -or $Roots.Count -eq 0) { $Roots = @((Get-Location).Path) }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stamp = Get-Date -Format "yyyy-MM-dd"
$runId = Get-Date -Format "yyyyMMdd-HHmmssfff"
$rows = @()

foreach ($root in $Roots) {
  if (-not (Test-Path -LiteralPath $root)) { Write-Warning "根目录不存在: $root"; continue }
  $rootLeaf = Split-Path $root -Leaf
  Get-ChildItem -LiteralPath $root -Directory -Force | ForEach-Object {
    $dir = $_.FullName; $name = $_.Name
    if ($name -like ".*" -or $name -like "_*" -or $name -eq (Split-Path $root -Leaf)) { $kind = "meta" } else { $kind = "project" }

    if (Test-Path (Join-Path $dir ".git")) {
      # ---- 采集（关键 git 调用检查退出码——失败保留为失败，不当干净）----
      $remotes     = @(git -C $dir remote 2>$null | Where-Object { $_ })
      $remoteLine  = git -C $dir remote -v 2>$null | Select-Object -First 1
      $sbLines     = git -C $dir status -sb 2>$null
      $sbOk        = ($LASTEXITCODE -eq 0)
      $sb          = $sbLines | Select-Object -First 1
      $porcLines   = git -C $dir status --porcelain 2>$null
      $porcelainOk = ($LASTEXITCODE -eq 0)
      $changed     = @($porcLines | Where-Object { $_ -and ($_ -notmatch "^!! ") })
      $dirty       = if ($porcelainOk) { $changed.Count } else { -1 }
      $ignLines    = git -C $dir status --ignored --porcelain 2>$null
      $ignOk       = ($LASTEXITCODE -eq 0)
      $ignoredCount = if ($ignOk) { @($ignLines | Where-Object { $_ -match "^!! " }).Count } else { -1 }
      $lastStr     = git -C $dir log -1 --format=%ci 2>$null
      $branch      = git -C $dir branch --show-current 2>$null
      $localHead   = git -C $dir rev-parse HEAD 2>$null
      $readme      = Test-Path (Join-Path $dir "README.md")

      # ---- 隐私检查：逐邮箱判断 + 已跟踪敏感文件 ----
      $emailList = git -C $dir log -100 --format=%ae 2>$null | Sort-Object -Unique
      $emails = $emailList -join "; "
      $sensPat = "(?i)(\.env($|\.|_)|secret|credential|token|api[_-]?key|password|(^|/)\.claude/|(^|/)\.codex/|(^|/)\.workbuddy|(^|/)\.obsidian/|(^|/)\.smart-env|transcript|desktop\.ini|thumbs\.db)"
      $sensHits = [int]((git -C $dir ls-files 2>$null | Where-Object { $_ -match $sensPat } | Measure-Object).Count)
      $personalEmail = [bool]($emailList | Where-Object { $_ -match "gmail\.com|qq\.com|163\.com|126\.com" })

      $ahead = 0; $behind = 0; $gone = $false; $noUp = $false
      if ($sb -match "ahead (\d+)")  { $ahead  = [int]$Matches[1] }
      if ($sb -match "behind (\d+)") { $behind = [int]$Matches[1] }
      if ($sb -match "gone")         { $gone   = $true }
      if ($sb -notmatch "\.\.\.")    { $noUp   = $true }

      # ---- 上游目标解析（v1.7）：git 官方定义 + 本地上游单独定类 ----
      $upRemote = $null; $upMergeRef = $null; $remoteBranch = $null; $isLocalUpstream = $false
      if ($branch) {
        $upRemote   = git -C $dir config --get "branch.$branch.remote" 2>$null
        $upMergeRef = git -C $dir config --get "branch.$branch.merge" 2>$null
      }
      if ($upMergeRef) { $remoteBranch = $upMergeRef -replace "^refs/heads/","" }
      if ($upRemote -eq ".") { $isLocalUpstream = $true }
      if (-not $upRemote -and $remotes.Count -ge 1) { $upRemote = $remotes[0]; if (-not $remoteBranch) { $remoteBranch = $branch } }
      $hasRemote = [bool]$upRemote
      $trackingKnown = [bool]$upMergeRef
      $multiRemote = ($remotes.Count -gt 1)

      # ---- 目标身份解析（v1.7 收敛）：所有本地形态统一解析为绝对路径 → common-dir 身份比对 ----
      # 平台语义：Windows 路径不区分大小写，类 Unix 区分（按 $env:OS 选择比较方式）。
      # 身份未知（解析失败/网络远端之外的异常）→ 标 unknown，封顶 C，不得健康。
      $selfCommon = git -C $dir rev-parse --path-format=absolute --git-common-dir 2>$null
      $selfCommon = if ($selfCommon) { ($selfCommon -replace "/","\").TrimEnd("\") } else { $null }
      $identityState = "unknown"    # unknown / external-url / self / independent-local
      $targetPath = $null
      if ($hasRemote -and -not $isLocalUpstream) {
        $rawUrl = git -C $dir remote get-url "$upRemote" 2>$null
        $rawUrl = "$rawUrl".Trim()
        if ($rawUrl -eq "." -or $rawUrl -eq "./") {
          $identityState = "self"; $targetPath = $dir
        } elseif ($rawUrl -match "^[a-z][a-z0-9+.-]+://") {
          if ($rawUrl -match "^file://") {
            # URI 语义：file:///tmp/x → /tmp/x（保留根斜杠）；file:///C:/x → C:/（剥盘符前的斜杠）
            if ($rawUrl -match "^file://(localhost)?/(.+)$") { $cand = "/" + $Matches[2] } else { $cand = $rawUrl -replace "^file://(localhost)?","" }
            if ($cand -match "^/[A-Za-z]:") { $cand = $cand.Substring(1) }
            $identityState = "local-path"; $targetPath = $cand
          } else {
            $identityState = "external-url"   # 网络 URL：身份在远端，本地不可判定
          }
        } else {
          $identityState = "local-path"; $targetPath = $rawUrl
        }
        if ($identityState -eq "local-path") {
          if ([IO.Path]::IsPathRooted($targetPath)) { $candAbs = $targetPath }
          else { $candAbs = Join-Path $dir $targetPath }
          $candAbs = [regex]::Replace($candAbs, "[\\/]+", "\")
          $rp = Resolve-Path -LiteralPath $candAbs -EA SilentlyContinue
          if ($rp) { $targetPath = $rp.Path } else { $identityState = "target-unresolvable" }
        }
      }

      # ---- 独立副本判定：目标 common-dir 与自身比较（按平台大小写语义）----
      $isSelfTarget = $false; $identityConfirmed = $false
      if ($identityState -eq "self") { $isSelfTarget = $true; $identityConfirmed = $true }
      elseif ($identityState -eq "local-path" -and $targetPath) {
        $tc = git -C $targetPath rev-parse --path-format=absolute --git-common-dir 2>$null
        if ($tc) {
          $tcN = ($tc -replace "/","\").TrimEnd("\")
          $same = if ($env:OS -eq "Windows_NT") { $tcN -ieq $selfCommon } else { $tcN -ceq $selfCommon }
          if ($same) { $isSelfTarget = $true; $identityConfirmed = $true }
          else { $identityConfirmed = $true; $identityState = "independent-local" }
        } else { $identityState = "identity-unknown" }
      }

      # ---- 远端内容核验（仅对外部目标；self/本地上游不做外部核验）----
      $remoteReachable = $false; $remoteBranchCount = -1; $targetRefExists = $false; $remoteSha = $null; $remoteTimedOut = $false
      if ($hasRemote -and -not $isSelfTarget -and -not $isLocalUpstream) {
        $rn = $upRemote
        $job = Start-Job -ScriptBlock { param($d, $r)
            git -C $d ls-remote --heads --exit-code $r 2>$null
            "GITEXIT:$LASTEXITCODE"
        } -ArgumentList $dir, $rn
        if (Wait-Job $job -Timeout 15) {
          $lsOut = @(Receive-Job $job); Remove-Job $job
          $ec = -1
          foreach ($l in $lsOut) { if ($l -match "^GITEXIT:(-?\d+)$") { $ec = [int]$Matches[1] } }
          $refs = @($lsOut | Where-Object { $_ -match "\trefs/heads/" })
          if ($ec -eq 0) {
            $remoteReachable = $true; $remoteBranchCount = $refs.Count
            foreach ($rf in $refs) {
              $refParts = $rf -split "\t"
              if ($refParts.Count -ge 2 -and $refParts[1] -ceq "refs/heads/$remoteBranch") { $targetRefExists = $true; $remoteSha = $refParts[0] }
            }
          } elseif ($ec -eq 2) { $remoteReachable = $true; $remoteBranchCount = 0 }
        } else { Stop-Job $job; Remove-Job $job -Force; $remoteTimedOut = $true }
      }

      $last = $null
      if ($lastStr -match "^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})") { $last = [datetime]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
      $days = if ($last) { [int]((Get-Date) - $last).TotalDays } else { 9999 }

      # ---- 备份事实链（v1.7）：结构化类别 → 硬封顶分级。目标未知/本地上游不得健康 ----
      $gitFailed = (-not $porcelainOk) -or (-not $sbOk) -or (-not $localHead)
      $remoteCategory = "none"
      if ($gitFailed)                   { $remoteCategory = "git-failed" }
      elseif ($isLocalUpstream)         { $remoteCategory = "local-upstream-dot" }
      elseif ($isSelfTarget)            { $remoteCategory = "self" }
      elseif (-not $hasRemote)          { $remoteCategory = "none" }
      elseif ($identityState -eq "target-unresolvable") { $remoteCategory = "external-unverified-unreachable" }
      elseif ($identityState -eq "identity-unknown")    { $remoteCategory = "identity-unknown" }
      # v1.8：网络远端不再短路——与本地独立目标共用同一条内容核验链
      elseif (-not $remoteReachable)    { $remoteCategory = "external-unverified-unreachable" }
      elseif ($remoteTimedOut)          { $remoteCategory = "external-unverified-timeout" }
      elseif ($remoteBranchCount -eq 0) { $remoteCategory = "external-no-branches" }
      elseif (-not $targetRefExists)    { $remoteCategory = "external-target-missing" }
      elseif ($remoteSha -and $localHead -and ($remoteSha -ceq $localHead)) { $remoteCategory = "external-in-sync" }
      elseif ($remoteSha)               { $remoteCategory = "external-diverged" }

      # ---- 实时差异（独立字段，来源明确）----
      $liveAhead = "未知"; $liveBehind = "未知"
      if ($remoteCategory -eq "external-in-sync") { $liveAhead = 0; $liveBehind = 0 }
      elseif ($remoteCategory -eq "external-diverged" -and $remoteSha -and $localHead) {
        $lr = git -C $dir rev-list --left-right --count "HEAD...$remoteSha" 2>$null
        if ($LASTEXITCODE -eq 0 -and $lr) { $parts = $lr.Trim() -split "\s+"; $liveAhead = [int]$parts[0]; $liveBehind = [int]$parts[1] }
      }

      # ---- 分值与硬封顶分级（按类别映射）----
      $sB = 0; $sA = if ($days -le 30) { 30 } elseif ($days -le 90) { 20 } elseif ($days -le 180) { 10 } else { 0 }
      $sC = 0
      if ($porcelainOk) {
        if (-not $gone) { $sC += 10 }
        if ($dirty -eq 0) { $sC += 10 } elseif ($dirty -le 10) { $sC += 5 }
      }
      $sD = if ($readme) { 10 } else { 0 }

      switch ($remoteCategory) {
        "git-failed"                      { $sB = 0 }
        "none"                            { $sB = 0 }
        "local-upstream-dot"              { $sB = 0 }
        "self"                            { $sB = 0 }
        "identity-unknown"                { $sB = 10 }
        "external-unverified-unreachable" { $sB = 10 }
        "external-unverified-timeout"     { $sB = 10 }
        "external-no-branches"            { $sB = 5 }
        "external-target-missing"         { $sB = 5 }
        "external-diverged"               { $sB = 10 }
        "external-in-sync"                { $sB = 20; if ($liveAhead -eq 0) { $sB += 10 } }
      }
      $score = $sB + $sA + $sC + $sD
      $grade = if ($score -ge 85) { "A健康" } elseif ($score -ge 70) { "B良好" } elseif ($score -ge 50) { "C关注" } else { "D风险" }
      # 类别硬封顶（不得被活跃/文档抵消）：目标未知/缺失/本地上游/self 一律 D；未核验/指向不同封顶 C
      if ($remoteCategory -in @("git-failed","none","local-upstream-dot","self","identity-unknown","external-no-branches","external-target-missing")) { $grade = "D风险" }
      elseif ($remoteCategory -in @("external-unverified-timeout","external-unverified-unreachable","external-diverged") -and ($grade -in "A健康","B良好")) { $grade = "C关注" }
      # noUp 但内容同步：治理缺口（恢复跟踪以恢复自动核验），封顶 C
      if ($remoteCategory -eq "external-in-sync" -and $noUp -and ($grade -in "A健康","B良好")) { $grade = "C关注" }

      # ---- 缺口文案（按类别）----
      $backupGap = switch ($remoteCategory) {
        "git-failed"                      { "git 状态读取失败（不得当作干净）" }
        "none"                            { "无远端" }
        "local-upstream-dot"              { "上游指向本仓库（.）：分支间一致，但无独立同步副本" }
        "self"                            { "上游指向本仓库自身（URL 解析为同一仓库）：无独立同步副本" }
        "identity-unknown"                { "目标身份无法确认（解析失败或状态异常）——按未知处理，不得视为健康" }
        "external-no-branches"            { "远端没有任何分支" }
        "external-target-missing"         { "远端缺少目标分支 refs/heads/$remoteBranch" }
        "external-unverified-timeout"     { "远端未核验（15s 超时，可能离线/慢网）" }
        "external-unverified-unreachable" { "远端未核验（不可达，可能离线）" }
        "external-diverged"               { "与远端指向不同：领先 $liveAhead / 落后 $liveBehind（需 fetch 核对后处理）" }
        "external-in-sync"                { if ($noUp) { "上游未设置（内容与远端一致；恢复跟踪以恢复自动核验）" } else { "" } }
        default                           { "同步状态未知" }
      }

      $remoteState = if ($remoteTimedOut) { "timeout" } elseif (-not $hasRemote -or $isLocalUpstream) { "-" } elseif ($remoteReachable) { "verified($remoteBranchCount heads)" } else { "unreachable" }
      $remoteVerifiedExternal = (($remoteCategory -like "external-*") -and $remoteReachable)

      $rows += [pscustomobject]@{
        Root=$rootLeaf; Name=$name; Kind="git"; Grade=$grade; Score=$score
        Backup=$sB; Active=$sA; Clean=$sC; Doc=$sD
        AheadLive=$liveAhead; BehindLive=$liveBehind
        CachedAhead=$ahead; CachedBehind=$behind
        Gone=$gone; NoUpstream=$noUp
        Dirty=$dirty; IgnoredCount=$ignoredCount; DaysSinceCommit=$days
        Emails=$emails; SensHits=$sensHits; PersonalEmail=$personalEmail
        RemoteCategory=$remoteCategory; IdentityState=$identityState
        TargetRef= if ($remoteBranch) { "refs/heads/$remoteBranch" } else { "-" }
        InSync= if ($remoteCategory -eq "external-in-sync") { $true } else { $false }
        RemoteVerified=$remoteVerifiedExternal; BackupGap=$backupGap; RemoteState=$remoteState
        Remote = if ($upRemote) {
            $rUrl = git -C $dir remote get-url "$upRemote" 2>$null
            $rUrl = "$rUrl" -replace "(?i)(://)[^/@]+@", '$1[redacted]@'
            $othersList = @($remotes | Where-Object { $_ -ne $upRemote })
            $others = if ($othersList.Count -gt 0) { "（未核验远端: $($othersList -join ','))" } else { "" }
            "$upRemote → $rUrl$others"
          } else { "-" }
        LastCommit = if ($last) { $last.ToString("yyyy-MM-dd") } else { "-" }
      }
    } else {
      $files = [int]((Get-ChildItem -LiteralPath $dir -Recurse -File -Force -EA SilentlyContinue | Measure-Object).Count)
      $rows += [pscustomobject]@{
        Root=$rootLeaf; Name=$name; Kind=$kind; Grade="X非git"; Score=0
        Backup=0; Active=0; Clean=0; Doc=0
        AheadLive=""; BehindLive=""; CachedAhead=""; CachedBehind=""
        Gone=""; NoUpstream=""
        Dirty=$files; IgnoredCount=""; DaysSinceCommit=""
        Emails=""; SensHits=""; PersonalEmail=$false
        RemoteCategory="-"; TargetRef="-"; InSync=""; RemoteVerified=""; BackupGap="-"; RemoteState="-"
        Remote="-"; LastCommit="-"
      }
    }
  }
}

# ---- 分流（必须早于趋势比较：趋势要拿本轮结果去对基线）----
$gitRows  = $rows | Where-Object Kind -eq "git"  | Sort-Object Score -Descending
$otherRows= $rows | Where-Object Kind -ne "git"

# ---- 基线趋势（v1.9）----
# 只在 -Baseline 指向的文件可读且含 snapshots.doctor.repos 时才比较；
# 其余情况一律降级为"无基线/无快照"，报告里显式声明，不猜趋势。
$gradeRank = @{ "A健康" = 4; "B良好" = 3; "C关注" = 2; "D风险" = 1 }
$trendState = "not-requested"
$trendWhy   = "未提供 -Baseline"
$priorRun   = ""
$priorRepos = @{}
if ($Baseline) {
  if (-not (Test-Path -LiteralPath $Baseline)) {
    $trendState = "missing"; $trendWhy = "基线文件不存在: $Baseline"
  } else {
    try {
      $bj = Get-Content -LiteralPath $Baseline -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      if ($bj.snapshots -and $bj.snapshots.doctor -and $bj.snapshots.doctor.repos) {
        $priorRun = "$($bj.snapshots.doctor.run_id)"
        foreach ($p in $bj.snapshots.doctor.repos.PSObject.Properties) { $priorRepos[$p.Name] = $p.Value }
        $trendState = "ok"
      } else {
        $trendState = "no-snapshot"; $trendWhy = "基线可读，但没有 snapshots.doctor（上轮未跑本脚本或用了旧格式）"
      }
    } catch {
      $trendState = "bad-json"; $trendWhy = "基线 JSON 解析失败: $($_.Exception.Message)"
    }
  }
}

$trendRows = @()
if ($trendState -eq "ok") {
  $curNames = @{}
  foreach ($r in $gitRows) {
    $curNames[$r.Name] = $true
    $prev = $priorRepos[$r.Name]
    if ($null -eq $prev) {
      $trendRows += [pscustomobject]@{ Name=$r.Name; Prev="-"; Cur=$r.Grade; Delta="新出现"; GradeDelta=0; ScoreDelta=$null }
    } else {
      $pr = $gradeRank["$($prev.grade)"]; $cr = $gradeRank["$($r.Grade)"]
      $gd = if ($pr -and $cr) { $cr - $pr } else { 0 }
      $sd = if ($null -ne $prev.score) { [int]$r.Score - [int]$prev.score } else { $null }
      $verdict = if ($gd -gt 0) { "改善" } elseif ($gd -lt 0) { "恶化" } else { "持平" }
      $trendRows += [pscustomobject]@{ Name=$r.Name; Prev=$prev.grade; Cur=$r.Grade; Delta=$verdict; GradeDelta=$gd; ScoreDelta=$sd }
    }
  }
  foreach ($k in $priorRepos.Keys) {
    if (-not $curNames.ContainsKey($k)) {
      $trendRows += [pscustomobject]@{ Name=$k; Prev="$($priorRepos[$k].grade)"; Cur="-"; Delta="已消失(需核实：改名/移走/删除)"; GradeDelta=0; ScoreDelta=$null }
    }
  }
}

# ---- 输出 ----
$md = @()
$md += "# 项目登记表 · $stamp · 运行 $runId"
$md += ""
$md += "- 扫描根: $($Roots -join ', ')"
$md += "- git 仓: $(($gitRows|Measure-Object).Count) ｜ 非 git: $(($otherRows|Measure-Object).Count)"
$md += "- 分级: A健康 $(($gitRows|? Grade -eq 'A健康'|Measure-Object).Count) / B良好 $(($gitRows|? Grade -eq 'B良好'|Measure-Object).Count) / C关注 $(($gitRows|? Grade -eq 'C关注'|Measure-Object).Count) / D风险 $(($gitRows|? Grade -eq 'D风险'|Measure-Object).Count) / X非git $(($otherRows|Measure-Object).Count)"
$md += "- **范围声明**：本表只覆盖 git 仓库的同步状态（上游目标存在性/分支/指向/独立副本身份已按 v1.7 核验），不等于资产备份状态——被 gitignore 忽略的文件（各仓'忽略项'列，git 不覆盖其备份）、非 git 目录、嵌套仓库与 LFS 大文件不在本表覆盖（见 SOP 阶段 11 的 3-2-1 评估）。"
$md += ""
$md += "## 与上轮基线 diff"
$md += ""
if ($trendState -eq "ok") {
  $up   = @($trendRows | Where-Object Delta -eq "改善").Count
  $down = @($trendRows | Where-Object Delta -eq "恶化").Count
  $flat = @($trendRows | Where-Object Delta -eq "持平").Count
  $new  = @($trendRows | Where-Object { $_.Delta -like "新出现*" }).Count
  $gone = @($trendRows | Where-Object { $_.Delta -like "已消失*" }).Count
  $md += "- 基线: ``$Baseline`` ｜ 上轮运行: $priorRun ｜ 本轮运行: $runId"
  $md += "- 新出现 $new ｜ 已消失 $gone ｜ 改善 $up ｜ 恶化 $down ｜ 持平 $flat"
  $md += ""
  if ($trendRows.Count -gt 0) {
    $md += "| 仓 | 上轮 | 本轮 | 判定 | 分变化 |"
    $md += "|---|---|---|---|---|"
    foreach ($t in ($trendRows | Sort-Object @{Expression={$_.GradeDelta}}, @{Expression={$_.Name}})) {
      $sdTxt = if ($null -eq $t.ScoreDelta) { "-" } elseif ($t.ScoreDelta -gt 0) { "+$($t.ScoreDelta)" } else { "$($t.ScoreDelta)" }
      $md += "| {0} | {1} | {2} | {3} | {4} |" -f $t.Name, $t.Prev, $t.Cur, $t.Delta, $sdTxt
    }
    $md += ""
  } else {
    $md += "（两轮仓库集合一致且等级无变化）"
    $md += ""
  }
  $md += "> 「已消失」只说明本轮没扫到——可能改名、移走或真删除，**不得直接记为已清理**；须重测原路径后才可关闭问题。"
} else {
  $md += "- **无基线，本轮不判趋势。**"
  $md += "- 原因: $trendWhy"
  $md += "- 处置: 首轮属正常（先建档）；非首轮需查基线是否随报告一起归档、路径是否写错。"
  $md += "- 本节只判趋势，**不影响本轮的分级结论**——当前风险照样按事实判级。"
}
$md += ""
$md += "## Git 仓库（按健康分降序）"
$md += ""
$md += "| 级 | 分 | 项目 | 区 | 备/活/净/文 | 领先(实时) | 落后(实时) | 脏 | 忽略 | 天 | 最后提交 | 目标引用 | 备份缺口 | 核验远端 |"
$md += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
foreach ($r in $gitRows) {
  $md += "| {0} | {1} | {2} | {3} | {4}/{5}/{6}/{7} | {8} | {9} | {10} | {11} | {12} | {13} | {14} | {15} | {16} |" -f `
    $r.Grade, $r.Score, $r.Name, $r.Root, $r.Backup, $r.Active, $r.Clean, $r.Doc, `
    $r.AheadLive, $r.BehindLive, $r.Dirty, $r.IgnoredCount, $r.DaysSinceCommit, $r.LastCommit, $r.TargetRef, $r.BackupGap, $r.Remote
}
$md += ""
$md += "## 非 git 目录（X 级，需逐个决策：git 化 / 归档 / 标注外部）"
$md += ""
$md += "| 区 | 目录 | 类型 | 文件数 |"
$md += "|---|---|---|---|"
foreach ($r in ($otherRows | Sort-Object {$_.Root}, Name)) {
  $md += "| {0} | {1} | {2} | {3} |" -f $r.Root, $r.Name, $r.Kind, $r.Dirty
}
$md += ""
$md += "## 隐私检查（逐邮箱判断）"
$md += ""
$md += "规则：任一提交邮箱为个人邮箱服务商即标记（混合 noreply 不压掉告警）；敏感模式命中 = 已跟踪文件需复核。"
$md += ""
$md += "| 仓 | 个人邮箱? | 提交邮箱(近100,去重) | 敏感命中 |"
$md += "|---|---|---|---|"
foreach ($r in ($gitRows | Where-Object { $_.PersonalEmail -or $_.SensHits -gt 0 })) {
  $md += "| {0} | {1} | {2} | {3} |" -f $r.Name, $(if ($r.PersonalEmail) { "⚠ 是" } else { "-" }), $r.Emails, $r.SensHits
}
$md += ""
$md += "## 需要处理的项（自动摘要，含缺口原因）"
$md += ""
foreach ($r in ($gitRows | Where-Object { $_.Grade -in "C关注","D风险" })) {
  $why = @()
  if ($r.BackupGap -and $r.BackupGap -ne "-") { $why += $r.BackupGap }
  if ($r.BehindLive -match "^\d+$" -and [int]$r.BehindLive -gt 0) { $why += "落后 $($r.BehindLive)" }
  if ($r.Dirty -gt 10) { $why += "未提交 $($r.Dirty)" }
  if ($r.DaysSinceCommit -gt 180) { $why += " $($r.DaysSinceCommit) 天未动" }
  $md += "- **{0}/{1}** [{2}] {3}" -f $r.Root, $r.Name, $r.Grade, ($why -join "；")
}
$md += ""
$mdFile = Join-Path $OutDir "项目登记表-$stamp-$runId.md"
$md | Out-File -FilePath $mdFile -Encoding UTF8
$rows | Export-Csv -Path (Join-Path $OutDir "registry-$stamp-$runId.csv") -NoTypeInformation -Encoding UTF8

$gapCount = ($gitRows | Where-Object { $_.BackupGap -and $_.BackupGap -ne "-" } | Measure-Object).Count

# ---- 写回基线快照（只补 snapshots.doctor，不代造六节）----
if ($SaveBaseline) {
  if (-not (Test-Path -LiteralPath $SaveBaseline)) {
    Write-Warning "未写基线：$SaveBaseline 不存在。完整基线（六节）由 Bootstrap 生成，本脚本只补 snapshots.doctor 一段——请先用 bootstrap 建档，或把 -SaveBaseline 指向已有基线文件。"
  } else {
    try {
      $sbj = Get-Content -LiteralPath $SaveBaseline -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      $repoMap = [ordered]@{}
      foreach ($r in $gitRows) {
        $repoMap[$r.Name] = [pscustomobject]@{ grade = "$($r.Grade)"; score = [int]$r.Score; backup_gap = "$($r.BackupGap)" }
      }
      $docNode = [pscustomobject]@{
        run_id       = $runId
        generated_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
        roots        = ($Roots -join ", ")
        repos        = [pscustomobject]$repoMap
      }
      if (-not $sbj.PSObject.Properties["snapshots"]) {
        $sbj | Add-Member -NotePropertyName snapshots -NotePropertyValue ([pscustomobject]@{}) -Force
      }
      $sbj.snapshots | Add-Member -NotePropertyName doctor -NotePropertyValue $docNode -Force
      $sbj | ConvertTo-Json -Depth 12 | Out-File -LiteralPath $SaveBaseline -Encoding UTF8
      Write-Host "基线快照已写入: $SaveBaseline （snapshots.doctor.repos = $($gitRows.Count) 项）"
      Write-Warning "写回后请跑 scripts/baseline-check.ps1 复核，别假设写对了。"
    } catch {
      Write-Warning "写基线失败（未改动原文件）: $($_.Exception.Message)"
    }
  }
}

Write-Host "完成: $mdFile"
Write-Host ("git 仓 {0} | A {1} / B {2} / C {3} / D {4} | 非git {5} | 备份缺口 {6}" -f `
  ($gitRows|Measure-Object).Count,
  ($gitRows|? Grade -eq 'A健康'|Measure-Object).Count, ($gitRows|? Grade -eq 'B良好'|Measure-Object).Count,
  ($gitRows|? Grade -eq 'C关注'|Measure-Object).Count, ($gitRows|? Grade -eq 'D风险'|Measure-Object).Count,
  ($otherRows|Measure-Object).Count, $gapCount)

if ($trendState -eq "ok") {
  $u = @($trendRows | Where-Object Delta -eq "改善").Count
  $d = @($trendRows | Where-Object Delta -eq "恶化").Count
  $n = @($trendRows | Where-Object { $_.Delta -like "新出现*" }).Count
  $g = @($trendRows | Where-Object { $_.Delta -like "已消失*" }).Count
  Write-Host ("基线趋势（对 {0}）: 改善 {1} / 恶化 {2} / 新出现 {3} / 已消失 {4}" -f `
    $(if ($priorRun) { $priorRun } else { "上轮" }), $u, $d, $n, $g)
} else {
  Write-Host "基线趋势: 无基线，本轮不判趋势（$trendWhy）"
}
