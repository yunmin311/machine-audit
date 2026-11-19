# tests/test-backup-scoring.ps1 — 备份评分反例回归测试 v3（覆盖断链/回退/目标偏移/自指/大小写边界反例）
# 用法（默认路径=仓库根 tests\..\scripts\project-doctor.ps1）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-backup-scoring.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-backup-scoring.ps1 -DoctorPath <路径>
param([string]$DoctorPath, [string]$WorkRoot)
$ErrorActionPreference = "Continue"   # PS5.1 下 git 的 stderr 警告在 Stop 模式会变成终止错误；断言均为显式判断
$here = $PSScriptRoot
if (-not $DoctorPath) { $DoctorPath = Join-Path (Split-Path $here -Parent) "scripts\project-doctor.ps1" }
if (-not (Test-Path $DoctorPath)) { Write-Host "FAIL  默认脚本路径不存在: $DoctorPath" -ForegroundColor Red; exit 1 }
if (-not $WorkRoot) { $WorkRoot = Join-Path $env:TEMP ("ma-test-" + [guid]::NewGuid().ToString("N").Substring(0,8)) }
$fixtures = Join-Path $WorkRoot "fixtures"
$outDir = Join-Path $WorkRoot "out"
New-Item -ItemType Directory -Path $fixtures, $outDir -Force | Out-Null
$script:pass = $true
function Assert($cond, $msg) { if ($cond) { Write-Host "PASS  $msg" -ForegroundColor Green } else { $script:pass = $false; Write-Host "FAIL  $msg" -ForegroundColor Red } }
function New-CommitRepo($path, $fileTable) {
  New-Item -ItemType Directory -Path $path -Force | Out-Null
  git init -q -b main $path 2>$null
  foreach ($entry in $fileTable.GetEnumerator()) {
    $fp = Join-Path $path $entry.Key
    $dirp = Split-Path $fp -Parent
    if ($dirp -and -not (Test-Path -LiteralPath $dirp)) { New-Item -ItemType Directory -Path $dirp -Force | Out-Null }
    Set-Content -Path $fp -Value $entry.Value -Encoding UTF8
  }
  git -C $path add -A 2>$null
  git -C $path -c user.email=test@example.com -c user.name=t commit -qm "init" 2>$null
}
function FixturePrecondition($path, $expectCommits) {
  # fixture 自检（样例先验证自身事实）
  $c = [int](git -C $path rev-list --count HEAD 2>$null)
  Assert ($c -eq $expectCommits) "fixture 前提: $((Split-Path $path -Leaf)) 提交数 $c = $expectCommits"
}

try {
# ---- 反例A：无远端 + 活跃 + 干净 + README（v0.5 旧版 70/B良好）----
$a = Join-Path $fixtures "fixA"
New-CommitRepo $a @{ "README.md" = "fixture A" }
FixturePrecondition $a 1

# ---- 反例B：远端已删 + 跟踪残留 + README（v0.5 旧版 100/A健康）----
$srcB = Join-Path $fixtures "srcB"
New-CommitRepo $srcB @{ "f.txt" = "x" }
git clone -q $srcB (Join-Path $fixtures "fixB") 2>$null
Set-Content (Join-Path $fixtures "fixB\README.md") "fixture B" -Encoding UTF8
git -C (Join-Path $fixtures "fixB") add -A 2>$null
git -C (Join-Path $fixtures "fixB") -c user.email=test@example.com -c user.name=t commit -qm "readme" 2>$null
Remove-Item -Recurse -Force $srcB

# ---- 反例C：反例B + gitignore 唯一资料（忽略项真验收）----
Copy-Item -Recurse -Force (Join-Path $fixtures "fixB") (Join-Path $fixtures "fixC")
Set-Content (Join-Path $fixtures "fixC\.gitignore") "secret-assets/" -Encoding UTF8
New-Item -ItemType Directory -Path (Join-Path $fixtures "fixC\secret-assets") -Force | Out-Null
Set-Content (Join-Path $fixtures "fixC\secret-assets\sole-copy.dat") "irreplaceable" -Encoding UTF8
git -C (Join-Path $fixtures "fixC") add .gitignore 2>$null
git -C (Join-Path $fixtures "fixC") -c user.email=test@example.com -c user.name=t commit -qm "gitignore" 2>$null

# ---- 反例D：远端 main 回退，本地跟踪未更新（v0.6.0 前旧版 100/A健康）----
$srcD = Join-Path $fixtures "srcD"
New-CommitRepo $srcD @{ "a.txt" = "1"; "b.txt" = "2" }
git -C $srcD -c user.email=test@example.com -c user.name=t commit -q --allow-empty -am "c2" 2>$null
$bareD = Join-Path $fixtures "bareD.git"
git init -q --bare -b main $bareD 2>$null
git -C $srcD push -q $bareD main 2>$null
git clone -q $bareD (Join-Path $fixtures "fixRollback") 2>$null
git -C $srcD push -q --force $bareD "HEAD~1:main" 2>$null

# ---- 反例E：远端可达但没有任何分支（v0.6.0 前旧版 100/A健康）----
$e = Join-Path $fixtures "fixNoBranches"
New-CommitRepo $e @{ "a.txt" = "1" }
$bareE = Join-Path $fixtures "bareE.git"
git init -q --bare $bareE 2>$null
git -C $e remote add origin $bareE 2>$null

# ---- 反例F：无上游 + 本地提交（v0.6.0 前旧版 100/A健康；措辞不得捏造未发布数）----
$f = Join-Path $fixtures "fixNoUp"
New-CommitRepo $f @{ "a.txt" = "1" }
$bareF = Join-Path $fixtures "bareF.git"
git init -q --bare $bareF 2>$null
git -C $f push -q $bareF main 2>$null
git -C $f remote add origin $bareF 2>$null
git -C $f -c user.email=test@example.com -c user.name=t commit -q --allow-empty -m "unpublished" 2>$null
git -C $f -c user.email=test@example.com -c user.name=t commit -q --allow-empty -am "unpublished2" 2>$null

# ---- 反例G：git 索引损坏，状态读取失败（v0.6.0 前当作干净）----
$g = Join-Path $fixtures "fixIndexCorrupt"
New-CommitRepo $g @{ "a.txt" = "1" }
Set-Content -Path (Join-Path $g ".git\index") -Value "corrupted-garbage-index" -Encoding ASCII

# ---- 反例 CX1：目标分支 main 已删，archive 还在（v0.6.1 前 100/A健康）----
$s1 = Join-Path $fixtures "srcCX1"
New-CommitRepo $s1 @{ "a.txt" = "1" }
git -C $s1 branch archive 2>$null
$bare1 = Join-Path $fixtures "bare1.git"
git init -q --bare -b main $bare1 2>$null
git -C $s1 push -q $bare1 main 2>$null
git -C $s1 push -q $bare1 archive 2>$null
git clone -q $bare1 (Join-Path $fixtures "cx1") 2>$null
git -C $bare1 symbolic-ref HEAD refs/heads/archive 2>$null
git -C $s1 push -q --delete $bare1 main 2>$null

# ---- 反例 CX2：main 回退，main-extra 指向本地最新（前缀遮蔽；v0.6.1 前 100/A健康）----
$s2 = Join-Path $fixtures "srcCX2"
New-CommitRepo $s2 @{ "a.txt" = "1" }
git -C $s2 -c user.email=test@example.com -c user.name=t commit -q --allow-empty -am "c2" 2>$null
$bare2 = Join-Path $fixtures "bare2.git"
git init -q --bare -b main $bare2 2>$null
git -C $s2 push -q $bare2 main 2>$null
git -C $s2 push -q $bare2 "main-extra:refs/heads/main-extra" 2>$null
git clone -q $bare2 (Join-Path $fixtures "cx2") 2>$null
git -C $s2 push -q --force $bare2 "HEAD~1:main" 2>$null
git -C $s2 push -q $bare2 "HEAD:refs/heads/main-extra" 2>$null

# ---- 反例 CX3：本地 feature 跟踪远端 main，远端 main 已回退（v0.6.1 前 100/A健康）----
$s3 = Join-Path $fixtures "srcCX3"
New-CommitRepo $s3 @{ "a.txt" = "1" }
git -C $s3 -c user.email=test@example.com -c user.name=t commit -q --allow-empty -am "c2" 2>$null
$bare3 = Join-Path $fixtures "bare3.git"
git init -q --bare -b main $bare3 2>$null
git -C $s3 push -q $bare3 main 2>$null
git clone -q $bare3 (Join-Path $fixtures "cx3") 2>$null
git -C (Join-Path $fixtures "cx3") checkout -q -b feature 2>$null
git -C (Join-Path $fixtures "cx3") branch -u origin/main feature 2>$null
git -C $s3 push -q --force $bare3 "HEAD~1:main" 2>$null

# ---- 反例 H/I：自指 origin（URL 指向本仓库自身）----
$seed5 = Join-Path $fixtures "seed5"
New-CommitRepo $seed5 @{ "a.txt" = "1" }
$hRel = Join-Path $fixtures "selfRel"
git clone -q $seed5 $hRel 2>$null
Set-Content -Path (Join-Path $hRel "new.txt") -Value "self-only" -Encoding UTF8
git -C $hRel add -A 2>$null
git -C $hRel -c user.email=test@example.com -c user.name=t commit -qm "self-only" 2>$null
git -C $hRel remote set-url origin "." 2>$null
git -C $hRel fetch -q origin 2>$null
$seed5b = Join-Path $fixtures "seed5b"
New-CommitRepo $seed5b @{ "b.txt" = "1" }
$hAbs = Join-Path $fixtures "selfAbs"
git clone -q $seed5b $hAbs 2>$null
Set-Content -Path (Join-Path $hAbs "new2.txt") -Value "also-self" -Encoding UTF8
git -C $hAbs add -A 2>$null
git -C $hAbs -c user.email=test@example.com -c user.name=t commit -qm "self-abs" 2>$null
git -C $hAbs remote set-url origin $hAbs 2>$null
git -C $hAbs fetch -q origin 2>$null

# ---- 变体反例：自指 origin 四种地址形态（./ .git ../name file:///）----
New-CommitRepo (Join-Path $fixtures "w6a") @{ "a.txt" = "1" }
$c6a = Join-Path $fixtures "self_dot_slash"
git clone -q (Join-Path $fixtures "w6a") $c6a 2>$null
Set-Content (Join-Path $c6a "new.txt") "x" -Encoding UTF8
git -C $c6a add -A 2>$null
git -C $c6a -c user.email=test@example.com -c user.name=t commit -qm "self-only" 2>$null
git -C $c6a remote set-url origin "./" 2>$null
git -C $c6a fetch -q origin 2>$null
$w6b = Join-Path $fixtures "w6b"
New-CommitRepo $w6b @{ "a.txt" = "1" }
$c6b = Join-Path $fixtures "self_git_dir"
git clone -q $w6b $c6b 2>$null
Set-Content (Join-Path $c6b "new.txt") "x" -Encoding UTF8
git -C $c6b add -A 2>$null
git -C $c6b -c user.email=test@example.com -c user.name=t commit -qm "self-only" 2>$null
git -C $c6b remote set-url origin ".git" 2>$null
git -C $c6b fetch -q origin 2>$null
$w6c = Join-Path $fixtures "w6c"
New-CommitRepo $w6c @{ "a.txt" = "1" }
$c6c = Join-Path $fixtures "self_parent_relative"
git clone -q $w6c $c6c 2>$null
Set-Content (Join-Path $c6c "new.txt") "x" -Encoding UTF8
git -C $c6c add -A 2>$null
git -C $c6c -c user.email=test@example.com -c user.name=t commit -qm "self-only" 2>$null
git -C $c6c remote set-url origin "../self_parent_relative" 2>$null
git -C $c6c fetch -q origin 2>$null
$w6d = Join-Path $fixtures "w6d"
New-CommitRepo $w6d @{ "a.txt" = "1" }
$c6d = Join-Path $fixtures "self_file_url"
git clone -q $w6d $c6d 2>$null
Set-Content (Join-Path $c6d "new.txt") "x" -Encoding UTF8
git -C $c6d add -A 2>$null
git -C $c6d -c user.email=test@example.com -c user.name=t commit -qm "self-only" 2>$null
$u6d = "file:///" + ($c6d -replace "\\","/")
git -C $c6d remote set-url origin $u6d 2>$null
git -C $c6d fetch -q origin 2>$null

# ---- 变体反例：本地上游 .（分支间一致但无独立副本）----
$w6e = Join-Path $fixtures "w6e"
New-CommitRepo $w6e @{ "a.txt" = "1" }
$c6e = Join-Path $fixtures "local_dot_upstream"
git clone -q $w6e $c6e 2>$null
git -C $c6e branch backup 2>$null
git -C $c6e config branch.main.remote . 2>$null
git -C $c6e config branch.main.merge refs/heads/backup 2>$null

# ---- 健康对照：正常同步 + README（防过度封锁：必须保持 A健康）----
$srcH = Join-Path $fixtures "srcH"
New-CommitRepo $srcH @{ "README.md" = "healthy control" }
$bareH = Join-Path $fixtures "bareH.git"
git init -q --bare -b main $bareH 2>$null
git -C $srcH push -q $bareH main 2>$null
git clone -q $bareH (Join-Path $fixtures "fixHealthy") 2>$null   # 克隆=带跟踪的正常同步对照

# ---- 运行 doctor（一次扫全部 fixtures）----
& $DoctorPath -Roots $fixtures -OutDir $outDir | Out-Null
$csvFile = Get-ChildItem $outDir -Filter *.csv | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$csv = Import-Csv $csvFile.FullName
$md = Get-Content (Get-ChildItem $outDir -Filter *.md | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName -Raw -Encoding UTF8
function Row($name) { $csv | Where-Object Name -eq $name }

# ---- 断言：基础反例（无远端/远端失联/忽略资产）----
Assert ((Row "fixA").Grade -eq "D风险") "反例A 无远端 → D风险（实际 $((Row 'fixA').Grade)）"
Assert ((Row "fixB").Grade -ne "A健康") "反例B 远端已删+跟踪残留 → 非 A健康（实际 $((Row 'fixB').Grade)）"
Assert ((Row "fixB").BackupGap -match "未核验") "反例B 缺口=远端未核验（实际 '$((Row 'fixB').BackupGap)'）"
Assert ([int](Row "fixC").IgnoredCount -ge 1) "反例C 忽略项计数 ≥1（实际 $((Row 'fixC').IgnoredCount)）"

# ---- 断言：状态与回退反例 ----
Assert ((Row "fixRollback").Grade -ne "A健康") "反例D 远端回退 → 非 A健康（实际 $((Row 'fixRollback').Grade)）"
Assert ((Row "fixRollback").BackupGap -match "指向不同|领先") "反例D 缺口=指向不一致（实际 '$((Row 'fixRollback').BackupGap)'）"
Assert ((Row "fixNoBranches").Grade -eq "D风险") "反例E 远端无分支 → D风险（实际 $((Row 'fixNoBranches').Grade)）"
Assert ((Row "fixNoUp").BackupGap -match "无上游|指向不同") "反例F 缺口=无上游或指向不同（实际 '$((Row 'fixNoUp').BackupGap)'）"
Assert ((Row "fixNoUp").Grade -ne "A健康") "反例F → 非 A健康（实际 $((Row 'fixNoUp').Grade)）"
Assert ((Row "fixIndexCorrupt").Grade -eq "D风险") "反例G 索引损坏 → D风险（实际 $((Row 'fixIndexCorrupt').Grade)）"
Assert ((Row "fixIndexCorrupt").BackupGap -match "读取失败") "反例G 缺口=读取失败（实际 '$((Row 'fixIndexCorrupt').BackupGap)'）"

# ---- 断言：目标分支解析与前缀遮蔽反例 ----
Assert ((Row "cx1").Grade -eq "D风险") "反例CX1 目标分支已删（archive 存在）→ D风险（实际 $((Row 'cx1').Grade)）"
Assert ((Row "cx1").BackupGap -match "缺少目标分支") "反例CX1 缺口=缺少目标分支（实际 '$((Row 'cx1').BackupGap)'）"
Assert ((Row "cx2").Grade -ne "A健康") "反例CX2 前缀遮蔽（main-extra=本地HEAD）→ 非 A健康（实际 $((Row 'cx2').Grade)）"
Assert ((Row "cx2").BackupGap -match "指向不同|不一致") "反例CX2 缺口=指向不一致（实际 '$((Row 'cx2').BackupGap)'）"
Assert ((Row "cx3").Grade -ne "A健康") "反例CX3 feature 跟踪 main+远端回退 → 非 A健康（实际 $((Row 'cx3').Grade)）"

Assert ((Row "selfRel").Grade -eq "D风险") "反例H 自指 origin(.) → D风险（实际 $((Row 'selfRel').Grade)）"
Assert ((Row "selfAbs").Grade -eq "D风险") "反例I 自指 origin(绝对路径) → D风险（实际 $((Row 'selfAbs').Grade)）"
Assert ((Row "selfRel").BackupGap -match "本仓库") "反例H 缺口=指向本仓库（实际 '$((Row 'selfRel').BackupGap)'）"

# ---- 断言：健康对照（防过度封锁）----
Assert ((Row "fixHealthy").Grade -eq "A健康") "健康对照 → A健康（实际 $((Row 'fixHealthy').Grade)，得分 $((Row 'fixHealthy').Score)）"

# ---- 断言：报告完整性（主表与远端字段）----
Assert ($md -match "## Git 仓库（按健康分降序）") "Markdown 含 Git 主表标题"
$dataRows = ($md -split "`n" | Where-Object { $_ -match "^\| (A健康|B良好|C关注|D风险)" } | Measure-Object).Count
Assert ($dataRows -ge 7) "Markdown 主表数据行 ≥7（实际 $dataRows）"
$remoteVals = @($csv | ForEach-Object { $_.Remote } | Where-Object { $_ -and $_ -ne "-" })
Assert ($remoteVals.Count -ge 7) "CSV 远端列非空值 ≥7（实际 $($remoteVals.Count)）——不得全部为'-'"
Assert ($md -match "目标引用") "Markdown 含目标引用列"
$targetRefCount = @($csv | Where-Object { $_.TargetRef -and $_.TargetRef -ne "-" }).Count
Assert ($targetRefCount -ge 5) "CSV TargetRef 已填充 ≥5（实际 $targetRefCount）"
# 阈值比较自检（0/1/4/5 边界——证明断言形式有效）
Assert ((1 -ge 5) -eq $false) "阈值自检: 1≥5 应为 false"
Assert ((4 -ge 5) -eq $false) "阈值自检: 4≥5 应为 false"
Assert ((5 -ge 5) -eq $true) "阈值自检: 5≥5 应为 true"

# ---- 断言：自指地址变体与本地上游 ----
foreach ($n in @("self_dot_slash","self_git_dir","self_parent_relative","self_file_url")) {
  $r6 = Row $n
  Assert ($r6.Grade -eq "D风险") "自指变体 $n → D风险（实际 $($r6.Grade)）"
  Assert ($r6.BackupGap -match "本仓库") "自指变体 $n 缺口=指向本仓库（实际 '$($r6.BackupGap)'）"
}
$r6e = Row "local_dot_upstream"
Assert ($r6e.Grade -eq "D风险") "本地上游 local_dot_upstream → D风险（实际 $($r6e.Grade)）"
Assert ($r6e.BackupGap -match "本仓库") "本地上游 local_dot_upstream 缺口=本仓库（实际 '$($r6e.BackupGap)'）"

# ---- 缓存不变性（v1.8）：远端已有全部内容、origin/main 缓存陈旧（ahead N），等级不得降；
#      随后 fetch 刷新缓存，等级不变 ----
$ciSrc = Join-Path $fixtures "ci-src"
New-CommitRepo $ciSrc @{ "a.txt" = "1" }
$ciBare = Join-Path $fixtures "ci-bare.git"
git init -q --bare -b main $ciBare 2>$null
git -C $ciSrc push -q $ciBare main 2>$null
$ciWork = Join-Path $fixtures "ci-work"
git clone -q $ciBare $ciWork 2>$null
# 制造 3 个新提交并经裸仓"路径"推送（绕过 origin → origin/main 缓存保持陈旧 ahead=3）
foreach ($i in 1..3) { git -C $ciWork -c user.email=test@example.com -c user.name=t commit -q --allow-empty -m "ci-$i" 2>$null }
git -C $ciWork push -q $ciBare main 2>$null
& $DoctorPath -Roots (Split-Path $ciWork -Parent) -OutDir $outDir | Out-Null
$csvBefore = Get-ChildItem $outDir -Filter *.csv | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$rowBefore = Import-Csv $csvBefore.FullName | Where-Object Name -eq "ci-work"
$gradeBefore = $rowBefore.Grade
Assert ($gradeBefore -in "A健康","B良好") "缓存不变性(前): 陈旧缓存(ahead $($rowBefore.CachedAhead))不得把实时一致的仓库降级到 C/D（实际 $gradeBefore，LiveAhead=$($rowBefore.AheadLive)）"
Assert ($rowBefore.AheadLive -eq "0") "缓存不变性(前): LiveAhead=0（远端确有全部内容）（实际 $($rowBefore.AheadLive)）"
git -C $ciWork fetch -q origin 2>$null
& $DoctorPath -Roots (Split-Path $ciWork -Parent) -OutDir $outDir | Out-Null
$csvAfter = Get-ChildItem $outDir -Filter *.csv | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$rowAfter = Import-Csv $csvAfter.FullName | Where-Object Name -eq "ci-work"
Assert ($rowAfter.Grade -eq $gradeBefore) "缓存不变性(后): fetch 刷新缓存后等级不变（$gradeBefore → $($rowAfter.Grade)）"

# ---- 大小写并用例（packed-refs 构造，NTFS 可行）——保护 -ceq 不被回退 ----
# 远端同时有 refs/heads/Main（旧提交）与 refs/heads/main（=本地 HEAD）；本地跟踪 Main。
# -ceq 正确：目标 Main=旧 → 分歧 C（领先1）；若回退 -eq：main 行遮蔽 → 误判同步 A（本断言失败）。
$ccSrc = Join-Path $fixtures "cc-src"
New-CommitRepo $ccSrc @{ "a.txt" = "1" }
git -C $ccSrc -c user.email=test@example.com -c user.name=t commit -q --allow-empty -am "c2" 2>$null
$shaNew = git -C $ccSrc rev-parse HEAD 2>$null
$shaOld = git -C $ccSrc rev-parse "HEAD~1" 2>$null
$ccBare = Join-Path $fixtures "cc-bare.git"
git init -q --bare $ccBare 2>$null
git -C $ccSrc push -q $ccBare main 2>$null
git -C $ccBare pack-refs --all 2>$null
$prFile = Join-Path $ccBare "packed-refs"
$prText = "# pack-refs with: peeled fully-peeled sorted" + "`n" + $shaOld + "`t" + "refs/heads/Main" + "`n" + $shaNew + "`t" + "refs/heads/main" + "`n"
[IO.File]::WriteAllText($prFile, $prText)
$ccWork = Join-Path $fixtures "cc-case-collision"
git init -q -b main $ccWork 2>$null
git -C $ccWork remote add origin $ccBare 2>$null
git -C $ccWork fetch -q origin "refs/heads/main:refs/remotes/origin/main" 2>$null
git -C $ccWork checkout -q -B main origin/main 2>$null
# NTFS 上 refs/remotes/origin/main 与 origin/Main 折叠为同一文件——上游 Main 不经 remote-tracking，
# 直接写 config（doctor 只读 branch.<n>.merge，不要求本地存在 origin/Main）
git -C $ccWork config branch.main.remote origin 2>$null
git -C $ccWork config branch.main.merge refs/heads/Main 2>$null
& $DoctorPath -Roots (Split-Path $ccWork -Parent) -OutDir $outDir | Out-Null
$csvCC = Get-ChildItem $outDir -Filter *.csv | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$rowCC = Import-Csv $csvCC.FullName | Where-Object Name -eq "cc-case-collision"
Assert ($rowCC.Grade -eq "C关注") "大小写并用例 → C关注·分歧（实际 $($rowCC.Grade)——若为 A 说明 -ceq 被回退）"
Assert ($rowCC.BackupGap -match "领先 1") "大小写并用例 缺口=领先 1（实际 '$($rowCC.BackupGap)'）"

# ---- ReparsePoint 跳过用例：顶层目录与非 git 子目录里的 junction 均不得重复计入 ----
$rpJuncs = @()
$rpRoot = Join-Path $WorkRoot "rp-root"
$rpTarget = Join-Path $WorkRoot "rp-real-src"
$rpNg = Join-Path $rpRoot "ng-with-link"
New-Item -ItemType Directory -Path $rpRoot, $rpTarget, $rpNg -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $rpTarget "r1.txt"), "1")
[IO.File]::WriteAllText((Join-Path $rpTarget "r2.txt"), "2")
[IO.File]::WriteAllText((Join-Path $rpNg "solo.txt"), "0")
$rpTopLink = Join-Path $rpRoot "rp-top-link"
$rpNestedLink = Join-Path $rpNg "nested-link"
$jOk1 = $false; $jOk2 = $false
try {
  cmd /c mklink /J "$rpTopLink" "$rpTarget" >$null 2>$null
  if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $rpTopLink)) { $jOk1 = $true; $rpJuncs += $rpTopLink }
  cmd /c mklink /J "$rpNestedLink" "$rpTarget" >$null 2>$null
  if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $rpNestedLink)) { $jOk2 = $true; $rpJuncs += $rpNestedLink }
} catch { }
if ($jOk1 -and $jOk2) {
  & $DoctorPath -Roots $rpRoot -OutDir $outDir | Out-Null
  $csvRP = Get-ChildItem $outDir -Filter *.csv | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $rowsRP = @(Import-Csv $csvRP.FullName)
  $hitTop = @($rowsRP | Where-Object Name -eq "rp-top-link")
  $rowNg = $rowsRP | Where-Object Name -eq "ng-with-link" | Select-Object -First 1
  Assert ($hitTop.Count -eq 0) "ReparsePoint 跳过: 顶层 junction 目录不被计为项目"
  Assert ($null -ne $rowNg -and [int]$rowNg.Dirty -eq 1) "ReparsePoint 跳过: 非 git 目录内嵌 junction 不被递归双计文件（Dirty=$($rowNg.Dirty)）"
} else {
  Assert $true "ReparsePoint 跳过(顶层) 非 NTFS/受限环境跳过"
  Assert $true "ReparsePoint 跳过(嵌套) 非 NTFS/受限环境跳过"
}

# ---- 总根工作区卫生与同源远端分身检测（v1.0.1）----
$hygBare = Join-Path $WorkRoot "hyg-upstream.git"
$hygRoot = Join-Path $WorkRoot "hyg-root"
New-Item -ItemType Directory -Path $hygBare, $hygRoot -Force | Out-Null
git -C $hygBare init --bare -q 2>$null
$hygSeed = Join-Path $WorkRoot "hyg-seed"
New-CommitRepo $hygSeed @{ "README.md" = "seed" }
git -C $hygSeed remote add origin $hygBare 2>$null
git -C $hygSeed push -u origin main -q 2>$null
git clone -q $hygBare (Join-Path $hygRoot "app") 2>$null
git clone -q $hygBare (Join-Path $hygRoot "app-fresh") 2>$null
$tsMemDir = Join-Path $hygRoot "2026-11-19-13-21-31\.workbuddy\memory"
[void][IO.Directory]::CreateDirectory($tsMemDir)
[IO.File]::WriteAllText((Join-Path $tsMemDir "2026-11-19.md"), "# daily log", (New-Object System.Text.UTF8Encoding($false)))
[void][IO.Directory]::CreateDirectory("\\?\$hygRoot\weird-space ")
[IO.File]::WriteAllText((Join-Path $hygRoot "AGENTS.md"), "# anchor", (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $hygRoot "stray-draft.md"), "# stray", (New-Object System.Text.UTF8Encoding($false)))

& $DoctorPath -Roots $hygRoot -OutDir $outDir | Out-Null
$csvHyg = Import-Csv ((Get-ChildItem $outDir -Filter *.csv | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName)
$mdHyg = Get-Content ((Get-ChildItem $outDir -Filter *.md | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName) -Raw -Encoding UTF8
Assert ($mdHyg -match '## 同源分身与工作区卫生提示' -and $mdHyg -match '同源远端分身' -and $mdHyg -match 'hyg-root/app' -and $mdHyg -match 'hyg-root/app-fresh' -and $mdHyg -match '疑似 app 分身') "doctor 检出同源远端分身与 -fresh 后缀分身"
$rowTs = $csvHyg | Where-Object Name -eq "2026-11-19-13-21-31" | Select-Object -First 1
$rowWeird = $csvHyg | Where-Object { $_.Name -like "weird-space*" } | Select-Object -First 1
Assert ($null -ne $rowTs -and $rowTs.Kind -eq "timestamp-shell" -and $null -ne $rowWeird -and $rowWeird.Kind -eq "weird-name") "doctor 将带 .workbuddy/memory 的时间戳目录标 timestamp-shell，尾随空格标 weird-name"
Assert ($mdHyg -match '多项目容器根一级散件.*stray-draft\.md' -and ($mdHyg -notmatch '多项目容器根一级散件.*AGENTS\.md')) "doctor 捕获总根散件 stray-draft.md 且放行 AGENTS.md"

# 自清理（自身文件政策：fixture/产物不残留）
# v0.8 修正：本条原先在脚本最末行，中途任何异常都到不了——实测在 %TEMP% 留下 5 项残留
# （ma-final-check / ma-final-fixtures / ma-verify-root / 两个 .log）。清理必须进 finally，
# 并且清理本身要被断言，否则"以为清了"和"真清了"分不出来。
} finally {
  foreach ($jl in @($rpJuncs)) {
    if ($jl -and (Test-Path -LiteralPath $jl)) { cmd /c rmdir "$jl" 2>$null }
  }
  if ($hygRoot) { try { [IO.Directory]::Delete("\\?\$hygRoot\weird-space ", $true) } catch {} }
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force -EA SilentlyContinue
  if (Test-Path -LiteralPath $WorkRoot) {
    try { [IO.Directory]::Delete("\\?\$WorkRoot", $true) } catch {}
  }
  if (Test-Path -LiteralPath $WorkRoot) {
    $script:pass = $false
    Write-Host "FAIL  临时区未清理: $WorkRoot（可能被进程占用，需人工确认后删除）" -ForegroundColor Red
  } else {
    Write-Host "PASS  临时区已清理: $WorkRoot" -ForegroundColor Green
  }
}

Write-Host ""
if ($script:pass) { Write-Host "全部通过" -ForegroundColor Green; exit 0 } else { Write-Host "存在失败断言" -ForegroundColor Red; exit 1 }
