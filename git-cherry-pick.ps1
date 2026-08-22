[CmdletBinding()]
param(
    [switch]$ScanOnly,
    [string]$ProjectName = "",
    [switch]$SkipPull,
    [string]$WarehouseFile = "",
    [string]$DemandFile = ""
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

# 配置文件路径：默认取脚本根目录，也允许通过 -WarehouseFile / -DemandFile 指定（验证时可用独立文件）
if ([string]::IsNullOrWhiteSpace($WarehouseFile)) {
    $WarehouseFile = Join-Path $ScriptRoot "warehouse.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($WarehouseFile)) {
    $WarehouseFile = Join-Path $ScriptRoot $WarehouseFile
}
$WarehouseFile = [System.IO.Path]::GetFullPath($WarehouseFile)

if ([string]::IsNullOrWhiteSpace($DemandFile)) {
    $DemandFile = Join-Path $ScriptRoot "gitCommitText.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($DemandFile)) {
    $DemandFile = Join-Path $ScriptRoot $DemandFile
}
$DemandFile = [System.IO.Path]::GetFullPath($DemandFile)

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Read-Choice {
    # 安全读取用户输入：管道/重定向场景下 Read-Host 可能返回 Null（EOF）
    param([Parameter(Mandatory = $true)][string]$Prompt)
    $value = Read-Host $Prompt
    if ($null -eq $value) {
        return $null
    }
    return $value.Trim()
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

function Get-UnmergedCommits {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$TargetHead,
        [Parameter(Mandatory = $true)][object[]]$Commits,
        [object]$AppliedCommitIds
    )

    # 批量判断哪些提交尚未合并：
    # 1) 一次 rev-list 得到目标分支全部祖先提交集合（提交 ID 相同即已合并）
    # 2) 一次 git cherry 得到补丁等价的提交集合（提交 ID 不同但内容相同也算已合并）
    $ancestorResult = Invoke-Git -RepoPath $RepoPath -Arguments @("rev-list", $TargetHead) -AllowFailure
    if ($ancestorResult.ExitCode -ne 0) {
        throw "获取目标分支提交历史失败：$($ancestorResult.Output)"
    }
    $ancestors = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in ($ancestorResult.Output -split "`r?`n")) {
        $hash = $line.Trim()
        if ($hash -match "^[0-9a-f]{40}$") {
            [void]$ancestors.Add($hash)
        }
    }

    # 源提交已通过 fetch 抓取到目标仓库（FETCH_HEAD 指向源分支）
    $patchApplied = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    $cherryResult = Invoke-Git -RepoPath $RepoPath -Arguments @("cherry", $TargetHead, "FETCH_HEAD") -AllowFailure
    if ($cherryResult.ExitCode -eq 0) {
        foreach ($line in ($cherryResult.Output -split "`r?`n")) {
            if ($line -match "^-\s+([0-9a-f]{40})") {
                [void]$patchApplied.Add($Matches[1])
            }
        }
    }

    $unmerged = New-Object System.Collections.ArrayList
    foreach ($commit in $Commits) {
        $commitId = $commit.CommitId

        $exists = Invoke-Git -RepoPath $RepoPath -Arguments @("cat-file", "-e", "$commitId`^{commit}") -AllowFailure
        if ($exists.ExitCode -ne 0) {
            throw "目标仓库中不存在提交对象 $commitId。请确认从源仓库 fetch 成功。"
        }

        if ($ancestors.Contains($commitId)) {
            continue
        }
        if ($patchApplied.Contains($commitId)) {
            continue
        }
        # 外部已合清单（按需求编号记录的已合并提交），即使内容被改得与源提交不同也能识别，避免重复合并
        if (($null -ne $AppliedCommitIds) -and $AppliedCommitIds.Contains($commitId)) {
            continue
        }

        [void]$unmerged.Add($commit)
    }

    return @($unmerged)
}

function Get-CherryPickInProgressCommit {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $state = Invoke-Git -RepoPath $RepoPath -Arguments @("rev-parse", "--quiet", "--verify", "CHERRY_PICK_HEAD") -AllowFailure
    if ($state.ExitCode -ne 0) {
        return ""
    }
    return $state.Output.Trim()
}

function Resolve-CherryPickConflict {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$PickOutput
    )

    # 处理进行中的 cherry-pick（冲突 / 空提交）。
    # 循环条件基于 CHERRY_PICK_HEAD 动态状态：外部处理完成后会自动退出，避免死循环。
    while ($true) {
        $currentId = Get-CherryPickInProgressCommit -RepoPath $RepoPath
        if ([string]::IsNullOrWhiteSpace($currentId)) {
            # 说明用户在外部已手动完成或中止了 cherry-pick
            Write-Host "检测到 cherry-pick 已在外部处理完成，脚本继续后续步骤。" -ForegroundColor Yellow
            return [PSCustomObject]@{ Action = "External"; CommitId = "" }
        }
        $shortId = $currentId.Substring(0, [Math]::Min(12, $currentId.Length))

        Write-Host "`n提交 $shortId 发生冲突或产生空提交。" -ForegroundColor Yellow
        Write-Host "请在另一个终端或编辑器中解决冲突，并执行 git add；不要手动执行 git cherry-pick --continue。"
        Write-Host "[C] 已处理，继续  [S] 跳过该提交  [A] 中止本次全部合并  [E] 保留现场并退出"
        $action = Read-Choice -Prompt "请选择"

        if ($null -eq $action) {
            Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
            exit 2
        }
        $action = $action.ToUpperInvariant()

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
                if ($continueResult.ExitCode -ne 0) {
                    Write-Host $continueResult.Output -ForegroundColor Yellow
                    Write-Host "提示：若提示为空提交（empty），可考虑选 S 跳过该提交，或手动 git commit --allow-empty 后重试。" -ForegroundColor Yellow
                    continue
                }

                # --continue 成功：若 sequencer 已全部完成则返回；若又停在下一处冲突则循环继续处理
                if ([string]::IsNullOrWhiteSpace((Get-CherryPickInProgressCommit -RepoPath $RepoPath))) {
                    Write-Host "冲突已解决，提交 $shortId 合并完成。" -ForegroundColor Green
                    return [PSCustomObject]@{ Action = "Continued"; CommitId = $currentId }
                }
            }
            "S" {
                $skipResult = Invoke-Git -RepoPath $RepoPath -Arguments @("cherry-pick", "--skip") -AllowFailure
                if ($skipResult.ExitCode -ne 0) {
                    Write-Host $skipResult.Output -ForegroundColor Yellow
                    # 若 --skip 失败且 cherry-pick 已不在进行中（外部已处理），立即退出循环
                    if ([string]::IsNullOrWhiteSpace((Get-CherryPickInProgressCommit -RepoPath $RepoPath))) {
                        Write-Host "检测到 cherry-pick 已在外部处理完成，脚本继续后续步骤。" -ForegroundColor Yellow
                        return [PSCustomObject]@{ Action = "External"; CommitId = "" }
                    }
                    continue
                }

                Write-Host "已跳过提交 $shortId。" -ForegroundColor Yellow
                # --skip 后 sequencer 自动继续；若全部完成则返回，若又停在冲突处则循环继续处理
                if ([string]::IsNullOrWhiteSpace((Get-CherryPickInProgressCommit -RepoPath $RepoPath))) {
                    return [PSCustomObject]@{ Action = "Skipped"; CommitId = $currentId }
                }
            }
            "A" {
                $abortResult = Invoke-Git -RepoPath $RepoPath -Arguments @("cherry-pick", "--abort") -AllowFailure
                if ($abortResult.ExitCode -ne 0) {
                    throw "中止 cherry-pick 失败：`n$($abortResult.Output)"
                }
                Write-Host "已中止本轮 cherry-pick，并恢复到合并前状态。" -ForegroundColor Yellow
                return [PSCustomObject]@{ Action = "Aborted"; CommitId = "" }
            }
            "E" {
                Write-Host "脚本已退出，冲突现场被保留。稍后请手动继续或中止 cherry-pick。" -ForegroundColor Yellow
                return [PSCustomObject]@{ Action = "Exited"; CommitId = "" }
            }
            default {
                Write-Host "无效选项，请输入 C、S、A 或 E。" -ForegroundColor Yellow
            }
        }
    }
}

function Resolve-NonSequencerFailure {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$PickOutput,
        [Parameter(Mandatory = $true)][string[]]$PendingIds
    )

    # 处理未进入 cherry-pick 状态的失败，例如：merge 提交未指定 -m。
    # 从输出中提取失败提交 id
    $failedId = ""
    if ($PickOutput -match "commit\s+([0-9a-f]{40,})\s+is a merge") {
        $failedId = $Matches[1]
    }

    while ($true) {
        if (-not [string]::IsNullOrWhiteSpace($failedId)) {
            Write-Host "`n提交 $failedId 是合并提交（merge commit），直接 cherry-pick 需要指定 -m 参数。" -ForegroundColor Yellow
            Write-Host "[M] 以 -m 1 合并该提交（取第一个父分支的变更）  [S] 跳过该提交，继续后续  [A] 中止本次全部合并  [E] 保留现场并退出"
        }
        else {
            Write-Host "`n合并失败且未进入可继续的 cherry-pick 状态（可能为其它 Git 错误）。" -ForegroundColor Yellow
            Write-Host "[C] 我已手动处理完成，继续  [S] 跳过该提交  [A] 中止本次全部合并  [E] 保留现场并退出"
        }
        $action = Read-Choice -Prompt "请选择"

        if ($null -eq $action) {
            Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
            exit 2
        }
        $action = $action.ToUpperInvariant()

        if ($action -eq "M" -and (-not [string]::IsNullOrWhiteSpace($failedId))) {
            $retry = Invoke-Git -RepoPath $RepoPath -Arguments @("cherry-pick", "-m", "1", $failedId) -AllowFailure
            if ($retry.ExitCode -eq 0) {
                Write-Host "以 -m 1 合并提交 $failedId 成功。" -ForegroundColor Green
                return [PSCustomObject]@{ Action = "Retried"; CommitId = $failedId }
            }
            Write-Host $retry.Output -ForegroundColor Yellow
            # -m 1 重试可能引发冲突：进入冲突处理
            if (-not [string]::IsNullOrWhiteSpace((Get-CherryPickInProgressCommit -RepoPath $RepoPath))) {
                $conflictResolution = Resolve-CherryPickConflict -RepoPath $RepoPath -PickOutput $retry.Output
                if (($conflictResolution.Action -eq "Aborted") -or ($conflictResolution.Action -eq "Exited")) {
                    return $conflictResolution
                }
                return [PSCustomObject]@{ Action = "Retried"; CommitId = $failedId }
            }
            continue
        }

        if ($action -eq "S") {
            $skipId = $failedId
            if ([string]::IsNullOrWhiteSpace($skipId)) {
                # 未知失败：跳过 pending 中的第一个提交（最可能是失败的那个）
                $skipId = $PendingIds[0]
            }
            Write-Host "已跳过提交 $skipId。" -ForegroundColor Yellow
            return [PSCustomObject]@{ Action = "Skipped"; CommitId = $skipId }
        }

        if ($action -eq "C" -and [string]::IsNullOrWhiteSpace($failedId)) {
            # 用户声明已手动处理完成：由主流程重新批量校验决定下一步
            Write-Host "已确认，继续后续步骤。" -ForegroundColor Yellow
            return [PSCustomObject]@{ Action = "Continued"; CommitId = "" }
        }

        if ($action -eq "A") {
            $abortResult = Invoke-Git -RepoPath $RepoPath -Arguments @("cherry-pick", "--abort") -AllowFailure
            if ($abortResult.ExitCode -eq 0) {
                Write-Host "已中止本轮 cherry-pick，并恢复到合并前状态。" -ForegroundColor Yellow
                return [PSCustomObject]@{ Action = "Aborted"; CommitId = "" }
            }
            Write-Host $abortResult.Output -ForegroundColor Yellow
            continue
        }

        if ($action -eq "E") {
            Write-Host "脚本已退出，请检查目标仓库状态后手动处理。" -ForegroundColor Yellow
            return [PSCustomObject]@{ Action = "Exited"; CommitId = "" }
        }

        Write-Host "无效选项，请重新输入。" -ForegroundColor Yellow
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
        $answer = Read-Choice -Prompt "请选择要合并的项目序号"

        if ($null -eq $answer) {
            Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
            exit 2
        }

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
        $answer = Read-Choice -Prompt "请输入 A，或输入序号（多个序号用逗号分隔）"

        if ($null -eq $answer) {
            Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
            exit 2
        }

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

function Select-AppliedLists {
    param(
        [Parameter(Mandatory = $true)][object[]]$DemandResults,
        [Parameter(Mandatory = $true)]$AppliedMap
    )

    while ($true) {
        Write-Host "`n检测到以下需求存在已合清单（加载后这些提交将被跳过，不再重复合并）："
        for ($index = 0; $index -lt $DemandResults.Count; $index++) {
            $item = $DemandResults[$index]
            $appliedCount = 0
            if ($AppliedMap.ContainsKey($item.DemandNo)) {
                $appliedCount = @($AppliedMap[$item.DemandNo]).Count
            }
            Write-Host ("[{0}] {1}（已记录 {2} 条）" -f ($index + 1), $item.DemandNo, $appliedCount)
        }
        Write-Host "[A] 全部加载  [Q] 不加载（按原有 rev-list + git cherry 判断）"
        $answer = Read-Choice -Prompt "请输入 A，或输入序号（多个序号用逗号分隔）"

        if ($null -eq $answer) {
            Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
            exit 2
        }

        if ($answer.ToUpperInvariant() -eq "Q") {
            return @()
        }

        if ($answer.ToUpperInvariant() -eq "A") {
            return @($DemandResults)
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

        return @($selectedIndexes | ForEach-Object { $DemandResults[$_] })
    }
}

function Save-AppliedList {
    param(
        [Parameter(Mandatory = $true)]$AppliedMap,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $output = New-Object System.Collections.ArrayList
    foreach ($demandNo in ($AppliedMap.Keys | Sort-Object)) {
        $list = $AppliedMap[$demandNo]
        if (($null -eq $list) -or ($list.Count -eq 0)) {
            continue
        }
        [void]$output.Add([ordered]@{
            demandNo = $demandNo
            appliedCommitIds = @($list | ForEach-Object { [ordered]@{ commitText = $_.commitText; commitId = $_.commitId } })
        })
    }
    $output | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Record-NewlyApplied {
    param(
        [Parameter(Mandatory = $true)][object[]]$SelectedCommits,
        # 全部合完时 $UnmergedCommits 可能为空数组，不能设为 Mandatory（PowerShell 会拒绝空数组）
        [object[]]$UnmergedCommits,
        [Parameter(Mandatory = $true)]$UserSkippedIds,
        [Parameter(Mandatory = $true)]$RecordedAppliedIds,
        [Parameter(Mandatory = $true)]$AllAppliedIds,
        [Parameter(Mandatory = $true)]$AppliedMap,
        [Parameter(Mandatory = $true)]$CommitDemandMap,
        [Parameter(Mandatory = $true)][string]$AppliedFilePath
    )

    $unmergedSet = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $UnmergedCommits) {
        [void]$unmergedSet.Add($c.CommitId)
    }

    $newly = New-Object System.Collections.ArrayList
    foreach ($c in $SelectedCommits) {
        $id = $c.CommitId
        if ($unmergedSet.Contains($id)) { continue }
        if ($UserSkippedIds.Contains($id)) { continue }
        if ($RecordedAppliedIds.Contains($id)) { continue }
        [void]$newly.Add($c)
    }

    # 把"被跳过"的提交也持久化进已合清单，避免下次运行因缺少记录而重复尝试同一提交，
    # 陷入"冲突/空提交 -> 跳过 -> 不落盘 -> 再冲突"的死循环。
    # （跳过即代表本次不纳入、后续也不再重试，其语义与"已合并"一致，都应被排除。）
    $skipNewly = New-Object System.Collections.ArrayList
    foreach ($c in $SelectedCommits) {
        $id = $c.CommitId
        if (-not $UserSkippedIds.Contains($id)) { continue }
        if ($RecordedAppliedIds.Contains($id)) { continue }
        [void]$skipNewly.Add($c)
    }

    if (($newly.Count -eq 0) -and ($skipNewly.Count -eq 0)) {
        return 0
    }

    foreach ($c in $newly) {
        [void]$RecordedAppliedIds.Add($c.CommitId)
        [void]$AllAppliedIds.Add($c.CommitId)
        $demands = $CommitDemandMap[$c.CommitId]
        if ($null -eq $demands) { $demands = @() }
        foreach ($dem in $demands) {
            if (-not $AppliedMap.ContainsKey($dem)) {
                $AppliedMap[$dem] = New-Object System.Collections.ArrayList
            }
            $dup = $false
            foreach ($existing in $AppliedMap[$dem]) {
                if ([string]::Equals($existing.commitId, $c.CommitId, [StringComparison]::OrdinalIgnoreCase)) {
                    $dup = $true
                    break
                }
            }
            if (-not $dup) {
                [void]$AppliedMap[$dem].Add([ordered]@{ commitText = $c.CommitText; commitId = $c.CommitId })
            }
        }
    }

    foreach ($c in $skipNewly) {
        [void]$RecordedAppliedIds.Add($c.CommitId)
        [void]$AllAppliedIds.Add($c.CommitId)
        $demands = $CommitDemandMap[$c.CommitId]
        if ($null -eq $demands) { $demands = @() }
        foreach ($dem in $demands) {
            if (-not $AppliedMap.ContainsKey($dem)) {
                $AppliedMap[$dem] = New-Object System.Collections.ArrayList
            }
            $dup = $false
            foreach ($existing in $AppliedMap[$dem]) {
                if ([string]::Equals($existing.commitId, $c.CommitId, [StringComparison]::OrdinalIgnoreCase)) {
                    $dup = $true
                    break
                }
            }
            if (-not $dup) {
                [void]$AppliedMap[$dem].Add([ordered]@{ commitText = $c.CommitText; commitId = $c.CommitId })
            }
        }
    }

    Save-AppliedList -AppliedMap $AppliedMap -Path $AppliedFilePath
    Write-Host ("已记录 {0} 条新合并提交、{1} 条跳过提交到已合清单：$AppliedFilePath" -f $newly.Count, $skipNewly.Count) -ForegroundColor Green
    return ($newly.Count + $skipNewly.Count)
}

function Assert-NoResidualCherryPick {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $head = Get-CherryPickInProgressCommit -RepoPath $RepoPath
    if ([string]::IsNullOrWhiteSpace($head)) {
        return
    }

    $shortId = $head.Substring(0, [Math]::Min(12, $head.Length))
    Write-Host "`n检测到目标仓库存在未完成的 cherry-pick 状态（CHERRY_PICK_HEAD = $shortId）。" -ForegroundColor Yellow
    Write-Host "这会导致工作区不干净，脚本无法正常合并。" -ForegroundColor Yellow
    while ($true) {
        Write-Host "[A] 中止残留 cherry-pick（git cherry-pick --abort）并继续  [C] 我已手动处理完成，重新检测后继续  [E] 退出，我自行处理"
        $answer = Read-Choice -Prompt "请选择"

        if ($null -eq $answer) {
            Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
            exit 2
        }
        $answer = $answer.ToUpperInvariant()

        if ($answer -eq "A") {
            $abort = Invoke-Git -RepoPath $RepoPath -Arguments @("cherry-pick", "--abort") -AllowFailure
            if ($abort.ExitCode -ne 0) {
                Write-Host $abort.Output -ForegroundColor Yellow
                Write-Host "中止失败，请手动处理后再运行脚本。" -ForegroundColor Yellow
                continue
            }
            Write-Host "已中止残留 cherry-pick，目标分支恢复到合并前状态。" -ForegroundColor Green
            return
        }
        if ($answer -eq "C") {
            $recheck = Get-CherryPickInProgressCommit -RepoPath $RepoPath
            if ([string]::IsNullOrWhiteSpace($recheck)) {
                Write-Host "残留状态已清除，继续后续步骤。" -ForegroundColor Green
                return
            }
            Write-Host "CHERRY_PICK_HEAD 仍存在，请先完成或中止 cherry-pick 后再继续。" -ForegroundColor Yellow
            continue
        }
        if ($answer -eq "E") {
            Write-Host "已退出，请自行处理目标仓库的 cherry-pick 状态。" -ForegroundColor Yellow
            exit 0
        }
        Write-Host "无效选项，请输入 A、C 或 E。" -ForegroundColor Yellow
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
        Write-Host "`ngit pull 执行失败，目标分支未能自动更新到最新状态。请手动在另一个终端处理（例如解决冲突、完成拉取或检查网络）。" -ForegroundColor Yellow
        Write-Host "失败信息如下：" -ForegroundColor Yellow
        Write-Host $pull.Output -ForegroundColor Yellow
        while ($true) {
            $answer = Read-Choice -Prompt "[Y] 我已手动处理完成，确认继续  [Q] 退出"

        if ($null -eq $answer) {
            Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
            exit 2
        }
            $answer = $answer.ToUpperInvariant()
            if ($answer -eq "Y") {
                Write-Host "已确认，继续后续合并步骤。" -ForegroundColor Green
                return
            }
            if ($answer -eq "Q") {
                Write-Host "已退出，未执行 cherry-pick。" -ForegroundColor Yellow
                exit 0
            }
            Write-Host "无效选项，请输入 Y 或 Q。" -ForegroundColor Yellow
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($pull.Output)) {
        Write-Host $pull.Output
    }
}

function Invoke-PushAfterMerge {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$BranchName
    )

    # 阶段一：询问合并完成后是否执行 push
    while ($true) {
        Write-Host "`n内容合并已完成，是否执行 git push 推送？"
        Write-Host "[A] 执行 git push 推送（分支：$BranchName）  [B] 结束程序，不推送"
        $answer = Read-Choice -Prompt "请选择"
        if ($null -eq $answer) {
            Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
            exit 2
        }
        $answer = $answer.ToUpperInvariant()
        if ($answer -eq "A") {
            break
        }
        if ($answer -eq "B") {
            Write-Host "`n程序结束，未执行 git push。请检查合并结果后自行推送。" -ForegroundColor Yellow
            exit 0
        }
        Write-Host "无效选项，请输入 A 或 B。" -ForegroundColor Yellow
    }

    # 阶段二：确定推送目标。优先使用已配置的上游分支（@{u}）；未配置时询问是否以第一个远端做首次推送
    $pushArgs = @()
    $upstream = Invoke-Git -RepoPath $RepoPath -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") -AllowFailure
    if ($upstream.ExitCode -eq 0) {
        Write-Host "检测到上游分支：$($upstream.Output.Trim())" -ForegroundColor Cyan
    }
    else {
        Write-Host "目标分支 $BranchName 未配置上游分支（@{u}）。" -ForegroundColor Yellow
        $remotes = Invoke-Git -RepoPath $RepoPath -Arguments @("remote") -AllowFailure
        $remoteNames = @()
        if ($remotes.ExitCode -eq 0) {
            $remoteNames = @($remotes.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
        }
        if ($remoteNames.Count -eq 0) {
            Write-Host "目标仓库未配置任何远程仓库（git remote），无法执行 push。" -ForegroundColor Yellow
            exit 0
        }
        $remoteName = $remoteNames[0]
        while ($true) {
            Write-Host "[U] 以 git push -u $remoteName $BranchName 推送并设置上游  [B] 结束程序，不推送"
            $answer = Read-Choice -Prompt "请选择"
            if ($null -eq $answer) {
                Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
                exit 2
            }
            $answer = $answer.ToUpperInvariant()
            if ($answer -eq "U") {
                $pushArgs = @("-u", $remoteName, $BranchName)
                break
            }
            if ($answer -eq "B") {
                Write-Host "`n程序结束，未执行 git push。请检查合并结果后自行推送。" -ForegroundColor Yellow
                exit 0
            }
            Write-Host "无效选项，请输入 U 或 B。" -ForegroundColor Yellow
        }
    }

    # 阶段三：执行推送，失败可重试
    while ($true) {
        Write-Host "`n正在执行 git push（分支：$BranchName）..."
        $push = Invoke-Git -RepoPath $RepoPath -Arguments (@("push") + $pushArgs) -AllowFailure
        if ($push.ExitCode -eq 0) {
            if (-not [string]::IsNullOrWhiteSpace($push.Output)) {
                Write-Host $push.Output
            }
            Write-Host "`ngit push 成功，分支 $BranchName 已推送至远端。" -ForegroundColor Green
            return
        }
        if (-not [string]::IsNullOrWhiteSpace($push.Output)) {
            Write-Host $push.Output -ForegroundColor Yellow
        }
        Write-Host "`ngit push 执行失败。请检查网络连接、登录凭据或远端状态。" -ForegroundColor Yellow
        Write-Host "若提示非快进（non-fast-forward）失败，请先在另一个终端处理（如 git pull）后再重试。" -ForegroundColor Yellow
        while ($true) {
            Write-Host "[R] 重试 push  [B] 结束程序，不推送"
            $answer = Read-Choice -Prompt "请选择"
            if ($null -eq $answer) {
                Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
                exit 2
            }
            $answer = $answer.ToUpperInvariant()
            if ($answer -eq "R") {
                break
            }
            if ($answer -eq "B") {
                Write-Host "`n程序结束，未执行 git push。请检查合并结果后自行推送。" -ForegroundColor Yellow
                exit 0
            }
            Write-Host "无效选项，请输入 R 或 B。" -ForegroundColor Yellow
        }
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

    # ===== 外部已合清单（按需求编号记录已合并提交，不污染任何提交消息）=====
    $appliedFilePath = Join-Path $recordDirectory ("{0}_applied.json" -f $safeProjectKey)
    $appliedMap = @{}   # demandNo -> ArrayList of @{ commitText, commitId }
    if (Test-Path -LiteralPath $appliedFilePath -PathType Leaf) {
        try {
            $loadedApplied = Read-JsonFile -Path $appliedFilePath -Description "已合清单 $appliedFilePath"
            $entries = @()
            if ($loadedApplied -is [System.Array]) {
                $entries = $loadedApplied
            }
            else {
                $entries = @($loadedApplied)
            }
            foreach ($entry in $entries) {
                $props = @($entry.PSObject.Properties.Name)
                if ($props -notcontains "demandNo") { continue }
                $dn = ([string]$entry.demandNo).Trim()
                if ([string]::IsNullOrWhiteSpace($dn)) { continue }
                $list = New-Object System.Collections.ArrayList
                if ($props -contains "appliedCommitIds") {
                    foreach ($c in $entry.appliedCommitIds) {
                        $cprops = @($c.PSObject.Properties.Name)
                        if (($cprops -contains "commitId") -and (-not [string]::IsNullOrWhiteSpace([string]$c.commitId))) {
                            [void]$list.Add([ordered]@{ commitText = [string]$c.commitText; commitId = [string]$c.commitId })
                        }
                    }
                }
                $appliedMap[$dn] = $list
            }
        }
        catch {
            Write-Host "已合清单读取失败，将忽略：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # 构建 提交ID -> 需求编号 映射（一个提交可能命中多个需求）
    $commitDemandMap = @{}
    foreach ($dr in $demandResults) {
        foreach ($c in $dr.Commits) {
            if (-not $commitDemandMap.ContainsKey($c.CommitId)) {
                $commitDemandMap[$c.CommitId] = New-Object System.Collections.ArrayList
            }
            if (-not $commitDemandMap[$c.CommitId].Contains($dr.DemandNo)) {
                [void]$commitDemandMap[$c.CommitId].Add($dr.DemandNo)
            }
        }
    }

    # 询问是否加载已有的已合清单（仅针对本次选中的、且存在清单的需求）
    $trustedAppliedIds = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    $demandsWithList = @($selectedDemands | Where-Object { $appliedMap.ContainsKey($_.DemandNo) -and $appliedMap[$_.DemandNo].Count -gt 0 })
    if ($demandsWithList.Count -gt 0) {
        $loadedDemands = @(Select-AppliedLists -DemandResults $demandsWithList -AppliedMap $appliedMap)
        foreach ($ld in $loadedDemands) {
            foreach ($c in $appliedMap[$ld.DemandNo]) {
                [void]$trustedAppliedIds.Add($c.commitId)
            }
        }
    }

    # 已合跟踪集合：受信任清单(加载的) + 本次运行过程中新记录的
    $recordedAppliedIds = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    $allAppliedIds = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $trustedAppliedIds) {
        [void]$allAppliedIds.Add($id)
    }

    # 用户策略集合（跳过 / 合并完成的提交），供后续循环与记录使用
    $userSkippedIds = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    $userMergedIds = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)

    Write-Host "`n即将从 $sourceBranch 合并到 $targetBranch，共 $($selectedCommits.Count) 条提交（按源分支从旧到新）：" -ForegroundColor Cyan
    foreach ($commit in $selectedCommits) {
        $firstLine = ($commit.CommitText -split "`r?`n")[0]
        Write-Host ("  {0}  {1}" -f $commit.CommitId.Substring(0, 12), $firstLine)
    }

    while ($true) {
        $answer = Read-Choice -Prompt "`n[A] 开始合并  [B] 取消"

        if ($null -eq $answer) {
            Write-Host "输入已结束，脚本退出。" -ForegroundColor Yellow
            exit 2
        }
        $answer = $answer.ToUpperInvariant()
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
    Assert-NoResidualCherryPick -RepoPath $targetPath
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

    # ===== 批量校验：一次 rev-list + 一次 git cherry，判断所有选中提交哪些已合并 =====
    Write-Host "当前正在校验内容是否已经合并...." -ForegroundColor Cyan
    $targetHead = (Invoke-Git -RepoPath $targetPath -Arguments @("rev-parse", "HEAD")).Output.Trim()
    $unmergedCommits = @(Get-UnmergedCommits -RepoPath $targetPath -TargetHead $targetHead -Commits $selectedCommits -AppliedCommitIds $allAppliedIds)
    $null = Record-NewlyApplied -SelectedCommits $selectedCommits -UnmergedCommits $unmergedCommits -UserSkippedIds $userSkippedIds -RecordedAppliedIds $recordedAppliedIds -AllAppliedIds $allAppliedIds -AppliedMap $appliedMap -CommitDemandMap $commitDemandMap -AppliedFilePath $appliedFilePath
    $autoSkippedCount = $selectedCommits.Count - $unmergedCommits.Count
    if ($autoSkippedCount -gt 0) {
        Write-Host "自动跳过已合并或补丁等价的提交 $autoSkippedCount 条。" -ForegroundColor Yellow
    }
    if ($unmergedCommits.Count -eq 0) {
        Write-Host "`n所有选中提交均已合并过，无需执行 cherry-pick。" -ForegroundColor Green
        Write-Host "当前目标分支：$targetBranch。脚本未执行 git push，请检查结果后自行推送。"
        exit 0
    }

    # 注意：$userSkippedIds / $userMergedIds 已在前面（已合清单初始化处）创建，此处不再重复初始化。
    $stopRequested = $false
    $pending = New-Object System.Collections.ArrayList
    foreach ($commit in $unmergedCommits) {
        [void]$pending.Add($commit)
    }

    while (($pending.Count -gt 0) -and (-not $stopRequested)) {
        # 每批最多 100 个提交，避免单条 git 命令行过长
        $batchIds = @($pending | Select-Object -First 100 | ForEach-Object { $_.CommitId })
        Write-Host "当前正在批量合并内容...." -ForegroundColor Cyan
        Write-Host "`n正在批量 cherry-pick $($batchIds.Count) 条提交（从旧到新）："
        foreach ($batchId in $batchIds) {
            Write-Host ("  " + $batchId.Substring(0, 12)) -ForegroundColor Cyan
        }

        $pickArgs = @("cherry-pick") + $batchIds
        $pickResult = Invoke-Git -RepoPath $targetPath -Arguments $pickArgs -AllowFailure
        $wasConflictPath = $false
        if ($pickResult.ExitCode -eq 0) {
            Write-Host "批量合并成功：$($batchIds.Count) 条提交。" -ForegroundColor Green
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($pickResult.Output)) {
                Write-Host $pickResult.Output -ForegroundColor Yellow
            }

            if (-not [string]::IsNullOrWhiteSpace((Get-CherryPickInProgressCommit -RepoPath $targetPath))) {
                # 冲突 / 空提交：进入冲突处理循环（基于 CHERRY_PICK_HEAD 动态状态，外部处理完成会自动退出）
                $wasConflictPath = $true
                $resolution = Resolve-CherryPickConflict -RepoPath $targetPath -PickOutput $pickResult.Output
            }
            else {
                # 未进入 cherry-pick 状态（例如 merge 提交未指定 -m）
                $resolution = Resolve-NonSequencerFailure -RepoPath $targetPath -PickOutput $pickResult.Output -PendingIds $batchIds
            }

            switch ($resolution.Action) {
                "Aborted" { $stopRequested = $true }
                "Exited" { $stopRequested = $true }
                "Skipped" {
                    if (-not [string]::IsNullOrWhiteSpace($resolution.CommitId)) {
                        [void]$userSkippedIds.Add($resolution.CommitId)
                    }
                }
                "Retried" {
                    # merge 提交已通过 -m 1 等策略处理完成，显式记录避免重复尝试
                    if (-not [string]::IsNullOrWhiteSpace($resolution.CommitId)) {
                        [void]$userMergedIds.Add($resolution.CommitId)
                    }
                }
                default {
                    # Continued / External：由下一轮重新校验决定
                }
            }
        }

        # 冲突解决 / 批量成功后，把 sequencer 已经应用的本批提交显式记入已合集合，
        # 不再依赖 git cherry 的 patch-id 比对。冲突解决后内容常与源提交不同，git cherry 会把它
        # 判为"未合并"，导致下一轮重新校验又把它排进批次、再次 cherry-pick、再次冲突，陷入死循环。
        # 仅当确实走过了 sequencer 应用（干净成功，或冲突路径且未中止/退出）时才标记。
        if (($pickResult.ExitCode -eq 0) -or ($wasConflictPath -and (-not $stopRequested))) {
            $stoppedNow = Get-CherryPickInProgressCommit -RepoPath $targetPath
            if ([string]::IsNullOrWhiteSpace($stoppedNow)) {
                # sequencer 已结束：整批评论都已应用
                foreach ($bid in $batchIds) {
                    if (-not $userSkippedIds.Contains($bid)) { [void]$allAppliedIds.Add($bid) }
                }
            }
            else {
                # sequencer 停在 $stoppedNow：其之前的提交都已应用
                foreach ($bid in $batchIds) {
                    if ($bid -eq $stoppedNow) { break }
                    if (-not $userSkippedIds.Contains($bid)) { [void]$allAppliedIds.Add($bid) }
                }
            }
        }

        # 重新批量校验剩余待合并提交
        Write-Host "当前正在重新校验内容是否已经合并...." -ForegroundColor Cyan
        $targetHead = (Invoke-Git -RepoPath $targetPath -Arguments @("rev-parse", "HEAD")).Output.Trim()
        $unmergedCommits = @(Get-UnmergedCommits -RepoPath $targetPath -TargetHead $targetHead -Commits $selectedCommits -AppliedCommitIds $allAppliedIds)
        $null = Record-NewlyApplied -SelectedCommits $selectedCommits -UnmergedCommits $unmergedCommits -UserSkippedIds $userSkippedIds -RecordedAppliedIds $recordedAppliedIds -AllAppliedIds $allAppliedIds -AppliedMap $appliedMap -CommitDemandMap $commitDemandMap -AppliedFilePath $appliedFilePath
        $pending = New-Object System.Collections.ArrayList
        foreach ($commit in $unmergedCommits) {
            if (($userSkippedIds.Contains($commit.CommitId)) -or ($userMergedIds.Contains($commit.CommitId)) -or ($allAppliedIds.Contains($commit.CommitId))) {
                continue
            }
            [void]$pending.Add($commit)
        }
    }

    if ($stopRequested) {
        Write-Host "`n合并流程已停止。剩余 $($pending.Count) 条提交未合并。未执行 git push。" -ForegroundColor Yellow
        exit 2
    }

    $skippedTotal = $autoSkippedCount + @($userSkippedIds | Where-Object { $selectedCommitIds.Contains($_) }).Count
    $mergedCount = $selectedCommits.Count - $skippedTotal - $pending.Count
    Write-Host "`n全部处理完成：成功合并 $mergedCount 条，跳过 $skippedTotal 条。" -ForegroundColor Green
    Write-Host "当前目标分支：$targetBranch。"

    # 合并完成后询问：执行 push 推送，还是结束程序
    Invoke-PushAfterMerge -RepoPath $targetPath -BranchName $targetBranch
}
catch {
    Write-Host "`n执行失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
