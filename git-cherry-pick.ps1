[CmdletBinding()]
param(
    [switch]$ScanOnly,
    [string]$ProjectName = "",
    [switch]$SkipPull
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# 让 PowerShell 以 UTF-8 解码 git 输出，解决提交记录中文乱码问题
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch { }

$ScriptRoot = $PSScriptRoot
$WarehouseFile = Join-Path $ScriptRoot "warehouse.json"
$DemandFile = Join-Path $ScriptRoot "gitCommitText.json"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $result = & git -C $RepoPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    $text = (($result | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        $argumentText = $Arguments -join " "
        throw "Git 命令执行失败（退出码 $exitCode）：git -C `"$RepoPath`" $argumentText`n$text"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = $text
    }
}

function Read-TextFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    # 带 BOM 的 UTF-8
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    # 无 BOM：优先按 UTF-8 严格解码，失败则退回系统默认编码（如 GBK）
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return $utf8.GetString($bytes)
    }
    catch {
        return [System.Text.Encoding]::Default.GetString($bytes)
    }
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "未找到$Description：$Path"
    }

    try {
        return (Read-TextFile -Path $Path | ConvertFrom-Json)
    }
    catch {
        throw "$Description不是有效 JSON：$Path`n$($_.Exception.Message)"
    }
}

function Resolve-ConfiguredPath {
    param([Parameter(Mandatory = $true)][string]$ConfiguredPath)

    $value = $ConfiguredPath.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "配置中存在空路径。"
    }

    if (-not [System.IO.Path]::IsPathRooted($value)) {
        $value = Join-Path $ScriptRoot $value
    }

    return [System.IO.Path]::GetFullPath($value)
}

function Assert-GitRepository {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description不存在或不是目录：$Path"
    }

    $inside = Invoke-Git -RepoPath $Path -Arguments @("rev-parse", "--is-inside-work-tree") -AllowFailure
    if (($inside.ExitCode -ne 0) -or ($inside.Output.Trim() -ne "true")) {
        throw "$Description不是 Git 工作区：$Path"
    }
}

function Get-CurrentBranch {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $branchResult = Invoke-Git -RepoPath $RepoPath -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
    if (($branchResult.ExitCode -ne 0) -or [string]::IsNullOrWhiteSpace($branchResult.Output)) {
        throw "仓库当前处于 detached HEAD 状态，无法确定分支：$RepoPath"
    }

    return $branchResult.Output.Trim()
}

function Assert-CleanWorkTree {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $status = Invoke-Git -RepoPath $RepoPath -Arguments @("status", "--porcelain")
    if (-not [string]::IsNullOrWhiteSpace($status.Output)) {
        throw "合并后项目存在未提交改动。为避免覆盖现有工作，请先提交或暂存这些改动：`n$RepoPath`n$status"
    }
}

function Test-DemandIncludedExactly {
    param(
        [Parameter(Mandatory = $true)][string]$CommitMessage,
        [Parameter(Mandatory = $true)][string]$DemandNo
    )

    # 需求编号必须作为完整标识出现，不能把 REQ-12 错配为 REQ-123 的一部分。
    $escaped = [Regex]::Escape($DemandNo)
    $pattern = "(?<![A-Za-z0-9_-])$escaped(?![A-Za-z0-9_-])"
    return [Regex]::IsMatch($CommitMessage, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-SourceCommits {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Branch
    )

    # --encoding=UTF-8 保证 git 输出 UTF-8；%cI 输出 ISO-8601 提交时间。
    # 记录分隔符 0x1e、字段分隔符 0x1f，避免多行提交说明破坏解析。
    $log = Invoke-Git -RepoPath $RepoPath -Arguments @(
        "--no-pager", "log",
        "--reverse",
        "--encoding=UTF-8",
        "--format=%H%x1f%cI%x1f%B%x1e",
        $Branch
    )

    $commits = New-Object System.Collections.ArrayList
    $entries = $log.Output -split ([string][char]0x1e)
    $order = 0

    foreach ($entry in $entries) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        $parts = $entry -split ([string][char]0x1f), 3
        if ($parts.Count -ne 3) {
            continue
        }

        $commitId = $parts[0].Trim()
        $commitTime = $parts[1].Trim()
        $commitText = $parts[2].Trim()
        if ([string]::IsNullOrWhiteSpace($commitId)) {
            continue
        }

        [void]$commits.Add([PSCustomObject]@{
            CommitId = $commitId
            CommitTime = $commitTime
            CommitText = $commitText
            Order = $order
        })
        $order++
    }

    return @($commits)
}

function Get-SafeFileNamePart {
    param([Parameter(Mandatory = $true)][string]$Value)

    $invalidChars = [Regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars()))
    $safeValue = [Regex]::Replace($Value, "[$invalidChars]", "_").Trim()
    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        throw "无法根据值生成安全文件名：$Value"
    }
    return $safeValue
}

function Test-CommitAlreadyApplied {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$CommitId
    )

    $exists = Invoke-Git -RepoPath $RepoPath -Arguments @("cat-file", "-e", "$CommitId`^{commit}") -AllowFailure
    if ($exists.ExitCode -ne 0) {
        throw "目标仓库中不存在提交对象 $CommitId。请确认从源仓库 fetch 成功。"
    }

    $ancestor = Invoke-Git -RepoPath $RepoPath -Arguments @("merge-base", "--is-ancestor", $CommitId, "HEAD") -AllowFailure
    if ($ancestor.ExitCode -eq 0) {
        return $true
    }

    # git cherry 可识别提交 ID 不同但补丁内容相同的历史 cherry-pick。
    $cherry = Invoke-Git -RepoPath $RepoPath -Arguments @("cherry", "HEAD", $CommitId) -AllowFailure
    if ($cherry.ExitCode -eq 0) {
        foreach ($line in ($cherry.Output -split "`r?`n")) {
            if ($line -match ("^-\s+" + [Regex]::Escape($CommitId) + "(?:\s|$)")) {
                return $true
            }
        }
    }

    return $false
}

function Test-CherryPickInProgress {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $state = Invoke-Git -RepoPath $RepoPath -Arguments @("rev-parse", "--quiet", "--verify", "CHERRY_PICK_HEAD") -AllowFailure
    return ($state.ExitCode -eq 0)
}

function Resolve-CherryPickFailure {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$CommitId
    )

    if (-not (Test-CherryPickInProgress -RepoPath $RepoPath)) {
        throw "提交 $CommitId 合并失败，且 Git 未进入可继续的 cherry-pick 状态。请检查上方错误信息。"
    }

    while ($true) {
        Write-Host "`n提交 $CommitId 发生冲突或产生空提交。" -ForegroundColor Yellow
        Write-Host "请在另一个终端或编辑器中解决冲突，并执行 git add；不要手动执行 git cherry-pick --continue。"
        Write-Host "[C] 已处理，继续  [S] 跳过该提交  [A] 中止本次全部合并  [E] 保留现场并退出"
        $action = (Read-Host "请选择").Trim().ToUpperInvariant()

        switch ($action) {
            "C" {
                # 先检查是否仍有未解决的冲突文件（未执行 git add 的）
                $unmerged = Invoke-Git -RepoPath $RepoPath -Arguments @("diff", "--name-only", "--diff-filter=U") -AllowFailure
                if ($unmerged.ExitCode -eq 0 -and (-not [string]::IsNullOrWhiteSpace($unmerged.Output))) {
                    Write-Host "仍存在未解决的冲突文件，请先在另一个终端处理并执行 git add 后再按 C：`n$($unmerged.Output)" -ForegroundColor Yellow
                    continue
                }

                # -c core.editor=true 避免空提交场景弹出编辑器（如 vim）卡住脚本
                $continueResult = Invoke-Git -RepoPath $RepoPath -Arguments @("-c", "core.editor=true", "cherry-pick", "--continue") -AllowFailure
                if ($continueResult.ExitCode -eq 0) {
                    Write-Host "冲突已解决，提交 $CommitId 合并完成。" -ForegroundColor Green
                    return "Continued"
                }
                Write-Host $continueResult.Output -ForegroundColor Yellow
                Write-Host "提示：若提示为空提交（empty），可考虑选 S 跳过该提交，或手动 git commit --allow-empty 后重试。" -ForegroundColor Yellow
            }
            "S" {
                $skipResult = Invoke-Git -RepoPath $RepoPath -Arguments @("cherry-pick", "--skip") -AllowFailure
                if ($skipResult.ExitCode -ne 0) {
                    Write-Host $skipResult.Output -ForegroundColor Yellow
                    continue
                }
                Write-Host "已跳过提交 $CommitId。" -ForegroundColor Yellow
                return "Skipped"
            }
            "A" {
                $abortResult = Invoke-Git -RepoPath $RepoPath -Arguments @("cherry-pick", "--abort") -AllowFailure
                if ($abortResult.ExitCode -ne 0) {
                    throw "中止 cherry-pick 失败：`n$($abortResult.Output)"
                }
                Write-Host "已中止本轮 cherry-pick，并恢复到合并前状态。" -ForegroundColor Yellow
                return "Aborted"
            }
            "E" {
                Write-Host "脚本已退出，冲突现场被保留。稍后请手动继续或中止 cherry-pick。" -ForegroundColor Yellow
                return "Exited"
            }
            default {
                Write-Host "无效选项，请输入 C、S、A 或 E。" -ForegroundColor Yellow
            }
        }
    }
}

function Select-Project {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Projects,
        [Parameter(Mandatory = $true)][object[]]$ProjectKeys,
        [string]$RequestedName = ""
    )

    # ProjectKeys 保持 warehouse.json 中的书写顺序，避免哈希表随机顺序导致选择错乱
    $keys = @($ProjectKeys)
    if ($keys.Count -eq 0) {
        throw "warehouse.json 中没有配置任何项目。"
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedName)) {
        $match = @($keys | Where-Object { $_ -ieq $RequestedName.Trim() })
        if ($match.Count -eq 0) {
            throw ("未找到项目 {0}。可用项目：{1}" -f $RequestedName, ($keys -join "、"))
        }
        return $match[0]
    }

    while ($true) {
        Write-Host "`n可用项目："
        for ($index = 0; $index -lt $keys.Count; $index++) {
            Write-Host ("[{0}] {1}" -f ($index + 1), $keys[$index])
        }
        Write-Host "[Q] 退出"
        $answer = (Read-Host "请选择要合并的项目序号").Trim()

        if ($answer.ToUpperInvariant() -eq "Q") {
            exit 0
        }

        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and ($number -ge 1) -and ($number -le $keys.Count)) {
            return $keys[$number - 1]
        }

        Write-Host "输入无效，请输入项目序号。" -ForegroundColor Yellow
    }
}

function Select-Demands {
    param([Parameter(Mandatory = $true)][object[]]$DemandResults)

    while ($true) {
        Write-Host "`n可合并需求："
        for ($index = 0; $index -lt $DemandResults.Count; $index++) {
            $item = $DemandResults[$index]
            Write-Host ("[{0}] {1}（{2} 条提交）" -f ($index + 1), $item.DemandNo, $item.Commits.Count)
        }
        Write-Host "[A] 合并全部有提交的需求  [Q] 退出，不合并"
        $answer = (Read-Host "请输入 A，或输入序号（多个序号用逗号分隔）").Trim()

        if ($answer.ToUpperInvariant() -eq "Q") {
            return @()
        }

        if ($answer.ToUpperInvariant() -eq "A") {
            return @($DemandResults | Where-Object { $_.Commits.Count -gt 0 })
        }

        $normalized = $answer.Replace("，", ",")
        $parts = @($normalized -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
        $selectedIndexes = New-Object System.Collections.ArrayList
        $valid = ($parts.Count -gt 0)

        foreach ($part in $parts) {
            $number = 0
            if ((-not [int]::TryParse($part, [ref]$number)) -or ($number -lt 1) -or ($number -gt $DemandResults.Count)) {
                $valid = $false
                break
            }
            if (-not $selectedIndexes.Contains($number - 1)) {
                [void]$selectedIndexes.Add($number - 1)
            }
        }

        if (-not $valid) {
            Write-Host "输入无效，请使用 A、Q 或列表中的序号。" -ForegroundColor Yellow
            continue
        }

        $selected = @($selectedIndexes | ForEach-Object { $DemandResults[$_] })
        $withCommits = @($selected | Where-Object { $_.Commits.Count -gt 0 })
        if ($withCommits.Count -eq 0) {
            Write-Host "所选需求没有匹配的提交，请重新选择。" -ForegroundColor Yellow
            continue
        }

        return $withCommits
    }
}

function Update-TargetBranch {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$BranchName
    )

    $upstream = Invoke-Git -RepoPath $RepoPath -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") -AllowFailure
    if ($upstream.ExitCode -ne 0) {
        Write-Host "目标分支 $BranchName 没有配置上游分支（@{u}），跳过更新。" -ForegroundColor Yellow
        return
    }

    Write-Host "正在将目标分支 $BranchName 更新到最新状态（git pull）..."
    $pull = Invoke-Git -RepoPath $RepoPath -Arguments @("-c", "pull.rebase=false", "pull") -AllowFailure
    if ($pull.ExitCode -ne 0) {
        throw "git pull 失败，目标分支未能更新到最新状态。请手动解决后重新运行：`n$($pull.Output)"
    }
    if (-not [string]::IsNullOrWhiteSpace($pull.Output)) {
        Write-Host $pull.Output
    }
}

try {
    Write-Step "检查运行环境"
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "未找到 git 命令。请先安装 Git for Windows，并确保 git 已加入 PATH。"
    }

    Write-Step "读取配置"
    $warehouse = Read-JsonFile -Path $WarehouseFile -Description "仓库配置文件 warehouse.json"
    $projects = @{}
    $projectKeys = New-Object System.Collections.ArrayList
    foreach ($property in $warehouse.PSObject.Properties) {
        $projects[$property.Name] = $property.Value
        [void]$projectKeys.Add($property.Name)
    }

    Write-Step "选择要合并的项目"
    $selectedKey = Select-Project -Projects $projects -ProjectKeys @($projectKeys) -RequestedName $ProjectName
    Write-Host "已选择项目：$selectedKey" -ForegroundColor Green

    $projectConfig = $projects[$selectedKey]
    $projectProperties = @($projectConfig.PSObject.Properties.Name)
    if (($projectProperties -notcontains "beforeAddress") -or ($projectProperties -notcontains "backAddress")) {
        throw "项目 $selectedKey 必须同时包含 beforeAddress 和 backAddress。"
    }

    $sourcePath = Resolve-ConfiguredPath -ConfiguredPath ([string]$projectConfig.beforeAddress)
    $targetPath = Resolve-ConfiguredPath -ConfiguredPath ([string]$projectConfig.backAddress)
    if (($projectProperties -contains "commitRecordAddress") -and (-not [string]::IsNullOrWhiteSpace([string]$projectConfig.commitRecordAddress))) {
        $recordDirectory = Resolve-ConfiguredPath -ConfiguredPath ([string]$projectConfig.commitRecordAddress)
    }
    else {
        $recordDirectory = Join-Path $ScriptRoot ("gitCommitRecord" + [IO.Path]::DirectorySeparatorChar + $selectedKey)
    }

    # 项目可指定各自的需求编号文件（commitTextSearchAddress）；
    # 同时兼容文档笔误写法 commitTextAddress；未配置时回退根目录默认 gitCommitText.json
    $demandFile = $DemandFile
    if (($projectProperties -contains "commitTextSearchAddress") -and (-not [string]::IsNullOrWhiteSpace([string]$projectConfig.commitTextSearchAddress))) {
        $demandFile = Resolve-ConfiguredPath -ConfiguredPath ([string]$projectConfig.commitTextSearchAddress)
    }
    elseif (($projectProperties -contains "commitTextAddress") -and (-not [string]::IsNullOrWhiteSpace([string]$projectConfig.commitTextAddress))) {
        $demandFile = Resolve-ConfiguredPath -ConfiguredPath ([string]$projectConfig.commitTextAddress)
    }
    Write-Host "需求编号文件：$demandFile"

    Assert-GitRepository -Path $sourcePath -Description "合并前项目"
    Assert-GitRepository -Path $targetPath -Description "合并后项目"

    $sourceBranch = Get-CurrentBranch -RepoPath $sourcePath
    $targetBranch = Get-CurrentBranch -RepoPath $targetPath
    Write-Host "合并前：$sourcePath（分支：$sourceBranch）"
    Write-Host "合并后：$targetPath（分支：$targetBranch）"

    $demandConfig = @(Read-JsonFile -Path $demandFile -Description "需求配置文件（项目 $selectedKey）")
    if ($demandConfig.Count -eq 0) {
        throw "gitCommitText.json 中没有需求编号。"
    }

    $demandNos = New-Object System.Collections.ArrayList
    $seenDemandNos = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $demandConfig) {
        $properties = @($entry.PSObject.Properties.Name)
        if ($properties -notcontains "commitText") {
            throw "gitCommitText.json 中每一项都必须包含 commitText。"
        }
        $demandNo = ([string]$entry.commitText).Trim()
        if ([string]::IsNullOrWhiteSpace($demandNo)) {
            throw "gitCommitText.json 中不能包含空需求编号。"
        }
        if ($seenDemandNos.Add($demandNo)) {
            [void]$demandNos.Add($demandNo)
        }
        else {
            Write-Host "忽略重复需求编号：$demandNo" -ForegroundColor Yellow
        }
    }

    Write-Step "检索源分支提交记录"
    $allCommits = @(Get-SourceCommits -RepoPath $sourcePath -Branch $sourceBranch)
    if (-not (Test-Path -LiteralPath $recordDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $recordDirectory -Force)
    }

    $safeProjectKey = Get-SafeFileNamePart -Value $selectedKey
    $demandResults = New-Object System.Collections.ArrayList

    foreach ($demandNo in $demandNos) {
        $matches = @($allCommits | Where-Object {
            Test-DemandIncludedExactly -CommitMessage $_.CommitText -DemandNo $demandNo
        })

        $record = [ordered]@{
            demandNo = $demandNo
            commitRecordList = @($matches | ForEach-Object {
                [ordered]@{
                    commitText = $_.CommitText
                    commitId = $_.CommitId
                    commitTime = $_.CommitTime
                }
            })
        }

        $safeDemandNo = Get-SafeFileNamePart -Value $demandNo
        $recordPath = Join-Path $recordDirectory ("{0}_{1}.json" -f $safeProjectKey, $safeDemandNo)
        $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $recordPath -Encoding UTF8
        Write-Host ("{0}：找到 {1} 条提交，记录已写入 {2}" -f $demandNo, $matches.Count, $recordPath)

        [void]$demandResults.Add([PSCustomObject]@{
            DemandNo = $demandNo
            Commits = $matches
            RecordPath = $recordPath
        })
    }

    if ($ScanOnly) {
        Write-Host "`n扫描完成。已启用 -ScanOnly，不执行 cherry-pick。" -ForegroundColor Green
        exit 0
    }

    $totalMatched = @($demandResults | ForEach-Object { $_.Commits }).Count
    if ($totalMatched -eq 0) {
        Write-Host "`n所有需求均未检索到符合条件的提交，不执行合并。" -ForegroundColor Yellow
        exit 0
    }

    Write-Step "选择要合并的需求"
    $selectedDemands = @(Select-Demands -DemandResults @($demandResults))
    if ($selectedDemands.Count -eq 0) {
        Write-Host "已取消，本次未执行 cherry-pick。" -ForegroundColor Yellow
        exit 0
    }

    # 同一提交可能同时包含多个需求编号；按源分支原始时间顺序去重。
    $selectedCommitIds = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($selectedDemand in $selectedDemands) {
        foreach ($commit in $selectedDemand.Commits) {
            [void]$selectedCommitIds.Add($commit.CommitId)
        }
    }
    $selectedCommits = @($allCommits | Where-Object { $selectedCommitIds.Contains($_.CommitId) })

    Write-Host "`n即将从 $sourceBranch 合并到 $targetBranch，共 $($selectedCommits.Count) 条提交（按源分支从旧到新）：" -ForegroundColor Cyan
    foreach ($commit in $selectedCommits) {
        $firstLine = ($commit.CommitText -split "`r?`n")[0]
        Write-Host ("  {0}  {1}" -f $commit.CommitId.Substring(0, 12), $firstLine)
    }

    while ($true) {
        $answer = (Read-Host "`n[A] 开始合并  [B] 取消").Trim().ToUpperInvariant()
        if ($answer -eq "A") {
            break
        }
        if ($answer -eq "B") {
            Write-Host "已取消，本次未执行 cherry-pick。" -ForegroundColor Yellow
            exit 0
        }
        Write-Host "无效选项，请输入 A 或 B。" -ForegroundColor Yellow
    }

    Write-Step "执行合并前安全检查"
    if ((Get-CurrentBranch -RepoPath $sourcePath) -ne $sourceBranch) {
        throw "源项目分支已发生变化，请重新运行脚本。"
    }
    if ((Get-CurrentBranch -RepoPath $targetPath) -ne $targetBranch) {
        throw "目标项目分支已发生变化，请重新运行脚本。"
    }
    Assert-CleanWorkTree -RepoPath $targetPath

    if (-not $SkipPull) {
        Write-Step "更新目标分支到最新状态"
        Update-TargetBranch -RepoPath $targetPath -BranchName $targetBranch
    }
    else {
        Write-Host "已通过 -SkipPull 跳过目标分支更新。" -ForegroundColor Yellow
    }

    Write-Host "从本地源仓库抓取提交对象（不会修改源项目，也不会 push）..."
    $fetchResult = Invoke-Git -RepoPath $targetPath -Arguments @("fetch", "--no-tags", $sourcePath, $sourceBranch)
    if (-not [string]::IsNullOrWhiteSpace($fetchResult.Output)) {
        Write-Host $fetchResult.Output
    }

    $mergedCount = 0
    $skippedCount = 0
    foreach ($commit in $selectedCommits) {
        $commitId = $commit.CommitId
        if (Test-CommitAlreadyApplied -RepoPath $targetPath -CommitId $commitId) {
            Write-Host "跳过已合并或补丁等价的提交：$commitId" -ForegroundColor Yellow
            $skippedCount++
            continue
        }

        Write-Host "正在 cherry-pick：$commitId" -ForegroundColor Cyan
        $pickResult = Invoke-Git -RepoPath $targetPath -Arguments @("cherry-pick", $commitId) -AllowFailure
        if ($pickResult.ExitCode -eq 0) {
            Write-Host "合并成功：$commitId" -ForegroundColor Green
            $mergedCount++
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($pickResult.Output)) {
            Write-Host $pickResult.Output -ForegroundColor Yellow
        }
        $resolution = Resolve-CherryPickFailure -RepoPath $targetPath -CommitId $commitId
        if ($resolution -eq "Continued") {
            $mergedCount++
        }
        elseif ($resolution -eq "Skipped") {
            $skippedCount++
        }
        elseif (($resolution -eq "Aborted") -or ($resolution -eq "Exited")) {
            Write-Host "`n合并流程已停止。未执行 git push。" -ForegroundColor Yellow
            exit 2
        }
    }

    Write-Host "`n全部处理完成：成功合并 $mergedCount 条，跳过 $skippedCount 条。" -ForegroundColor Green
    Write-Host "当前目标分支：$targetBranch。脚本未执行 git push，请检查结果后自行推送。"
}
catch {
    Write-Host "`n执行失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
