<#
.SYNOPSIS
    Git Cherry-Pick 需求合并工具 - 桌面可视化操作界面
.DESCRIPTION
    在原有 git-cherry-pick.ps1 脚本程序基础上增加的可视化操作界面。
    本界面不直接修改原脚本，仅复用其数据文件（warehouse.json / gitCommitText.json /
    gitCommitRecord / commitTextSearch）并自行实现合并引擎。
    依赖：Windows + PowerShell 5.1 + .NET Framework（WinForms 默认已随系统提供）。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

# =========================================================================
# 全局状态
# =========================================================================
$script:scriptRoot      = $PSScriptRoot
$script:warehousePath   = Join-Path $script:scriptRoot 'warehouse.json'
$script:warehouse       = @{}          # 项目名称 -> 配置对象
$script:projectOrder    = New-Object System.Collections.ArrayList   # 保持 warehouse.json 书写顺序
$script:currentProject  = $null        # 当前选中的项目
$script:appliedMap      = @{}          # 当前项目的已合清单：demandNo -> ArrayList(@{commitText,commitId})
# 合并引擎运行态
$script:merge           = $null
$script:opNext          = $null        # 当前操作面板"确定"后要执行的延续脚本块
$script:opSelected      = $null        # 当前选中的操作选项 Key
# 合并进行中标志：Invoke-GitGui 等待期间会泵 UI 消息（避免"未响应"），
# 因此必须用它阻断项目切换 / 重复发起合并等重入操作。
$script:mergeBusy       = $false

# 日志缓冲：Add-Log 只入队，达到阈值或到达关键节点时才一次性写入 RichTextBox。
# 旧实现每行都做一次 ScrollToCaret + DoEvents，批量日志（数百行）时会明显拖慢界面。
$script:logBuffer       = New-Object System.Collections.ArrayList   # 元素：@{Text; Color}
$script:logBufferLimit  = 40        # 缓冲行数阈值，达到即刷新
$script:logMaxChars     = 200000    # 日志框文本上限，超出后从头部丢弃一半，避免长期运行越来越卡

# =========================================================================
# 纯逻辑辅助函数（无 UI）
# =========================================================================

function Read-AllText {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Description = 'JSON 文件'
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "未找到$Description：$Path"
    }
    try {
        $text = Read-AllText $Path
        return ($text | ConvertFrom-Json)
    }
    catch {
        throw "$Description不是有效 JSON：$Path`n$($_.Exception.Message)"
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Object
    )
    $json = $Object | ConvertTo-Json -Depth 6
    # UTF-8 无 BOM（与原脚本 Set-Content -Encoding UTF8 输出一致）
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function ResolvePathGui {
    param([Parameter(Mandatory=$true)][string]$ConfiguredPath)
    $v = [string]$ConfiguredPath
    if ([string]::IsNullOrWhiteSpace($v)) { return $v }
    if (-not [System.IO.Path]::IsPathRooted($v)) {
        $v = Join-Path $script:scriptRoot $v
    }
    return [System.IO.Path]::GetFullPath($v)
}

function Get-SafeFileNamePartGui {
    param([Parameter(Mandatory=$true)][string]$Value)
    $invalidChars = [regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars()))
    $safe = [regex]::Replace($Value, "[$invalidChars]", '_').Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { throw "无法根据值生成安全文件名：$Value" }
    return $safe
}

function Format-UserPath {
    # 将用户填写的地址规范化为脚本可接受的格式：统一反斜杠、去掉尾部分隔符、首尾去空格
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $v = $Raw.Trim()
    # 兼容用户输入的正斜杠，统一转为反斜杠
    $v = $v.Replace('/', '\')
    # 去掉尾部分隔符；但保留盘符根（如 D:\ 不能被截成 D:）
    while ($v.Length -gt 1 -and ($v.EndsWith('\') -or $v.EndsWith('/'))) {
        if ($v.Length -eq 3 -and $v[1] -eq ':') { break }
        $v = $v.Substring(0, $v.Length - 1)
    }
    return $v
}

function Load-Warehouse {
    $obj = $null
    if (Test-Path -LiteralPath $script:warehousePath -PathType Leaf) {
        $obj = Read-JsonFile -Path $script:warehousePath -Description '仓库配置文件 warehouse.json'
    }
    $ht = @{}
    $order = New-Object System.Collections.ArrayList
    if ($obj) {
        foreach ($p in $obj.PSObject.Properties) {
            $ht[$p.Name] = $p.Value
            [void]$order.Add($p.Name)
        }
    }
    $script:warehouse    = $ht
    $script:projectOrder = $order
}

function Save-Warehouse {
    $out = New-Object PSObject
    foreach ($k in $script:projectOrder) {
        $out | Add-Member -MemberType NoteProperty -Name $k -Value $script:warehouse[$k]
    }
    Write-JsonFile -Path $script:warehousePath -Object $out
}

function Get-ProjectPaths {
    param([Parameter(Mandatory=$true)][string]$Key)
    $cfg = $script:warehouse[$Key]
    if ($null -eq $cfg) {
        throw "仓库中不存在项目：$Key"
    }
    $props = @($cfg.PSObject.Properties.Name)

    $source = ResolvePathGui ([string]$cfg.beforeAddress)
    $target = ResolvePathGui ([string]$cfg.backAddress)

    if (($props -contains 'commitRecordAddress') -and (-not [string]::IsNullOrWhiteSpace([string]$cfg.commitRecordAddress))) {
        $recordDir = ResolvePathGui ([string]$cfg.commitRecordAddress)
    }
    else {
        $recordDir = Join-Path $script:scriptRoot ("gitCommitRecord\" + $Key)
    }

    $demandFile = Join-Path $script:scriptRoot 'gitCommitText.json'
    if (($props -contains 'commitTextSearchAddress') -and (-not [string]::IsNullOrWhiteSpace([string]$cfg.commitTextSearchAddress))) {
        $demandFile = ResolvePathGui ([string]$cfg.commitTextSearchAddress)
    }
    elseif (($props -contains 'commitTextAddress') -and (-not [string]::IsNullOrWhiteSpace([string]$cfg.commitTextAddress))) {
        $demandFile = ResolvePathGui ([string]$cfg.commitTextAddress)
    }

    $appliedFile = Join-Path $recordDir ("{0}_applied.json" -f $Key)

    return [PSCustomObject]@{
        Source     = $source
        Target     = $target
        RecordDir  = $recordDir
        DemandFile = $demandFile
        AppliedFile = $appliedFile
    }
}

function Load-AppliedMap {
    param([Parameter(Mandatory=$true)][string]$AppliedFile)
    $map = @{}
    if (Test-Path -LiteralPath $AppliedFile -PathType Leaf) {
        try {
            $loaded = Read-JsonFile -Path $AppliedFile -Description "已合清单 $AppliedFile"
            $entries = @()
            if ($loaded -is [System.Array]) { $entries = $loaded } else { $entries = @($loaded) }
            foreach ($entry in $entries) {
                $ep = @($entry.PSObject.Properties.Name)
                if ($ep -notcontains 'demandNo') { continue }
                $dn = ([string]$entry.demandNo).Trim()
                if ([string]::IsNullOrWhiteSpace($dn)) { continue }
                $list = New-Object System.Collections.ArrayList
                if ($ep -contains 'appliedCommitIds') {
                    foreach ($c in $entry.appliedCommitIds) {
                        $cp = @($c.PSObject.Properties.Name)
                        if (($cp -contains 'commitId') -and (-not [string]::IsNullOrWhiteSpace([string]$c.commitId))) {
                            [void]$list.Add([ordered]@{ commitText = [string]$c.commitText; commitId = [string]$c.commitId })
                        }
                    }
                }
                $map[$dn] = $list
            }
        }
        catch { }
    }
    $script:appliedMap = $map
}

function Save-AppliedMap {
    param(
        [Parameter(Mandatory=$true)][string]$AppliedFile,
        [Parameter(Mandatory=$true)]$Map
    )
    $output = New-Object System.Collections.ArrayList
    foreach ($demandNo in ($Map.Keys | Sort-Object)) {
        $list = $Map[$demandNo]
        if (($null -eq $list) -or ($list.Count -eq 0)) { continue }
        [void]$output.Add([ordered]@{
            demandNo        = $demandNo
            appliedCommitIds = @($list | ForEach-Object { [ordered]@{ commitText = $_.commitText; commitId = $_.commitId } })
        })
    }
    Write-JsonFile -Path $AppliedFile -Object $output
}

# ---------- Git 封装（Process 直调，UTF-8 解码，避免中文乱码）----------
function ConvertTo-GitArgumentLine {
    # 把参数数组拼成命令行。含空白的参数必须加双引号，否则形如
    # "D:\my repo\leasing_product_v2" 的路径会被拆成多个参数导致 git 报错。
    param([string[]]$Arguments)
    $parts = New-Object System.Collections.ArrayList
    foreach ($a in $Arguments) {
        $s = [string]$a
        if ([string]::IsNullOrEmpty($s)) { [void]$parts.Add('""'); continue }
        if (($s -match '\s') -and -not ($s.StartsWith('"') -and $s.EndsWith('"'))) {
            $s = '"' + $s.Replace('"', '\"') + '"'
        }
        [void]$parts.Add($s)
    }
    return ($parts -join ' ')
}

function Invoke-GitGui {
    <#
      P0 改造说明：
      1) 异步读取 stdout/stderr。旧实现「先 ReadToEnd(stdout) 再 ReadToEnd(stderr)」
         在 stderr 输出超过管道缓冲区（Windows 约 4KB）时会父子互相等待，
         导致进程永不返回、界面永久假死（批量 cherry-pick / pull / fetch 都会触发）。
      2) 等待期间用 DoEvents 泵 UI 消息。旧实现同步阻塞 UI 线程，窗口无法重绘，
         Windows 会打上「未响应」白屏；现在窗口保持可拖动/可重绘。
         合并期间按钮与项目列表已被禁用（见 $script:mergeBusy），不会因此重入。
      3) 支持 StandardInputText，配合 git cat-file --batch-check 做批量校验，
         消除逐条起进程的 N+1 问题。
      4) -Quiet 用于批量/短时调用，跳过泵消息，减少无谓的 UI 刷新。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RepoPath,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [string]$StandardInputText,
        [switch]$Quiet
    )
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName               = 'git'
    $p.StartInfo.Arguments              = ConvertTo-GitArgumentLine -Arguments $Arguments
    $p.StartInfo.WorkingDirectory       = $RepoPath
    $p.StartInfo.UseShellExecute        = $false
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError  = $true
    $p.StartInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p.StartInfo.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $p.StartInfo.CreateNoWindow         = $true
    $hasStdin = $PSBoundParameters.ContainsKey('StandardInputText')
    if ($hasStdin) { $p.StartInfo.RedirectStandardInput = $true }
    # 起进程前先落地缓冲日志：等待期间界面处于泵消息状态，用户应当能看到最新进度
    if ((-not $Quiet) -and $script:mergeBusy) { Flush-Log }
    [void]$p.Start()

    # 必须先启动异步读取，再写 stdin，否则输出量大时仍可能阻塞
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    if ($hasStdin) {
        try {
            $writer = New-Object System.IO.StreamWriter($p.StandardInput.BaseStream, [System.Text.Encoding]::ASCII)
            $writer.Write($StandardInputText)
            $writer.Flush()
            $writer.Close()
        }
        catch { }
    }

    $pump = -not $Quiet
    while (-not $p.HasExited) {
        if ($pump) {
            try { [System.Windows.Forms.Application]::DoEvents() }
            catch { $pump = $false }   # 窗体已关闭/释放，停止泵消息
        }
        Start-Sleep -Milliseconds 30
    }
    $p.WaitForExit()   # 确保异步读取已把管道内容全部排空

    $out  = $outTask.Result
    $err  = $errTask.Result
    $code = $p.ExitCode
    $p.Dispose()
    return [PSCustomObject]@{ ExitCode = $code; Output = ($out + $err) }
}

function Get-MissingCommitObjectsGui {
    <#
      批量校验提交对象是否存在于指定仓库。
      旧实现：对每条提交单独执行一次 `git cat-file -e`，属 N+1 次进程调用；
              本机实测单次约 1.1s，100+ 条即造成上百秒界面冻结。
      新实现：一次 `git cat-file --batch-check`，把全部对象名一次性喂给 stdin。
              实测 120 条由约 132s 降到约 2.5s。
      返回：不存在的提交 ID 数组（空数组表示全部存在）。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RepoPath,
        [Parameter(Mandatory=$true)][string[]]$CommitIds
    )
    $ids = @($CommitIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($ids.Count -eq 0) { return @() }

    $inputText = (($ids | ForEach-Object { "$_`^{commit}" }) -join "`n") + "`n"
    $r = Invoke-GitGui -RepoPath $RepoPath -Arguments @('cat-file','--batch-check') `
            -StandardInputText $inputText -Quiet

    if ($r.ExitCode -ne 0) {
        # 兜底：批量能力不可用时退回逐条校验，避免因批量调用失败而中断整个合并
        $fallback = New-Object System.Collections.ArrayList
        foreach ($id in $ids) {
            $one = Invoke-GitGui -RepoPath $RepoPath -Arguments @('cat-file','-e',"$id`^{commit}") -Quiet
            if ($one.ExitCode -ne 0) { [void]$fallback.Add($id) }
        }
        return @($fallback)
    }

    # 存在的对象输出 "<sha> <type> <size>"；不存在的对象行不会匹配该格式
    $ok = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in ($r.Output -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq '') { continue }
        if ($t -match '^([0-9a-f]{40})\s+commit\s+\d+$') { [void]$ok.Add($Matches[1]) }
    }
    $missing = New-Object System.Collections.ArrayList
    foreach ($id in $ids) {
        if (-not $ok.Contains($id)) { [void]$missing.Add($id) }
    }
    return @($missing)
}

function Get-SourceCommitsGui {
    param(
        [Parameter(Mandatory=$true)][string]$RepoPath,
        [Parameter(Mandatory=$true)][string]$Branch
    )
    $log = Invoke-GitGui -RepoPath $RepoPath -Arguments @(
        '--no-pager','log','--reverse','--encoding=UTF-8','--format=%H%x1f%cI%x1f%B%x1e',$Branch)
    if ($log.ExitCode -ne 0) { throw "获取源分支提交历史失败：`n$($log.Output)" }
    $commits = New-Object System.Collections.ArrayList
    $entries = $log.Output -split ([string][char]0x1e)
    $order = 0
    foreach ($entry in $entries) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $parts = $entry -split ([string][char]0x1f), 3
        if ($parts.Count -ne 3) { continue }
        $commitId   = $parts[0].Trim()
        $commitTime = $parts[1].Trim()
        $commitText = $parts[2].Trim()
        if ([string]::IsNullOrWhiteSpace($commitId)) { continue }
        [void]$commits.Add([PSCustomObject]@{
            CommitId = $commitId; CommitTime = $commitTime; CommitText = $commitText; Order = $order
        })
        $order++
    }
    return @($commits)
}

function Test-DemandIncludedExactlyGui {
    param([string]$CommitMessage, [string]$DemandNo)
    $escaped = [regex]::Escape($DemandNo)
    $pattern = "(?<![A-Za-z0-9_-])$escaped(?![A-Za-z0-9_-])"
    return [regex]::IsMatch($CommitMessage, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function New-DemandMatcherGui {
    <#
      P1-2：把"逐个需求编号 × 全量提交"的两层循环（O(需求数 × 提交数) 次正则匹配）压成
      一次遍历 + 一个合并正则（O(提交数) 次）。25 个需求、数百条提交时省下的是纯 CPU 时间。
      语义与 Test-DemandIncludedExactlyGui 保持一致：两侧仍用
        (?<![A-Za-z0-9_-]) / (?![A-Za-z0-9_-])
      做边界断言；候选串按长度从长到短排列，保证 "P0-A" 与 "P0-A-1" 同时存在时
      不会在 "P0-A-1" 上先命中短串（短串会被后置断言挡住，长串优先才能真正匹配）。
      返回 $null 表示无法构造合并正则，调用方回退到逐需求匹配。
    #>
    param([string[]]$DemandNos)
    $canon = @{}
    $alts  = New-Object System.Collections.ArrayList
    foreach ($dn in $DemandNos) {
        $d = ([string]$dn).Trim()
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $u = $d.ToUpperInvariant()
        if ($canon.ContainsKey($u)) { continue }   # 忽略大小写去重
        $canon[$u] = $d
        [void]$alts.Add($d)
    }
    if ($alts.Count -eq 0) { return $null }

    $sorted  = @($alts | Sort-Object -Property Length -Descending)
    $escaped = @($sorted | ForEach-Object { [regex]::Escape($_) })
    $pattern = '(?<![A-Za-z0-9_-])(?<dn>' + ($escaped -join '|') + ')(?![A-Za-z0-9_-])'
    try {
        $rx = New-Object System.Text.RegularExpressions.Regex ($pattern, ([Text.RegularExpressions.RegexOptions]::IgnoreCase))
    }
    catch { return $null }
    return [PSCustomObject]@{ Regex = $rx; Canon = $canon }
}

function Get-DemandMatchMapGui {
    <#
      P1-2：一次遍历完成"提交 -> 命中哪些需求编号"的归属计算。
      返回 @{}：需求编号（大写） -> ArrayList(命中的提交对象，保持传入顺序即源分支时间顺序)。
      合并正则构造失败时回退到逐需求匹配（与旧实现完全一致），保证不因正则问题漏匹配。
    #>
    param(
        [Parameter(Mandatory=$true)][object[]]$Commits,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$DemandNos
    )
    $matchMap = @{}
    foreach ($dn in $DemandNos) {
        $d = ([string]$dn).Trim()
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $u = $d.ToUpperInvariant()
        if (-not $matchMap.ContainsKey($u)) { $matchMap[$u] = New-Object System.Collections.ArrayList }
    }
    if ($matchMap.Count -eq 0) { return $matchMap }

    $matcher = New-DemandMatcherGui -DemandNos @($DemandNos)
    if ($null -ne $matcher) {
        # 每个提交内先对命中结果去重，避免同一需求在一条 message 里出现多次时被重复计入
        $hit = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($c in $Commits) {
            $hit.Clear()
            foreach ($mo in $matcher.Regex.Matches([string]$c.CommitText)) {
                [void]$hit.Add($mo.Groups['dn'].Value.ToUpperInvariant())
            }
            if ($hit.Count -eq 0) { continue }
            foreach ($u in $hit) {
                if ($matchMap.ContainsKey($u)) { [void]$matchMap[$u].Add($c) }
            }
        }
        return $matchMap
    }

    foreach ($dn in $DemandNos) {
        $d = ([string]$dn).Trim()
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $u = $d.ToUpperInvariant()
        foreach ($c in $Commits) {
            if (Test-DemandIncludedExactlyGui -CommitMessage $c.CommitText -DemandNo $d) {
                if ($matchMap.ContainsKey($u)) { [void]$matchMap[$u].Add($c) }
            }
        }
    }
    return $matchMap
}

function Get-CherryPickInProgressGui {
    param([Parameter(Mandatory=$true)][string]$RepoPath)
    $r = Invoke-GitGui -RepoPath $RepoPath -Arguments @('rev-parse','--quiet','--verify','CHERRY_PICK_HEAD')
    if ($r.ExitCode -ne 0) { return '' }
    return $r.Output.Trim()
}

function Get-UnmergedCommitsGui {
    <#
      P1-1 改造：用单次 `git cherry HEAD FETCH_HEAD` 同时取得两类信息，替代旧实现的
      rev-list（取目标祖先集合）+ cherry（取补丁等价集合）+ 其前的 rev-parse HEAD。
      可行性依据：cherry 只会列出 "FETCH_HEAD --not HEAD" 区间内的提交，
        '+ <sha>' = 尚未进入目标，需要 cherry-pick
        '- <sha>' = 目标中已有补丁等价的提交
      目标祖先集合在该区间里天然被排除，因此祖先判定已被 cherry 的区间覆盖，
      两次多余的 git 进程（本机实测每次约 0.9~1.3s）可以省掉。
      仍然保留 cat-file --batch-check：它校验对象是否真的 fetch 到了，
      不满足时应当明确报错，而不是让后续 cherry-pick 抛出一堆看不懂的信息。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RepoPath,
        [Parameter(Mandatory=$true)][object[]]$Commits,
        [object]$AppliedCommitIds
    )
    if ($Commits.Count -eq 0) { return @() }

    $cherryR = Invoke-GitGui -RepoPath $RepoPath -Arguments @('cherry','HEAD','FETCH_HEAD')
    if ($cherryR.ExitCode -ne 0) {
        # 旧实现在 cherry 失败时静默按"补丁等价集合为空"处理；这里改为显式失败：
        # 只有 cherry 这一个数据源时，静默降级会把"还没合并"误判成"已合并"。
        throw "git cherry 校验失败（FETCH_HEAD 可能不存在，请确认 fetch 成功）：$($cherryR.Output)"
    }
    $patchPending = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in ($cherryR.Output -split "`r?`n")) {
        if ($line -match '^\+\s*([0-9a-f]{40})') { [void]$patchPending.Add($Matches[1]) }
    }

    # P0 改造保留：先按 补丁待合并集合 / 已合清单 过滤，只对"真正还需要合并"的提交
    # 校验对象是否存在，再用一次 cat-file --batch-check 批量完成。
    $unmerged = New-Object System.Collections.ArrayList
    foreach ($commit in $Commits) {
        $id = $commit.CommitId
        if (-not $patchPending.Contains($id)) { continue }   # 已是目标祖先，或目标中已有等价补丁
        if (($null -ne $AppliedCommitIds) -and $AppliedCommitIds.Contains($id)) { continue }
        [void]$unmerged.Add($commit)
    }
    if ($unmerged.Count -eq 0) { return @() }

    $missing = Get-MissingCommitObjectsGui -RepoPath $RepoPath -CommitIds @($unmerged | ForEach-Object { $_.CommitId })
    if ($missing.Count -gt 0) {
        throw "目标仓库中不存在提交对象 $($missing[0])。请确认从源仓库 fetch 成功。"
    }
    return @($unmerged)
}

function Get-CurrentBranchGui {
    param([Parameter(Mandatory=$true)][string]$RepoPath)
    $r = Invoke-GitGui -RepoPath $RepoPath -Arguments @('symbolic-ref','--quiet','--short','HEAD')
    if (($r.ExitCode -ne 0) -or [string]::IsNullOrWhiteSpace($r.Output)) {
        throw "仓库当前处于 detached HEAD 状态，无法确定分支：$RepoPath"
    }
    return $r.Output.Trim()
}

# =========================================================================
# UI 控件句柄（在构建阶段赋值）
# =========================================================================
$ui = @{}

function Add-Log {
    # P2 改造：只入队缓冲，不再每行都 AppendText + ScrollToCaret + DoEvents。
    # 日志框为空时直接丢弃（例如无界面的隔离测试环境）。
    param([string]$Text, [System.Drawing.Color]$Color)
    if ($null -eq $Color) { $Color = [System.Drawing.Color]::Black }
    if ($null -eq $ui.LogBox) { return }
    [void]$script:logBuffer.Add([PSCustomObject]@{ Text = $Text; Color = $Color })
    if ($script:logBuffer.Count -ge $script:logBufferLimit) { Flush-Log }
}

function Flush-Log {
    # 把缓冲区攒下的日志一次性写入日志框：逐行着色，但整批只做一次滚动与重绘。
    # 缓冲区为空时立即返回，所以可以在每个关键节点无条件调用。
    $box = $ui.LogBox
    if ($null -eq $box) { return }
    if ($script:logBuffer.Count -eq 0) { return }
    $box.SelectionStart = $box.TextLength
    foreach ($item in $script:logBuffer) {
        $box.SelectionColor = $item.Color
        $box.AppendText($item.Text + "`r`n")
    }
    $script:logBuffer.Clear()
    Trim-LogBox
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-LogNow {
    # 用户交互（新增 / 覆盖新增 / 删除需求编号、保存 / 删除项目、切换合并状态等）直接产生的日志：
    # 这类日志通常只有一两行，永远达不到 $script:logBufferLimit 的阈值，若只走 Add-Log 入队，
    # 就会一直留在缓冲里不显示，直到下一次合并等关键节点调用 Flush-Log 时才"迟到"冒出来。
    # 因此交互路径统一用本函数：入队后立即刷新，保证点完按钮马上看到结果。
    param([string]$Text, [System.Drawing.Color]$Color)
    Add-Log $Text $Color
    Flush-Log
}

function Trim-LogBox {
    # 文本超上限时从头部按行丢弃一半，防止长时间运行后 RichTextBox 渲染越来越慢。
    # ReadOnly 控件下 SelectedText 赋值不保证生效，因此临时解除只读再恢复。
    $box = $ui.LogBox
    if ($null -eq $box) { return }
    if ($box.TextLength -le $script:logMaxChars) { return }
    try {
        # 分轮丢弃头部一半，直到落回上限以内（最多 12 轮，足够把任意超量压到 1/4096）。
        # 不用 RichTextBox.Lines / GetFirstCharIndexFromLine 定位：控件未挂载窗体时这两个
        # 行索引 API 返回值不可靠（实测裁剪后仍超上限）。改为对 Text 做位置计算，
        # RichTextBox.Text 的行分隔统一为 \n，行为在挂载/未挂载两种情况下一致。
        $box.ReadOnly = $false
        for ($i = 0; $i -lt 12; $i++) {
            if ($box.TextLength -le $script:logMaxChars) { break }
            $text = $box.Text
            $cut  = [int]($text.Length / 2)
            $nl   = $text.IndexOf("`n", $cut)
            if ($nl -lt 0) { $nl = $text.Length - 1 }
            if ($nl -lt 0) { break }
            $box.Select(0, $nl + 1)
            $box.SelectedText = ''
        }
    }
    catch { }
    finally { $box.ReadOnly = $true }
}

# =========================================================================
# 项目列表 / 需求列表 刷新
# =========================================================================
function Refresh-ProjectList {
    $list = $ui.ProjectList
    $list.Items.Clear()
    foreach ($k in $script:projectOrder) {
        [void]$list.Items.Add($k)
    }
}

function Refresh-DemandList {
    $key = $script:currentProject
    $list = $ui.DemandList
    if ($null -eq $list) { return }
    $list.Items.Clear()
    if ([string]::IsNullOrWhiteSpace($key)) { return }

    # 强制 Details 视图与列（某些情况下 View 可能被重置导致行不显示）
    if ($list.View -ne 'Details') { $list.View = 'Details' }
    if ($list.Columns.Count -eq 0) {
        [void]$list.Columns.Add('序号', 50)
        [void]$list.Columns.Add('需求编号', 180)
        [void]$list.Columns.Add('是否合并', 80)
    }

    $paths = Get-ProjectPaths -Key $key
    $seq = 0
    if (Test-Path -LiteralPath $paths.DemandFile -PathType Leaf) {
        try {
            $arr = @(Read-JsonFile -Path $paths.DemandFile -Description "需求配置文件（项目 $key）")
            foreach ($e in $arr) {
                if ($null -eq $e -or $null -eq $e.commitText) { continue }
                $dn = ([string]$e.commitText).Trim()
                if ([string]::IsNullOrWhiteSpace($dn)) { continue }
                $seq++
                $merged = '未合并'
                if ($script:appliedMap.ContainsKey($dn) -and $script:appliedMap[$dn].Count -gt 0) {
                    $merged = '已合并'
                }
                $item = New-Object System.Windows.Forms.ListViewItem ($seq.ToString())
                [void]$item.SubItems.Add($dn)
                [void]$item.SubItems.Add($merged)
                [void]$list.Items.Add($item)
            }
            if ($list.Items.Count -gt 0) {
                $list.Items[0].Selected = $true
                $list.EnsureVisible(0)
            }
            # 强制重绘，避免 TableLayoutPanel 初次布局后 ListView 行不渲染
            $list.Refresh()
            $list.Update()
            [System.Windows.Forms.Application]::DoEvents()
        }
        catch {
            Add-LogNow "读取需求文件失败：$($_.Exception.Message)" ([System.Drawing.Color]::Red)
        }
    }
    else {
        Add-LogNow "项目 [$key] 暂未配置需求编号文件：$($paths.DemandFile)" ([System.Drawing.Color]::Gray)
    }
}

function Select-Project {
    param([string]$Key)
    # 合并进行中且会泵 UI 消息，禁止切换项目，避免改动 $script:appliedMap 等共享状态
    if ($script:mergeBusy) { return }
    $script:currentProject = $Key
    if ([string]::IsNullOrWhiteSpace($Key)) {
        $ui.ProjectInfoLabel.Text = '未选择项目'
        $ui.DemandList.Items.Clear()
        Set-DemandButtonsEnabled $false
        return
    }
    $cfg = $script:warehouse[$Key]
    if ($null -eq $cfg) {
        $ui.ProjectInfoLabel.Text = "项目不存在（可能已从 warehouse.json 删除）：$Key"
        $ui.DemandList.Items.Clear()
        Set-DemandButtonsEnabled $false
        return
    }
    $paths = Get-ProjectPaths -Key $Key
    Load-AppliedMap -AppliedFile $paths.AppliedFile

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("当前项目：$Key")
    [void]$sb.AppendLine("合并前：$($paths.Source)")
    [void]$sb.AppendLine("合并后：$($paths.Target)")
    [void]$sb.AppendLine("需求文件：$($paths.DemandFile)")
    [void]$sb.AppendLine("记录目录：$($paths.RecordDir)")
    $ui.ProjectInfoLabel.Text = $sb.ToString()

    Refresh-DemandList
    Set-DemandButtonsEnabled $true
}

function Set-DemandButtonsEnabled {
    param([bool]$Enabled)
    foreach ($b in @($ui.BtnOverwriteAdd, $ui.BtnAddDemand, $ui.BtnDelDemand,
                     $ui.BtnToggleStatus, $ui.BtnView, $ui.BtnMergeAll, $ui.BtnMerge)) {
        if ($null -ne $b) { $b.Enabled = $Enabled }
    }
}

# =========================================================================
# 操作面板（合并过程中展示选项 + 确定）
# =========================================================================
function Hide-OperationPanel {
    $ui.OpPanel.Visible = $false
    if ($null -ne $ui.RrTable) {
        $ui.RrTable.RowStyles[2].Height = 0
        $ui.RrTable.PerformLayout()
    }
    $script:opNext     = $null
    $script:opSelected = $null
}

function Show-OperationPanel {
    param(
        [string]$Message,
        [System.Collections.ArrayList]$Options,   # 每个元素 @{Key; Label}
        [scriptblock]$NextAction
    )
    # 面板出现前先落地缓冲日志：用户需要看到"为什么弹出这个选择"
    Flush-Log
    $ui.OpLabel.Text = $Message
    $ui.OpFlow.Controls.Clear()
    $script:opSelected = $null
    $script:opButtons  = New-Object System.Collections.ArrayList

    foreach ($o in $Options) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = "$($o.Key)  $($o.Label)"
        $b.Tag  = $o.Key
        $b.AutoSize = $true
        $b.Margin = New-Object System.Windows.Forms.Padding(3)
        $b.Add_Click({
            param($s, $e)
            $script:opSelected = $s.Tag
            foreach ($ob in $script:opButtons) { $ob.BackColor = [System.Drawing.SystemColors]::Control }
            $s.BackColor = [System.Drawing.Color]::LightSkyBlue
            $ui.OpConfirm.Enabled = $true
        })
        $ui.OpFlow.Controls.Add($b)
        [void]$script:opButtons.Add($b)
    }
    $ui.OpConfirm.Enabled = $false
    $script:opNext = $NextAction
    $ui.OpPanel.Visible = $true
    if ($null -ne $ui.RrTable) {
        $ui.RrTable.RowStyles[2].Height = 220
        $ui.RrTable.PerformLayout()
    }
}

# =========================================================================
# 合并引擎（状态机：每次需要决策时由操作面板等待用户，确定后继续执行）
# =========================================================================

function Merge-EnableDemandButtons($Enabled) {
    foreach ($b in @($ui.BtnOverwriteAdd, $ui.BtnAddDemand, $ui.BtnDelDemand,
                     $ui.BtnToggleStatus, $ui.BtnView, $ui.BtnMergeAll, $ui.BtnMerge)) {
        $b.Enabled = $Enabled
    }
    $ui.BtnDeleteProject.Enabled = $Enabled
    $ui.BtnEditProject.Enabled   = $Enabled
    $ui.BtnAddProject.Enabled    = $Enabled
    $ui.ProjectList.Enabled      = $Enabled
}

function Merge-Begin {
    param([System.Collections.ArrayList]$DemandNos)
    # 重入保护：合并流程会泵 UI 消息，禁止在合并未结束时再次发起
    if ($script:mergeBusy) { return }
    $key = $script:currentProject
    if ([string]::IsNullOrWhiteSpace($key)) {
        [System.Windows.Forms.MessageBox]::Show('请先在左侧选择一个项目。', '提示', 'OK', 'Information')
        return
    }
    if ($DemandNos.Count -eq 0) {
        Add-LogNow '没有可合并的需求编号（列表为空）。' ([System.Drawing.Color]::DarkGoldenrod)
        return
    }

    $paths   = Get-ProjectPaths -Key $key
    $src     = $paths.Source
    $tgt     = $paths.Target
    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
        Add-LogNow "合并前项目地址不存在：$src" ([System.Drawing.Color]::Red); return
    }
    if (-not (Test-Path -LiteralPath $tgt -PathType Container)) {
        Add-LogNow "合并后项目地址不存在：$tgt" ([System.Drawing.Color]::Red); return
    }

    if (-not (Test-Path -LiteralPath $paths.DemandFile -PathType Leaf)) {
        Add-LogNow "需求编号文件不存在：$($paths.DemandFile)" ([System.Drawing.Color]::Red); return
    }

    # 校验 git 可用
    $gitChk = Invoke-GitGui -RepoPath $tgt -Arguments @('--version')
    if ($gitChk.ExitCode -ne 0) {
        Add-LogNow '未找到 git 命令，请先安装 Git for Windows 并加入 PATH。' ([System.Drawing.Color]::Red); return
    }

    $script:merge = [PSCustomObject]@{
        Key         = $key
        Paths       = $paths
        Source      = $src
        Target      = $tgt
        DemandFile  = $paths.DemandFile
        AppliedFile = $paths.AppliedFile
        RecordDir   = $paths.RecordDir
        DemandNos   = @($DemandNos)
        AllCommits  = New-Object System.Collections.ArrayList
        CommitIndex = @{}          # 提交ID -> 提交对象 的哈希索引（替代循环内 Where-Object 全量扫描）
        CommitDemandMap = @{}
        AppliedMap  = $script:appliedMap
        SkippedIds  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        MergedIds   = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        RecordedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        TrustAppliedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Pending     = New-Object System.Collections.ArrayList
        PendingPool = $null        # P1-1：上次校验得出的"未合并"集合，供增量校验做集合差
        DidPick     = $false
        CurrentBatchIds = @()
        LastBatchApplied = $false
        SourceBranch = ''
        TargetBranch = ''
    }

    $script:mergeBusy = $true
    Merge-EnableDemandButtons $false
    Add-Log "========== 开始合并项目 [$key] ==========" ([System.Drawing.Color]::DarkCyan)
    Merge-Scan
}

function Select-AppliedListsGui {
    # 启动合并前，若已存在"已合清单"，询问用户是否信任并加载（加载后这些提交将被跳过，不再重复合并）。
    # 与命令行参考脚本 git-cherry-pick.ps1 的 Select-AppliedLists 行为一致。
    $m = $script:merge
    $m.TrustAppliedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $hasList = $false
    foreach ($dn in $m.DemandNos) {
        if ($m.AppliedMap.ContainsKey($dn) -and $m.AppliedMap[$dn].Count -gt 0) { $hasList = $true; break }
    }
    if (-not $hasList) {
        # 没有已合清单，直接进入确认环节（git cherry 仍会排除已合提交）
        Merge-Confirm; return
    }

    Add-Log '检测到以下需求存在已合清单：' ([System.Drawing.Color]::DarkCyan)
    foreach ($dn in $m.DemandNos) {
        if ($m.AppliedMap.ContainsKey($dn) -and $m.AppliedMap[$dn].Count -gt 0) {
            Add-Log ("  需求 {0}：已记录 {1} 条" -f $dn, $m.AppliedMap[$dn].Count) ([System.Drawing.Color]::Gray)
        }
    }
    Show-OperationPanel -Message '检测到以下需求存在已合清单（加载后这些提交将被跳过，不再重复合并）。是否加载？' -Options @(
        @{Key='A'; Label='全部加载'},
        @{Key='Q'; Label='不加载（按 git cherry 补丁比对判断）'}
    ) -NextAction {
        param($choice)
        $m = $script:merge
        # 重新计算，避免依赖已离开作用域的局部变量
        $m.TrustAppliedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        if ($choice -eq 'A') {
            foreach ($dn in $m.DemandNos) {
                if ($m.AppliedMap.ContainsKey($dn) -and $m.AppliedMap[$dn].Count -gt 0) {
                    foreach ($c in $m.AppliedMap[$dn]) { [void]$m.TrustAppliedIds.Add($c.commitId) }
                }
            }
            Add-Log '已加载已合清单，对应提交将被跳过。' ([System.Drawing.Color]::Green)
        }
        else {
            Add-Log '未加载已合清单，将按 git cherry 补丁比对判断。' ([System.Drawing.Color]::DarkGoldenrod)
        }
        Merge-Confirm
    }
}

function Merge-Scan {
    $m = $script:merge
    Add-Log '检索源分支提交记录...' ([System.Drawing.Color]::DarkCyan)
    try {
        $m.SourceBranch = Get-CurrentBranchGui -RepoPath $m.Source
        $m.TargetBranch = Get-CurrentBranchGui -RepoPath $m.Target
    }
    catch {
        Add-Log "获取分支失败：$($_.Exception.Message)" ([System.Drawing.Color]::Red)
        Merge-Finish '合并中止（分支获取失败）'; return
    }
    Add-Log "合并前：$($m.Source)（分支：$($m.SourceBranch)）" ([System.Drawing.Color]::Gray)
    Add-Log "合并后：$($m.Target)（分支：$($m.TargetBranch)）" ([System.Drawing.Color]::Gray)

    $allCommits = @(Get-SourceCommitsGui -RepoPath $m.Source -Branch $m.SourceBranch)
    if (-not (Test-Path -LiteralPath $m.RecordDir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $m.RecordDir -Force)
    }
    $safeKey = Get-SafeFileNamePartGui -Value $m.Key

    # P1-2 改造：一次遍历扫出所有需求编号的命中情况。
    # 旧实现是"每个需求各扫一遍全量提交"（O(需求数 × 提交数) 次正则匹配）。
    $matchMap = Get-DemandMatchMapGui -Commits @($allCommits) -DemandNos @($m.DemandNos)
    Add-Log ("已扫描 {0} 条提交完成需求编号匹配。" -f $allCommits.Count) ([System.Drawing.Color]::Gray)

    # 汇总所有需求命中的提交 ID（同一提交可能命中多个需求编号）
    $selectedCommitIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($dn in $m.DemandNos) {
        $d = ([string]$dn).Trim()
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $u = $d.ToUpperInvariant()
        $matches = @()
        if ($matchMap.ContainsKey($u)) { $matches = @($matchMap[$u]) }
        $safeDn  = Get-SafeFileNamePartGui -Value $d
        $record  = [ordered]@{
            demandNo = $dn
            commitRecordList = @($matches | ForEach-Object {
                [ordered]@{ commitText = $_.CommitText; commitId = $_.CommitId; commitTime = $_.CommitTime }
            })
        }
        $recordPath = Join-Path $m.RecordDir ("{0}_{1}.json" -f $safeKey, $safeDn)
        Write-JsonFile -Path $recordPath -Object $record
        Add-Log ("需求 {0}：找到 {1} 条提交，记录已写入 {2}" -f $dn, $matches.Count, $recordPath) ([System.Drawing.Color]::Gray)

        foreach ($c in $matches) {
            # 提交 -> 需求编号映射（用于按需求写入已合清单），同一提交可能命中多个需求
            if (-not $m.CommitDemandMap.ContainsKey($c.CommitId)) {
                $m.CommitDemandMap[$c.CommitId] = New-Object System.Collections.ArrayList
            }
            if (-not $m.CommitDemandMap[$c.CommitId].Contains($d)) {
                [void]$m.CommitDemandMap[$c.CommitId].Add($d)
            }
            [void]$selectedCommitIds.Add($c.CommitId)
        }
    }

    # 对齐命令行脚本的合并策略：先汇总所有需求命中的提交，再按源分支原始提交时间
    # （$allCommits 由 git log --reverse 取得，严格从旧到新）统一排序，而不是按需求编号
    # 顺序拼接。这样可以避免跨需求的提交因排序错位而产生不必要的冲突。
    $m.AllCommits = @($allCommits | Where-Object { $selectedCommitIds.Contains($_.CommitId) })

    # P0 改造：一次性建立 提交ID -> 提交对象 的哈希索引。
    # 旧实现在 Mark-BatchAppliedGui 的循环里用 Where-Object 反复全量扫描 AllCommits，
    # 复杂度 O(批大小 × 提交总数)，批量提交多时是一处明显的卡顿来源。
    $m.CommitIndex = @{}
    foreach ($c in $m.AllCommits) { $m.CommitIndex[$c.CommitId] = $c }

    if ($m.AllCommits.Count -eq 0) {
        Add-Log '所有需求均未检索到符合条件的提交，不执行合并。' ([System.Drawing.Color]::DarkGoldenrod)
        Merge-Finish '未检索到可合并提交'; return
    }

    Add-Log ("共检索到 {0} 条待处理提交（按源分支时间从旧到新）。" -f $m.AllCommits.Count) ([System.Drawing.Color]::Gray)
    Select-AppliedListsGui
}

function Merge-Confirm {
    Add-Log '请确认是否开始合并。' ([System.Drawing.Color]::DarkCyan)
    Show-OperationPanel -Message '确认开始合并？' -Options @(
        @{Key='A'; Label='开始合并'},
        @{Key='B'; Label='取消'}
    ) -NextAction {
        param($choice)
        if ($choice -eq 'B') { Merge-Finish '已取消，本次未执行 cherry-pick。'; return }
        Merge-Precheck
    }
}

function Merge-Precheck {
    $m = $script:merge
    $head = Get-CherryPickInProgressGui -RepoPath $m.Target
    if ([string]::IsNullOrWhiteSpace($head)) {
        Merge-Pull
        return
    }
    $short = $head.Substring(0, [Math]::Min(12, $head.Length))
    Add-Log "检测到目标仓库存在未完成的 cherry-pick 状态（CHERRY_PICK_HEAD = $short）。" ([System.Drawing.Color]::DarkGoldenrod)
    Show-OperationPanel -Message "目标仓库存在未完成的 cherry-pick（$short）。请选择处理方式：" -Options @(
        @{Key='A'; Label='中止残留 cherry-pick 并继续'},
        @{Key='C'; Label='我已手动处理完成，重新检测后继续'},
        @{Key='E'; Label='退出，我自行处理'}
    ) -NextAction {
        param($choice)
        $m = $script:merge
        if ($choice -eq 'E') { Merge-Finish '已退出，请自行处理目标仓库的 cherry-pick 状态。'; return }
        if ($choice -eq 'A') {
            $r = Invoke-GitGui -RepoPath $m.Target -Arguments @('cherry-pick','--abort')
            if ($r.ExitCode -ne 0) {
                Add-Log "中止失败：$($r.Output)" ([System.Drawing.Color]::DarkGoldenrod)
                Merge-Precheck; return
            }
            Add-Log '已中止残留 cherry-pick，目标分支恢复到合并前状态。' ([System.Drawing.Color]::Green)
            Merge-Pull; return
        }
        if ($choice -eq 'C') {
            $re = Get-CherryPickInProgressGui -RepoPath $m.Target
            if ([string]::IsNullOrWhiteSpace($re)) {
                Add-Log '残留状态已清除，继续后续步骤。' ([System.Drawing.Color]::Green)
                Merge-Pull; return
            }
            Add-Log 'CHERRY_PICK_HEAD 仍存在，请先完成或中止 cherry-pick 后再继续。' ([System.Drawing.Color]::DarkGoldenrod)
            Merge-Precheck; return
        }
    }
}

function Merge-Pull {
    $m = $script:merge
    # 合并前安全检查：工作区干净 + 是否配置上游分支。
    # P1-1 改造：原本 status --porcelain 与 rev-parse @{u} 各起一次 git 进程（本机每次约 1s），
    # 现合并为一次 git status --porcelain=v1 -b——首行 "## <分支>...<上游>" 即代表已配置上游。
    $st = Invoke-GitGui -RepoPath $m.Target -Arguments @('status','--porcelain=v1','-b')
    if ($st.ExitCode -ne 0) {
        Add-Log "无法读取目标仓库状态：$($st.Output)" ([System.Drawing.Color]::Red)
        Merge-Finish '合并中止（无法读取目标仓库状态）'; return
    }
    $stLines = @($st.Output -split "`r?`n")
    $header  = ''
    if ($stLines.Count -gt 0) { $header = [string]$stLines[0] }
    $dirty = @()
    if ($stLines.Count -gt 1) {
        $dirty = @($stLines[1..($stLines.Count - 1)] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($dirty.Count -gt 0) {
        Add-Log ("合并后项目存在未提交改动，为避免覆盖现有工作，请先提交或暂存：`n" + ($dirty -join "`n")) ([System.Drawing.Color]::Red)
        Merge-Finish '合并中止（目标工作区不干净）'; return
    }

    Add-Log '更新目标分支到最新状态（git pull）...' ([System.Drawing.Color]::DarkCyan)
    if ($header -notmatch '^##\s+\S+\.\.\.') {
        Add-Log '目标分支未配置上游分支（@{u}），跳过更新。' ([System.Drawing.Color]::DarkGoldenrod)
        Merge-Fetch; return
    }
    $pull = Invoke-GitGui -RepoPath $m.Target -Arguments @('-c','pull.rebase=false','pull')
    if ($pull.ExitCode -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($pull.Output)) { Add-Log $pull.Output ([System.Drawing.Color]::Gray) }
        Merge-Fetch; return
    }
    Add-Log "git pull 执行失败：`n$($pull.Output)" ([System.Drawing.Color]::DarkGoldenrod)
    Show-OperationPanel -Message 'git pull 失败，请在另一个终端处理（如解决冲突或检查网络）后继续。' -Options @(
        @{Key='Y'; Label='我已手动处理完成，确认继续'},
        @{Key='Q'; Label='退出'}
    ) -NextAction {
        param($choice)
        if ($choice -eq 'Q') { Merge-Finish '已退出，未执行 cherry-pick。'; return }
        Merge-Fetch
    }
}

function Merge-Fetch {
    $m = $script:merge
    Add-Log '从本地源仓库抓取提交对象（不会修改源项目，也不会 push）...' ([System.Drawing.Color]::DarkCyan)
    $fetch = Invoke-GitGui -RepoPath $m.Target -Arguments @('fetch','--no-tags',$m.Source,$m.SourceBranch)
    if ($fetch.ExitCode -ne 0) {
        Add-Log "git fetch 失败：$($fetch.Output)" ([System.Drawing.Color]::Red)
        Merge-Finish '合并中止（fetch 失败）'; return
    }
    if (-not [string]::IsNullOrWhiteSpace($fetch.Output)) { Add-Log $fetch.Output ([System.Drawing.Color]::Gray) }
    Merge-ReVerify
}

function Merge-ReVerify {
    <#
      P1-1 改造：把"每批成功后都全量重算"改成"首次全量 + 后续增量"。
      全量路径：单次 git cherry（详见 Get-UnmergedCommitsGui），不再需要 rev-list / rev-parse。
      增量路径（-Incremental）：cherry-pick 退出码为 0 说明本批全部应用，批次内容已由
        Mark-BatchAppliedGui 写入已合清单并落盘；此时相对上次校验唯一的变化就是"这批已合并"，
        不需要再起任何 git 进程，直接在上次校验结果 PendingPool 上做集合差即可。
        没有上一次结果（PendingPool 为空）时自动退回全量。
    #>
    param([switch]$Incremental)
    $m = $script:merge

    # 已合跟踪集合 = 用户选择信任的已合清单 + 本次运行过程中新记录的（含跳过的）
    $allApplied = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $m.TrustAppliedIds) { [void]$allApplied.Add($id) }
    foreach ($id in $m.RecordedIds)     { [void]$allApplied.Add($id) }
    foreach ($id in $m.MergedIds)       { [void]$allApplied.Add($id) }

    $useIncremental = ($Incremental -and ($null -ne $m.PendingPool))
    if ($useIncremental) {
        Add-Log '当前正在校验内容是否已经合并....（增量：复用上次校验结果）' ([System.Drawing.Color]::DarkCyan)
        $pool = New-Object System.Collections.ArrayList
        foreach ($c in $m.PendingPool) {
            if ($m.MergedIds.Contains($c.CommitId))  { continue }
            if ($m.SkippedIds.Contains($c.CommitId)) { continue }
            [void]$pool.Add($c)
        }
        $unmerged = @($pool)
    }
    else {
        Add-Log '当前正在校验内容是否已经合并....' ([System.Drawing.Color]::DarkCyan)
        try {
            $unmerged = @(Get-UnmergedCommitsGui -RepoPath $m.Target -Commits $m.AllCommits -AppliedCommitIds $allApplied)
        }
        catch {
            Add-Log "校验失败：$($_.Exception.Message)" ([System.Drawing.Color]::Red)
            Merge-Finish '合并中止（校验失败）'; return
        }
    }
    $m.PendingPool = @($unmerged)

    # 记录已合（持久化到 applied 清单）。
    # 增量路径下本批提交已由 Mark-BatchAppliedGui 记录并落盘，这里跳过，避免重复写盘与重复日志。
    if (-not $useIncremental) {
        $unmergedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($c in $unmerged) { [void]$unmergedSet.Add($c.CommitId) }
        $newly = New-Object System.Collections.ArrayList
        foreach ($c in $m.AllCommits) {
            $id = $c.CommitId
            if ($unmergedSet.Contains($id)) { continue }
            if ($m.SkippedIds.Contains($id)) { continue }
            if ($m.RecordedIds.Contains($id)) { continue }
            [void]$newly.Add($c)
        }
        foreach ($c in $newly) {
            [void]$m.RecordedIds.Add($c.CommitId)
            [void]$allApplied.Add($c.CommitId)
            $demands = $m.CommitDemandMap[$c.CommitId]
            if ($null -eq $demands) { $demands = @() }
            foreach ($dem in $demands) {
                if (-not $m.AppliedMap.ContainsKey($dem)) { $m.AppliedMap[$dem] = New-Object System.Collections.ArrayList }
                $dup = $false
                foreach ($ex in $m.AppliedMap[$dem]) {
                    if ([string]::Equals($ex.commitId, $c.CommitId, [StringComparison]::OrdinalIgnoreCase)) { $dup = $true; break }
                }
                if (-not $dup) { [void]$m.AppliedMap[$dem].Add([ordered]@{ commitText = $c.CommitText; commitId = $c.CommitId }) }
            }
        }
        if ($newly.Count -gt 0) {
            Save-AppliedMap -AppliedFile $m.AppliedFile -Map $m.AppliedMap
            Add-Log ("已记录 {0} 条新合并提交到已合清单。" -f $newly.Count) ([System.Drawing.Color]::Green)
        }
    }

    # 把"被跳过"的提交也持久化进已合清单（统一走 Save-SkippedIdsGui，E 退出时也会复用）
    Save-SkippedIdsGui

    # 计算待合并（排除已跳过/已合）
    $m.Pending = New-Object System.Collections.ArrayList
    foreach ($c in $unmerged) {
        if ($m.SkippedIds.Contains($c.CommitId)) { continue }
        if ($m.MergedIds.Contains($c.CommitId)) { continue }
        if ($allApplied.Contains($c.CommitId)) { continue }
        [void]$m.Pending.Add($c)
    }

    if ($m.Pending.Count -eq 0) {
        if ($m.DidPick) {
            Add-Log '所有选中提交已合并完成。' ([System.Drawing.Color]::Green)
        }
        else {
            Add-Log '所有选中提交均已合并过，无需执行 cherry-pick。' ([System.Drawing.Color]::Green)
        }
        # 无论本次是否实际执行过 cherry-pick，合并流程结束后都询问是否推送
        Merge-PushPrompt
        return
    }

    Merge-PickBatch
}

function Merge-PickBatch {
    $m = $script:merge
    if ($m.Pending.Count -eq 0) { Merge-ReVerify; return }
    $batchIds = @($m.Pending | Select-Object -First 100 | ForEach-Object { $_.CommitId })
    # 记录本批提交，供冲突解决后显式标记为已合并（见 Mark-BatchAppliedGui）
    $m.CurrentBatchIds = $batchIds
    Add-Log ("当前正在批量合并内容....（本批 {0} 条）" -f $batchIds.Count) ([System.Drawing.Color]::DarkCyan)
    # P2 改造：不再逐条打印（100 条会刷 100 行日志），只预览前 10 条
    $preview = @($batchIds | Select-Object -First 10 | ForEach-Object { $_.Substring(0, [Math]::Min(12, $_.Length)) })
    $tail = ''
    if ($batchIds.Count -gt 10) { $tail = " …… 等共 $($batchIds.Count) 条" }
    Add-Log ("  " + ($preview -join ', ') + $tail) ([System.Drawing.Color]::Gray)

    $args = @('cherry-pick') + $batchIds
    $r = Invoke-GitGui -RepoPath $m.Target -Arguments $args
    if ($r.ExitCode -eq 0) {
        Add-Log ("批量合并成功：$($batchIds.Count) 条提交。") ([System.Drawing.Color]::Green)
        $m.DidPick = $true
        # P1-1：退出码 0 表示本批全部应用，直接落盘已合清单；随后的校验因此可走增量路径（零 git 进程）
        Mark-BatchAppliedGui -StoppedId ''
        Merge-ReVerify -Incremental
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($r.Output)) { Add-Log $r.Output ([System.Drawing.Color]::DarkGoldenrod) }

    if (-not [string]::IsNullOrWhiteSpace((Get-CherryPickInProgressGui -RepoPath $m.Target))) {
        Merge-Conflict -PickOutput $r.Output
    }
    else {
        Merge-MergeFail -PickOutput $r.Output
    }
}

function Mark-BatchAppliedGui {
    # 冲突解决 / 批量成功后，把 sequencer 已应用的本批原始提交 id 显式记入"已合清单"并落盘。
    # 关键修复：不再只依赖 git cherry 的 patch-id 比对——冲突解决后内容与源提交常不一致，
    # git cherry 会把它判为"未合并"，导致下一轮重新校验又排进批次、再次 cherry-pick、再次冲突，陷入死循环。
    param([string]$StoppedId)
    $m = $script:merge
    if ($null -eq $m.CurrentBatchIds -or $m.CurrentBatchIds.Count -eq 0) { return }
    foreach ($bid in $m.CurrentBatchIds) {
        # sequencer 停在 StoppedId：其之后的提交尚未应用，停止标记
        if (-not [string]::IsNullOrWhiteSpace($StoppedId) -and ($bid -eq $StoppedId)) { break }
        # 被用户跳过的提交不应记为已合并
        if ($m.SkippedIds.Contains($bid)) { continue }
        if ($m.MergedIds.Contains($bid)) { continue }
        [void]$m.MergedIds.Add($bid)
        # 用哈希索引 O(1) 取提交对象（旧实现为 @($m.AllCommits | Where-Object {...})，O(N)）
        $c = $null
        if ($m.CommitIndex.ContainsKey($bid)) { $c = $m.CommitIndex[$bid] }
        if ($null -ne $c) {
            $demands = $m.CommitDemandMap[$bid]
            if ($null -eq $demands) { $demands = @() }
            foreach ($dem in $demands) {
                if (-not $m.AppliedMap.ContainsKey($dem)) { $m.AppliedMap[$dem] = New-Object System.Collections.ArrayList }
                $dup = $false
                foreach ($ex in $m.AppliedMap[$dem]) {
                    if ([string]::Equals($ex.commitId, $bid, [StringComparison]::OrdinalIgnoreCase)) { $dup = $true; break }
                }
                if (-not $dup) { [void]$m.AppliedMap[$dem].Add([ordered]@{ commitText = $c.CommitText; commitId = $bid }) }
            }
        }
    }
    Save-AppliedMap -AppliedFile $m.AppliedFile -Map $m.AppliedMap
}

function Save-SkippedIdsGui {
    # 把"被跳过"的提交持久化进已合清单，避免下次运行因缺少记录而重复尝试同一提交，
    # 陷入"冲突/空提交 -> 跳过 -> 不落盘 -> 再冲突"的死循环。
    # 用于：(1) 每轮重新校验时（见 Merge-ReVerify）；(2) 用户按 E 保留现场并退出时——
    # 此时序列仍在中途，若不打盘，跳过的提交下次重跑又会被当成未合并而再次冲突。
    $m = $script:merge
    if ($null -eq $m -or $null -eq $m.SkippedIds -or $m.SkippedIds.Count -eq 0) { return }
    $skipNewly = New-Object System.Collections.ArrayList
    foreach ($c in $m.AllCommits) {
        $id = $c.CommitId
        if (-not $m.SkippedIds.Contains($id)) { continue }
        if ($m.RecordedIds.Contains($id)) { continue }
        [void]$skipNewly.Add($c)
    }
    if ($skipNewly.Count -eq 0) { return }
    foreach ($c in $skipNewly) {
        [void]$m.RecordedIds.Add($c.CommitId)
        $demands = $m.CommitDemandMap[$c.CommitId]
        if ($null -eq $demands) { $demands = @() }
        foreach ($dem in $demands) {
            if (-not $m.AppliedMap.ContainsKey($dem)) { $m.AppliedMap[$dem] = New-Object System.Collections.ArrayList }
            $dup = $false
            foreach ($ex in $m.AppliedMap[$dem]) {
                if ([string]::Equals($ex.commitId, $c.CommitId, [StringComparison]::OrdinalIgnoreCase)) { $dup = $true; break }
            }
            if (-not $dup) { [void]$m.AppliedMap[$dem].Add([ordered]@{ commitText = $c.CommitText; commitId = $c.CommitId }) }
        }
    }
    Save-AppliedMap -AppliedFile $m.AppliedFile -Map $m.AppliedMap
    Add-Log ("已记录 {0} 条跳过提交到已合清单（避免重复尝试）。" -f $skipNewly.Count) ([System.Drawing.Color]::Yellow)
}

function Merge-Conflict {
    param([string]$PickOutput)
    $m = $script:merge
    $currentId = Get-CherryPickInProgressGui -RepoPath $m.Target
    $short = $currentId.Substring(0, [Math]::Min(12, $currentId.Length))
    Add-Log "提交 $short 发生冲突或产生空提交。" ([System.Drawing.Color]::DarkGoldenrod)
    Show-OperationPanel -Message "提交 $short 冲突/空提交。请在另一个终端解决冲突并执行 git add 后选择：" -Options @(
        @{Key='C'; Label='已处理，继续'},
        @{Key='S'; Label='跳过该提交'},
        @{Key='A'; Label='中止本次全部合并'},
        @{Key='E'; Label='保留现场并退出'}
    ) -NextAction {
        param($choice)
        $m = $script:merge
        $id = Get-CherryPickInProgressGui -RepoPath $m.Target
        switch ($choice) {
            'C' {
                $un = Invoke-GitGui -RepoPath $m.Target -Arguments @('diff','--name-only','--diff-filter=U')
                if ($un.ExitCode -eq 0 -and (-not [string]::IsNullOrWhiteSpace($un.Output))) {
                    Add-Log "仍存在未解决的冲突文件，请先处理并执行 git add 后再选 C：`n$($un.Output)" ([System.Drawing.Color]::DarkGoldenrod)
                    Merge-Conflict -PickOutput ''; return
                }
                $cont = Invoke-GitGui -RepoPath $m.Target -Arguments @('-c','core.editor=true','cherry-pick','--continue')
                if ($cont.ExitCode -ne 0) {
                    Add-Log $cont.Output ([System.Drawing.Color]::DarkGoldenrod)
                    $still = Get-CherryPickInProgressGui -RepoPath $m.Target
                    if (-not [string]::IsNullOrWhiteSpace($still)) {
                        # 区分空提交与仍有冲突，避免用户反复点 C 陷入死循环
                        $outLow = $cont.Output.ToLowerInvariant()
                        if ($outLow -match 'empty|空提交|nothing to commit|no changes') {
                            Add-Log '当前提交为空提交（变更可能已在目标分支中）。请选 S 跳过该提交，或在另一个终端执行 "git commit --allow-empty" 后再点 C。' ([System.Drawing.Color]::DarkGoldenrod)
                        }
                        else {
                            Add-Log 'cherry-pick --continue 失败，可能仍存在冲突。请确认已执行 git add 后再试。' ([System.Drawing.Color]::DarkGoldenrod)
                        }
                        Merge-Conflict -PickOutput $cont.Output; return
                    }
                    Merge-ReVerify; return
                }
                $stopped = Get-CherryPickInProgressGui -RepoPath $m.Target
                if ([string]::IsNullOrWhiteSpace($stopped)) {
                    # 整批评论均已应用：显式标记为已合并并落盘，避免依赖 git cherry 的 patch-id 比对
                    # （冲突解决后内容常与源提交不同，git cherry 会判定为"未合并"，从而反复重放同一提交）
                    Mark-BatchAppliedGui -StoppedId ''
                    $resolvedId = if ([string]::IsNullOrWhiteSpace($id)) { '（外部已处理）' } else { $id.Substring(0,12) }
                    Add-Log "冲突已解决，提交 $resolvedId 合并完成。" ([System.Drawing.Color]::Green)
                    Merge-ReVerify; return
                }
                Merge-Conflict -PickOutput ''; return
            }
            'S' {
                $skip = Invoke-GitGui -RepoPath $m.Target -Arguments @('cherry-pick','--skip')
                if ($skip.ExitCode -ne 0) {
                    Add-Log $skip.Output ([System.Drawing.Color]::DarkGoldenrod)
                    if ([string]::IsNullOrWhiteSpace((Get-CherryPickInProgressGui -RepoPath $m.Target))) { Merge-ReVerify; return }
                    Merge-Conflict -PickOutput ''; return
                }
                Add-Log "已跳过提交 $($id.Substring(0,12))。" ([System.Drawing.Color]::DarkGoldenrod)
                [void]$m.SkippedIds.Add($id)
                # --skip 后 sequencer 会自动继续；若停在下一处冲突应继续处理，而非直接重新校验
                if (-not [string]::IsNullOrWhiteSpace((Get-CherryPickInProgressGui -RepoPath $m.Target))) {
                    Merge-Conflict -PickOutput ''; return
                }
                Merge-ReVerify; return
            }
            'A' {
                $ab = Invoke-GitGui -RepoPath $m.Target -Arguments @('cherry-pick','--abort')
                if ($ab.ExitCode -ne 0) { Add-Log "中止失败：$($ab.Output)" ([System.Drawing.Color]::Red) }
                else { Add-Log '已中止本轮 cherry-pick，并恢复到合并前状态。' ([System.Drawing.Color]::DarkGoldenrod) }
                Merge-Finish '合并已中止'; return
            }
            'E' {
                Add-Log '脚本已退出，冲突现场被保留。' ([System.Drawing.Color]::DarkGoldenrod)
                # 序列仍可能中途进行：先把已跳过的提交落盘，避免下次重跑又冲突
                Save-SkippedIdsGui
                Merge-Finish '合并已退出（保留现场）'; return
            }
        }
    }
}

function Merge-MergeFail {
    param([string]$PickOutput)
    $m = $script:merge
    $failedId = ''
    if ($PickOutput -match 'commit\s+([0-9a-f]{40,})\s+is a merge') { $failedId = $Matches[1] }
    if (-not [string]::IsNullOrWhiteSpace($failedId)) {
        Add-Log "提交 $failedId 是合并提交（merge commit），直接 cherry-pick 需要指定 -m 参数。" ([System.Drawing.Color]::DarkGoldenrod)
        Show-OperationPanel -Message "提交 $failedId 为合并提交，请选择处理策略：" -Options @(
            @{Key='M'; Label='以 -m 1 合并该提交'},
            @{Key='S'; Label='跳过该提交'},
            @{Key='A'; Label='中止本次全部合并'},
            @{Key='E'; Label='保留现场并退出'}
        ) -NextAction {
            param($choice)
            $m = $script:merge
            if ($choice -eq 'M') {
                $retry = Invoke-GitGui -RepoPath $m.Target -Arguments @('cherry-pick','-m','1',$failedId)
                if ($retry.ExitCode -eq 0) {
                    Add-Log "以 -m 1 合并提交 $failedId 成功。" ([System.Drawing.Color]::Green)
                    [void]$m.MergedIds.Add($failedId)
                    Merge-ReVerify; return
                }
                Add-Log $retry.Output ([System.Drawing.Color]::DarkGoldenrod)
                if (-not [string]::IsNullOrWhiteSpace((Get-CherryPickInProgressGui -RepoPath $m.Target))) {
                    Merge-Conflict -PickOutput $retry.Output; return
                }
                Merge-ReVerify; return
            }
            if ($choice -eq 'S') {
                Add-Log "已跳过提交 $failedId。" ([System.Drawing.Color]::DarkGoldenrod)
                [void]$m.SkippedIds.Add($failedId)
                Merge-ReVerify; return
            }
            if ($choice -eq 'A') {
                $ab = Invoke-GitGui -RepoPath $m.Target -Arguments @('cherry-pick','--abort')
                if ($ab.ExitCode -ne 0) { Add-Log "中止失败：$($ab.Output)" ([System.Drawing.Color]::Red) }
                else { Add-Log '已中止本轮 cherry-pick。' ([System.Drawing.Color]::DarkGoldenrod) }
                Merge-Finish '合并已中止'; return
            }
            if ($choice -eq 'E') {
                Add-Log '脚本已退出，请检查目标仓库状态后手动处理。' ([System.Drawing.Color]::DarkGoldenrod)
                Merge-Finish '合并已退出'; return
            }
        }
    }
    else {
        Show-OperationPanel -Message '合并失败且未进入可继续的 cherry-pick 状态。请选择：' -Options @(
            @{Key='C'; Label='我已手动处理完成，继续'},
            @{Key='S'; Label='跳过该提交'},
            @{Key='A'; Label='中止本次全部合并'},
            @{Key='E'; Label='保留现场并退出'}
        ) -NextAction {
            param($choice)
            $m = $script:merge
            if ($choice -eq 'C') { Add-Log '已确认，继续后续步骤。' ([System.Drawing.Color]::DarkGoldenrod); Merge-ReVerify; return }
            if ($choice -eq 'S') {
                if ($m.Pending.Count -gt 0) {
                    $sid = $m.Pending[0].CommitId
                    Add-Log "已跳过提交 $($sid.Substring(0,12))。" ([System.Drawing.Color]::DarkGoldenrod)
                    [void]$m.SkippedIds.Add($sid)
                }
                Merge-ReVerify; return
            }
            if ($choice -eq 'A') {
                $ab = Invoke-GitGui -RepoPath $m.Target -Arguments @('cherry-pick','--abort')
                if ($ab.ExitCode -ne 0) { Add-Log "中止失败：$($ab.Output)" ([System.Drawing.Color]::Red) }
                else { Add-Log '已中止本轮 cherry-pick。' ([System.Drawing.Color]::DarkGoldenrod) }
                Merge-Finish '合并已中止'; return
            }
            if ($choice -eq 'E') { Add-Log '脚本已退出。' ([System.Drawing.Color]::DarkGoldenrod); Merge-Finish '合并已退出'; return }
        }
    }
}

function Merge-PushPrompt {
    $m = $script:merge
    Add-Log '内容合并已完成，是否执行 git push 推送？' ([System.Drawing.Color]::DarkCyan)
    Show-OperationPanel -Message "是否执行 git push 推送（分支：$($m.TargetBranch)）？" -Options @(
        @{Key='A'; Label='执行 git push 推送'},
        @{Key='B'; Label='结束程序，不推送'}
    ) -NextAction {
        param($choice)
        $m = $script:merge
        if ($choice -eq 'B') {
            Add-Log '程序结束，未执行 git push。请检查合并结果后自行推送。' ([System.Drawing.Color]::DarkGoldenrod)
            Merge-Finish '合并完成（未推送）'; return
        }
        # 确定推送目标
        $up = Invoke-GitGui -RepoPath $m.Target -Arguments @('rev-parse','--abbrev-ref','--symbolic-full-name','@{u}')
        $pushArgs = @()
        if ($up.ExitCode -eq 0) {
            Add-Log "检测到上游分支：$($up.Output.Trim())" ([System.Drawing.Color]::DarkCyan)
        }
        else {
            $rems = Invoke-GitGui -RepoPath $m.Target -Arguments @('remote')
            $remoteNames = @()
            if ($rems.ExitCode -eq 0) {
                $remoteNames = @($rems.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            }
            if ($remoteNames.Count -eq 0) {
                Add-Log '目标仓库未配置任何远程仓库，无法执行 push。' ([System.Drawing.Color]::DarkGoldenrod)
                Merge-Finish '合并完成（无远程，未推送）'; return
            }
            $remoteName = $remoteNames[0]
            Add-Log "目标分支未配置上游分支，将使用 $remoteName 做首次推送。" ([System.Drawing.Color]::DarkGoldenrod)
            $pushArgs = @('-u', $remoteName, $m.TargetBranch)
        }
        Merge-DoPush -PushArgs $pushArgs
    }
}

function Merge-DoPush {
    param([string[]]$PushArgs)
    $m = $script:merge
    Add-Log ("正在执行 git push（分支：$($m.TargetBranch)）...") ([System.Drawing.Color]::DarkCyan)
    $push = Invoke-GitGui -RepoPath $m.Target -Arguments (@('push') + $PushArgs)
    if ($push.ExitCode -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($push.Output)) { Add-Log $push.Output ([System.Drawing.Color]::Gray) }
        Add-Log "git push 成功，分支 $($m.TargetBranch) 已推送至远端。" ([System.Drawing.Color]::Green)
        Merge-Finish '合并完成并已推送'; return
    }
    Add-Log $push.Output ([System.Drawing.Color]::DarkGoldenrod)
    Add-Log 'git push 执行失败。' ([System.Drawing.Color]::DarkGoldenrod)
    Show-OperationPanel -Message 'git push 失败，请检查网络/凭据/远端状态后选择：' -Options @(
        @{Key='R'; Label='重试 push'},
        @{Key='B'; Label='结束程序，不推送'}
    ) -NextAction {
        param($choice)
        if ($choice -eq 'R') { Merge-DoPush -PushArgs $PushArgs; return }
        Add-Log '程序结束，未执行 git push。' ([System.Drawing.Color]::DarkGoldenrod)
        Merge-Finish '合并完成（未推送）'
    }
}

function Merge-Finish {
    param([string]$Message)
    Add-Log ("========== {0} ==========" -f $Message) ([System.Drawing.Color]::DarkCyan)
    Flush-Log
    Hide-OperationPanel
    $script:mergeBusy = $false
    Merge-EnableDemandButtons $true
    # 刷新需求列表的"是否合并"状态
    if (-not [string]::IsNullOrWhiteSpace($script:currentProject)) {
        $paths = Get-ProjectPaths -Key $script:currentProject
        Load-AppliedMap -AppliedFile $paths.AppliedFile
        Refresh-DemandList
    }
    $script:merge = $null
}

# =========================================================================
# 项目 CRUD 表单
# =========================================================================
function Show-ProjectForm {
    param([string]$EditKey = '')

    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($EditKey) { "修改项目 - $EditKey" } else { '新增项目' }
    $form.Size = New-Object System.Drawing.Size(560, 380)
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $y = 20
    $labelW = 200; $textW = 300; $x1 = 20; $x2 = 230

    $lblName = New-Object System.Windows.Forms.Label; $lblName.Text = '项目名称（必填）'; $lblName.Location = New-Object System.Drawing.Point($x1,$y); $lblName.Size = New-Object System.Drawing.Size($labelW,20); $form.Controls.Add($lblName)
    $txtName = New-Object System.Windows.Forms.TextBox; $txtName.Location = New-Object System.Drawing.Point($x2,$y); $txtName.Size = New-Object System.Drawing.Size($textW,20); $form.Controls.Add($txtName)

    $y += 36
    $lblBefore = New-Object System.Windows.Forms.Label; $lblBefore.Text = '合并前项目地址（必填）'; $lblBefore.Location = New-Object System.Drawing.Point($x1,$y); $lblBefore.Size = New-Object System.Drawing.Size($labelW,20); $form.Controls.Add($lblBefore)
    $txtBefore = New-Object System.Windows.Forms.TextBox; $txtBefore.Location = New-Object System.Drawing.Point($x2,$y); $txtBefore.Size = New-Object System.Drawing.Size($textW,20); $form.Controls.Add($txtBefore)

    $y += 36
    $lblBack = New-Object System.Windows.Forms.Label; $lblBack.Text = '合并后项目地址（必填）'; $lblBack.Location = New-Object System.Drawing.Point($x1,$y); $lblBack.Size = New-Object System.Drawing.Size($labelW,20); $form.Controls.Add($lblBack)
    $txtBack = New-Object System.Windows.Forms.TextBox; $txtBack.Location = New-Object System.Drawing.Point($x2,$y); $txtBack.Size = New-Object System.Drawing.Size($textW,20); $form.Controls.Add($txtBack)

    $y += 36
    $lblRec = New-Object System.Windows.Forms.Label; $lblRec.Text = '提交记录文件存放位置（可选）'; $lblRec.Location = New-Object System.Drawing.Point($x1,$y); $lblRec.Size = New-Object System.Drawing.Size($labelW,32); $form.Controls.Add($lblRec)
    $txtRec = New-Object System.Windows.Forms.TextBox; $txtRec.Location = New-Object System.Drawing.Point($x2,$y); $txtRec.Size = New-Object System.Drawing.Size($textW,20); $form.Controls.Add($txtRec)

    $y += 36
    $lblDem = New-Object System.Windows.Forms.Label; $lblDem.Text = '需求编号文件存放位置（可选）'; $lblDem.Location = New-Object System.Drawing.Point($x1,$y); $lblDem.Size = New-Object System.Drawing.Size($labelW,32); $form.Controls.Add($lblDem)
    $txtDem = New-Object System.Windows.Forms.TextBox; $txtDem.Location = New-Object System.Drawing.Point($x2,$y); $txtDem.Size = New-Object System.Drawing.Size($textW,20); $form.Controls.Add($txtDem)

    # 预填（修改）
    $defaultRec = ''
    $defaultDem = ''
    if ($EditKey) {
        $cfg = $script:warehouse[$EditKey]
        $txtName.Text    = $EditKey
        $txtName.Enabled = $false   # 项目名称不可改（改了就等于换 key）
        $txtBefore.Text  = [string]$cfg.beforeAddress
        $txtBack.Text    = [string]$cfg.backAddress
        if ($cfg.PSObject.Properties.Name -contains 'commitRecordAddress') { $txtRec.Text = [string]$cfg.commitRecordAddress }
        if (($cfg.PSObject.Properties.Name -contains 'commitTextSearchAddress')) { $txtDem.Text = [string]$cfg.commitTextSearchAddress }
        elseif (($cfg.PSObject.Properties.Name -contains 'commitTextAddress')) { $txtDem.Text = [string]$cfg.commitTextAddress }
    }

    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = '保存'; $btnSave.Location = New-Object System.Drawing.Point($x2,($y+34)); $btnSave.Size = New-Object System.Drawing.Size(90,28); $form.Controls.Add($btnSave)
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = '取消'; $btnCancel.Location = New-Object System.Drawing.Point(($x2+110),($y+34)); $btnCancel.Size = New-Object System.Drawing.Size(90,28); $form.Controls.Add($btnCancel)

    $btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })

    $btnSave.Add_Click({
        $name = $txtName.Text.Trim()
        $before = Format-UserPath $txtBefore.Text
        $back   = Format-UserPath $txtBack.Text
        $rec    = Format-UserPath $txtRec.Text
        $dem    = Format-UserPath $txtDem.Text

        if ([string]::IsNullOrWhiteSpace($name)) {
            [System.Windows.Forms.MessageBox]::Show('项目名称不能为空。', '校验失败', 'OK', 'Warning'); return
        }
        if ([string]::IsNullOrWhiteSpace($before)) {
            [System.Windows.Forms.MessageBox]::Show('合并前项目地址不能为空。', '校验失败', 'OK', 'Warning'); return
        }
        if ([string]::IsNullOrWhiteSpace($back)) {
            [System.Windows.Forms.MessageBox]::Show('合并后项目地址不能为空。', '校验失败', 'OK', 'Warning'); return
        }

        # 唯一性校验（修改自身时除外）
        if (-not $EditKey) {
            if ($script:warehouse.ContainsKey($name)) {
                [System.Windows.Forms.MessageBox]::Show("项目名称 [$name] 已存在，请使用其他名称。", '校验失败', 'OK', 'Warning'); return
            }
        }

        # 默认值（可选字段留空时按规则自动生成）
        if ([string]::IsNullOrWhiteSpace($rec)) { $rec = "gitCommitRecord/$name/" }
        if ([string]::IsNullOrWhiteSpace($dem)) { $dem = "commitTextSearch/$name/gitCommitText.json" }

        $obj = New-Object PSObject
        $obj | Add-Member -MemberType NoteProperty -Name 'beforeAddress'         -Value $before
        $obj | Add-Member -MemberType NoteProperty -Name 'backAddress'           -Value $back
        $obj | Add-Member -MemberType NoteProperty -Name 'commitRecordAddress'   -Value $rec
        $obj | Add-Member -MemberType NoteProperty -Name 'commitTextSearchAddress' -Value $dem

        if ($EditKey) {
            $script:warehouse[$EditKey] = $obj
        }
        else {
            $script:warehouse[$name] = $obj
            [void]$script:projectOrder.Add($name)
            # 创建需求编号文件与记录目录，避免后续报错
            try {
                $demPath = ResolvePathGui $dem
                $demDir  = Split-Path $demPath -Parent
                if (-not (Test-Path -LiteralPath $demDir -PathType Container)) { [void](New-Item -ItemType Directory -Path $demDir -Force) }
                if (-not (Test-Path -LiteralPath $demPath -PathType Leaf)) { Write-JsonFile -Path $demPath -Object @() }
                $recDir = ResolvePathGui $rec
                if (-not (Test-Path -LiteralPath $recDir -PathType Container)) { [void](New-Item -ItemType Directory -Path $recDir -Force) }
            }
            catch { }
        }
        Save-Warehouse
        Refresh-ProjectList
        Add-LogNow ("已保存项目配置：{0}" -f $name) ([System.Drawing.Color]::Green)
        $form.DialogResult = 'OK'; $form.Close()
    })

    [void]$form.ShowDialog()
}

function Delete-Projects {
    param([System.Collections.ArrayList]$Keys)
    if ($Keys.Count -eq 0) { return }
    $names = ($Keys -join "`n")
    $r = [System.Windows.Forms.MessageBox]::Show(
        "确认删除以下项目？删除后将同步清理其提交记录与需求记录，此操作不可恢复：`n`n$names",
        '二次确认 - 删除项目', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }

    foreach ($key in $Keys) {
        # 清理需求文件 + 提交记录目录：按项目配置的实际路径清理（自定义路径 + 默认路径都覆盖）
        try {
            $cfg = $script:warehouse[$key]
            $paths = Get-ProjectPaths -Key $key
            if (Test-Path -LiteralPath $paths.DemandFile) { Remove-Item -LiteralPath $paths.DemandFile -Force }
            $demDir = Split-Path -Path $paths.DemandFile -Parent
            # 向上递归清理空目录，直到 gitCommitRecord\<key>/ 或 commitTextSearch\<key>/ 的父目录
            $cfgProps = @($cfg.PSObject.Properties.Name)
            $recRootDefault = Join-Path $script:scriptRoot ("gitCommitRecord\" + $key)
            $ctsRootDefault = Join-Path $script:scriptRoot ("commitTextSearch\" + $key)
            # 自定义路径：删除整个目录
            if (Test-Path -LiteralPath $paths.RecordDir -PathType Container) {
                if ($paths.RecordDir -ine $recRootDefault) {
                    # 自定义记录目录（不在默认位置）：整目录删除
                    Remove-Item -LiteralPath $paths.RecordDir -Recurse -Force
                }
            }
            # 默认 commitTextSearch\<key> 目录：仅当需求文件不在自定义路径时才清理
            if ($paths.DemandFile -ine (Join-Path $ctsRootDefault 'gitCommitText.json')) {
                # 需求文件是自定义路径，不动默认目录
            }
            elseif (Test-Path -LiteralPath $ctsRootDefault) {
                Remove-Item -LiteralPath $ctsRootDefault -Recurse -Force
            }
            # 默认 gitCommitRecord\<key> 目录（仅当未在上面自定义删除时清理）
            if ($paths.RecordDir -ine $recRootDefault) {
                # 已在上面删过自定义，跳过
            }
            elseif (Test-Path -LiteralPath $recRootDefault) {
                Remove-Item -LiteralPath $recRootDefault -Recurse -Force
            }
            # 记录目录根目录下以项目名前缀命名的历史文件（如 <key>_<demand>.json）
            $recRoot = Join-Path $script:scriptRoot 'gitCommitRecord'
            if (Test-Path -LiteralPath $recRoot -PathType Container) {
                foreach ($f in (Get-ChildItem -LiteralPath $recRoot -File -Filter "${key}_*.json" -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $f.FullName -Force
                }
            }
        }
        catch {
            $errMsg = "清理项目 [$key] 的记录时发生错误：$($_.Exception.Message)`r`n堆栈：$($_.ScriptStackTrace)"
            Add-LogNow $errMsg ([System.Drawing.Color]::Red)
        }
        # 从内存与顺序表移除
        $script:warehouse.Remove($key)
        [void]$script:projectOrder.Remove($key)
        Add-LogNow ("已删除项目：$key") ([System.Drawing.Color]::Green)
    }
    Save-Warehouse
    Refresh-ProjectList
    if ($script:currentProject -in $Keys) { Select-Project -Key '' }
}

# =========================================================================
# 需求编号管理
# =========================================================================
function Show-DemandInputDialog {
    param([string]$Title, [string]$DefaultText = '')
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size(420, 320)
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = '每行代表一个需求编号，可批量录入：'
    $lbl.Location = New-Object System.Drawing.Point(15,15); $lbl.Size = New-Object System.Drawing.Size(380,20)
    $form.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true; $txt.ScrollBars = 'Vertical'
    $txt.Location = New-Object System.Drawing.Point(15,40); $txt.Size = New-Object System.Drawing.Size(380,200)
    $txt.Text = $DefaultText
    $form.Controls.Add($txt)

    $btnOk = New-Object System.Windows.Forms.Button; $btnOk.Text = '确定'; $btnOk.Location = New-Object System.Drawing.Point(215,255); $btnOk.Size = New-Object System.Drawing.Size(90,28); $form.Controls.Add($btnOk)
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = '取消'; $btnCancel.Location = New-Object System.Drawing.Point(310,255); $btnCancel.Size = New-Object System.Drawing.Size(90,28); $form.Controls.Add($btnCancel)

    $btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })
    $btnOk.Add_Click({ $form.DialogResult = 'OK'; $form.Close() })

    if ($form.ShowDialog() -eq 'OK') {
        return @($txt.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    return $null
}

function Demand-OverwriteAdd {
    # 覆盖新增：直接覆盖 gitCommitText.json
    $key = $script:currentProject
    if ([string]::IsNullOrWhiteSpace($key)) { [System.Windows.Forms.MessageBox]::Show('请先选择项目。','提示','OK','Information'); return }
    $paths = Get-ProjectPaths -Key $key
    $input = Show-DemandInputDialog -Title '覆盖新增需求编号'
    if ($null -eq $input) { return }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $arr = New-Object System.Collections.ArrayList
    $dup = 0
    foreach ($d in $input) {
        if ($seen.Add($d)) { $o = New-Object PSObject; $o | Add-Member -MemberType NoteProperty -Name 'commitText' -Value $d; [void]$arr.Add($o) }
        else { $dup++ }
    }
    Write-JsonFile -Path $paths.DemandFile -Object $arr
    Add-LogNow ("已覆盖写入 {0} 条需求编号（忽略重复 {1} 条）到 {2}" -f $arr.Count, $dup, $paths.DemandFile) ([System.Drawing.Color]::Green)
    Refresh-DemandList
}

function Demand-PlainAdd {
    # 单纯新增：向 gitCommitText.json 追加（已存在的不再录入）
    $key = $script:currentProject
    if ([string]::IsNullOrWhiteSpace($key)) { [System.Windows.Forms.MessageBox]::Show('请先选择项目。','提示','OK','Information'); return }
    $paths = Get-ProjectPaths -Key $key
    $input = Show-DemandInputDialog -Title '新增需求编号'
    if ($null -eq $input) { return }

    $existing = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $arr = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $paths.DemandFile -PathType Leaf) {
        foreach ($e in @(Read-JsonFile -Path $paths.DemandFile -Description '需求文件')) {
            if ($null -eq $e -or $null -eq $e.commitText) { continue }
            $t = ([string]$e.commitText).Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            [void]$existing.Add($t)
            $o = New-Object PSObject; $o | Add-Member -MemberType NoteProperty -Name 'commitText' -Value $t; [void]$arr.Add($o)
        }
    }
    $added = 0; $skipped = 0
    foreach ($d in $input) {
        if ($existing.Contains($d)) { $skipped++; continue }
        [void]$existing.Add($d)
        $o = New-Object PSObject; $o | Add-Member -MemberType NoteProperty -Name 'commitText' -Value $d; [void]$arr.Add($o)
        $added++
    }
    Write-JsonFile -Path $paths.DemandFile -Object $arr
    Add-LogNow ("已新增 {0} 条需求编号，已存在跳过 {1} 条。" -f $added, $skipped) ([System.Drawing.Color]::Green)
    Refresh-DemandList
}

function Demand-Delete {
    $key = $script:currentProject
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    $sel = @($ui.DemandList.SelectedItems)
    if ($sel.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('请选择要删除的需求编号。','提示','OK','Information'); return }
    $names = ($sel | ForEach-Object { $_.SubItems[1].Text }) -join "`n"
    $r = [System.Windows.Forms.MessageBox]::Show("确认删除以下需求编号？`n`n$names", '二次确认 - 删除需求', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $toRemove = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($it in $sel) { [void]$toRemove.Add($it.SubItems[1].Text) }

    $paths = Get-ProjectPaths -Key $key
    $arr = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $paths.DemandFile -PathType Leaf) {
        foreach ($e in @(Read-JsonFile -Path $paths.DemandFile -Description '需求文件')) {
            if ($null -eq $e -or $null -eq $e.commitText) { continue }
            $t = ([string]$e.commitText).Trim()
            if ($toRemove.Contains($t)) { continue }
            $o = New-Object PSObject; $o | Add-Member -MemberType NoteProperty -Name 'commitText' -Value $t; [void]$arr.Add($o)
        }
    }
    Write-JsonFile -Path $paths.DemandFile -Object $arr
    Add-LogNow ("已删除 {0} 条需求编号。" -f $toRemove.Count) ([System.Drawing.Color]::Green)
    Refresh-DemandList
}

function Demand-ToggleStatus {
    $key = $script:currentProject
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    $sel = @($ui.DemandList.SelectedItems)
    if ($sel.Count -ne 1) { [System.Windows.Forms.MessageBox]::Show('请选中一个需求编号进行状态切换。','提示','OK','Information'); return }
    $dn = $sel[0].SubItems[1].Text
    $current = $sel[0].SubItems[2].Text

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "切换合并状态 - $dn"
    $form.Size = New-Object System.Drawing.Size(320, 180)
    $form.StartPosition = 'CenterParent'; $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "当前状态：$current`n将该需求标记为："
    $lbl.Location = New-Object System.Drawing.Point(15,15); $lbl.Size = New-Object System.Drawing.Size(280,40)
    $form.Controls.Add($lbl)

    $rbMerged = New-Object System.Windows.Forms.RadioButton; $rbMerged.Text = '已合并'; $rbMerged.Location = New-Object System.Drawing.Point(20,65); $rbMerged.Size = New-Object System.Drawing.Size(120,20); $form.Controls.Add($rbMerged)
    $rbUnmerged = New-Object System.Windows.Forms.RadioButton; $rbUnmerged.Text = '未合并'; $rbUnmerged.Location = New-Object System.Drawing.Point(150,65); $rbUnmerged.Size = New-Object System.Drawing.Size(120,20); $form.Controls.Add($rbUnmerged)
    if ($current -eq '已合并') { $rbMerged.Checked = $true } else { $rbUnmerged.Checked = $true }

    $btnOk = New-Object System.Windows.Forms.Button; $btnOk.Text = '确定'; $btnOk.Location = New-Object System.Drawing.Point(125,110); $btnOk.Size = New-Object System.Drawing.Size(80,28); $form.Controls.Add($btnOk)
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = '取消'; $btnCancel.Location = New-Object System.Drawing.Point(215,110); $btnCancel.Size = New-Object System.Drawing.Size(80,28); $form.Controls.Add($btnCancel)
    $btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })
    $btnOk.Add_Click({ $form.DialogResult = 'OK'; $form.Close() })

    if ($form.ShowDialog() -ne 'OK') { return }
    $target = if ($rbMerged.Checked) { '已合并' } else { '未合并' }
    if ($target -eq $current) { return }

    $r2 = [System.Windows.Forms.MessageBox]::Show("确认将需求 [$dn] 的状态切换为 [$target]？", '二次确认 - 切换状态', 'YesNo', 'Warning')
    if ($r2 -ne 'Yes') { return }

    $paths = Get-ProjectPaths -Key $key
    Load-AppliedMap -AppliedFile $paths.AppliedFile
    if ($target -eq '已合并') {
        # 依赖已有的提交记录文件（扫描/合并生成）来获取 commitId
        $safeDn = Get-SafeFileNamePartGui -Value $dn
        $recPath = Join-Path $paths.RecordDir ("{0}_{1}.json" -f (Get-SafeFileNamePartGui -Value $key), $safeDn)
        if (-not (Test-Path -LiteralPath $recPath -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show("该需求暂无提交记录文件，无法标记已合并。请先执行扫描或合并以生成记录。", '无法标记', 'OK', 'Warning')
            return
        }
        $rec = Read-JsonFile -Path $recPath -Description '提交记录'
        if (-not $script:appliedMap.ContainsKey($dn)) { $script:appliedMap[$dn] = New-Object System.Collections.ArrayList }
        foreach ($c in $rec.commitRecordList) {
            $cid = [string]$c.commitId
            if ([string]::IsNullOrWhiteSpace($cid)) { continue }
            $dup = $false
            foreach ($ex in $script:appliedMap[$dn]) { if ([string]::Equals($ex.commitId, $cid, [StringComparison]::OrdinalIgnoreCase)) { $dup = $true; break } }
            if (-not $dup) { [void]$script:appliedMap[$dn].Add([ordered]@{ commitText = [string]$c.commitText; commitId = $cid }) }
        }
    }
    else {
        if ($script:appliedMap.ContainsKey($dn)) { $script:appliedMap.Remove($dn) }
    }
    Save-AppliedMap -AppliedFile $paths.AppliedFile -Map $script:appliedMap
    Add-LogNow ("需求 [$dn] 状态已切换为 [$target]。") ([System.Drawing.Color]::Green)
    Refresh-DemandList
}

function Demand-View {
    $key = $script:currentProject
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    $sel = @($ui.DemandList.SelectedItems)
    if ($sel.Count -ne 1) { [System.Windows.Forms.MessageBox]::Show('请选中一个需求编号查看提交记录。','提示','OK','Information'); return }
    $dn = $sel[0].SubItems[1].Text
    $paths = Get-ProjectPaths -Key $key
    $safeDn = Get-SafeFileNamePartGui -Value $dn
    $recPath = Join-Path $paths.RecordDir ("{0}_{1}.json" -f (Get-SafeFileNamePartGui -Value $key), $safeDn)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "提交记录 - $dn"
    $form.Size = New-Object System.Drawing.Size(640, 420)
    $form.StartPosition = 'CenterParent'

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true
    $lv.Location = New-Object System.Drawing.Point(10,10); $lv.Size = New-Object System.Drawing.Size(610,360)
    $lv.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    [void]$lv.Columns.Add('commitText', 360); [void]$lv.Columns.Add('commitId', 140); [void]$lv.Columns.Add('commitTime', 100)
    $form.Controls.Add($lv)

    if (Test-Path -LiteralPath $recPath -PathType Leaf) {
        try {
            $rec = Read-JsonFile -Path $recPath -Description '提交记录'
            foreach ($c in $rec.commitRecordList) {
                # PowerShell 5.1 下用数组直接构造 ListViewItem 只会设置第一列，改用 SubItems.Add
                $it = New-Object System.Windows.Forms.ListViewItem ([string]$c.commitText)
                [void]$it.SubItems.Add([string]$c.commitId)
                [void]$it.SubItems.Add([string]$c.commitTime)
                [void]$lv.Items.Add($it)
            }
            if ($lv.Items.Count -eq 0) {
                $it = New-Object System.Windows.Forms.ListViewItem ('（暂无提交记录）')
                [void]$it.SubItems.Add(''); [void]$it.SubItems.Add('')
                [void]$lv.Items.Add($it)
            }
        }
        catch {
            $it = New-Object System.Windows.Forms.ListViewItem ('读取记录失败：' + $_.Exception.Message)
            [void]$it.SubItems.Add(''); [void]$it.SubItems.Add('')
            [void]$lv.Items.Add($it)
        }
    }
    else {
        $it = New-Object System.Windows.Forms.ListViewItem ('该需求暂无提交记录文件，请先执行扫描或合并。')
        [void]$it.SubItems.Add(''); [void]$it.SubItems.Add('')
        [void]$lv.Items.Add($it)
    }
    [void]$form.ShowDialog()
}

function Demand-MergeAll {
    $key = $script:currentProject
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    $paths = Get-ProjectPaths -Key $key
    if (-not (Test-Path -LiteralPath $paths.DemandFile -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show('该项目暂无需求编号文件。','提示','OK','Information'); return
    }
    $all = @()
    foreach ($e in @(Read-JsonFile -Path $paths.DemandFile -Description '需求文件')) {
        if ($null -eq $e -or $null -eq $e.commitText) { continue }
        $t = ([string]$e.commitText).Trim()
        if (-not [string]::IsNullOrWhiteSpace($t)) { $all += $t }
    }
    if ($all.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('列表中不存在需求编号，无法合并。','提示','OK','Information'); return
    }
    # 若所有需求都已合并（applied 清单中存在），不允许再次合并
    Load-AppliedMap -AppliedFile $paths.AppliedFile
    $unmergedDemands = @($all | Where-Object { -not ($script:appliedMap.ContainsKey($_) -and $script:appliedMap[$_].Count -gt 0) })
    if ($unmergedDemands.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('需求已全部合并完成，不允许再次合并。','提示','OK','Information'); return
    }
    Merge-Begin -DemandNos $unmergedDemands
}

function Demand-MergeSelected {
    $key = $script:currentProject
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    $sel = @($ui.DemandList.SelectedItems)
    $unmerged = @($sel | Where-Object { $_.SubItems[2].Text -ne '已合并' } | ForEach-Object { $_.SubItems[1].Text })
    if ($unmerged.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请选择未合并的需求编号进行合并。','提示','OK','Information'); return
    }
    Merge-Begin -DemandNos $unmerged
}

# =========================================================================
# 主窗体构建
# =========================================================================
function Build-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Git Cherry-Pick 需求合并工具 - 可视化操作界面'
    $form.Size = New-Object System.Drawing.Size(1100, 720)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)

    # ---------- 顶部：全局操作按钮 ----------
    # 注意：topPanel 必须在 mainSplit 之后 Add 到 Form。
    # WinForms Dock 布局按 Controls 集合逆序处理；若先 Add topPanel 再 Add mainSplit(Fill)，
    # mainSplit 会先占满整个客户区，导致其 Y=0、被 topPanel 覆盖，表现为左侧列表首行
    # / 右侧 GroupBox 标题被按钮区遮挡。参考 more_tool_manager.ps1:237-261 的
    # "完全手动 SetBounds" 思路，这里保留 SplitContainer 但修正 Dock 添加顺序。
    $topPanel = New-Object System.Windows.Forms.Panel
    $topPanel.Dock = 'Top'; $topPanel.Height = 50; $topPanel.BackColor = [System.Drawing.Color]::FromArgb(240,240,245)

    $btnAddProject = New-Object System.Windows.Forms.Button; $btnAddProject.Text = '新增项目'; $btnAddProject.Location = New-Object System.Drawing.Point(15,10); $btnAddProject.Size = New-Object System.Drawing.Size(110,30); $topPanel.Controls.Add($btnAddProject)
    $btnEditProject = New-Object System.Windows.Forms.Button; $btnEditProject.Text = '修改项目'; $btnEditProject.Location = New-Object System.Drawing.Point(140,10); $btnEditProject.Size = New-Object System.Drawing.Size(110,30); $topPanel.Controls.Add($btnEditProject)
    $btnDeleteProject = New-Object System.Windows.Forms.Button; $btnDeleteProject.Text = '删除项目'; $btnDeleteProject.Location = New-Object System.Drawing.Point(265,10); $btnDeleteProject.Size = New-Object System.Drawing.Size(110,30); $topPanel.Controls.Add($btnDeleteProject)
    $lblTitle = New-Object System.Windows.Forms.Label; $lblTitle.Text = '项目配置（warehouse.json）'; $lblTitle.Location = New-Object System.Drawing.Point(420,16); $lblTitle.Size = New-Object System.Drawing.Size(300,20); $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold); $topPanel.Controls.Add($lblTitle)

    # ---------- 主区域：左(项目列表) / 右(两栏) ----------
    $mainSplit = New-Object System.Windows.Forms.SplitContainer
    $mainSplit.Dock = 'Fill'
    $mainSplit.Orientation = 'Vertical'
    $form.Controls.Add($mainSplit)
    # SplitterDistance 必须在 Add 到父容器之后设置：
    # 若先于 Add 设置，控件默认 Width=150，SplitterDistance=250 会被截断为 ~121；
    # 之后 Dock=Fill 触发 Layout 时 WinForms 会按比例重新分配 Panel，SplitterDistance 实际变成 ~874，
    # 导致 Panel1 占满、Panel2 极窄（界面错位的根因）。
    $mainSplit.SplitterDistance = 250

    # 关键：topPanel 在 mainSplit 之后 Add，确保 Dock=Top 优先于 Dock=Fill 布局，
    # 使 mainSplit 从 Y=50 开始而非覆盖整个客户区。
    $form.Controls.Add($topPanel)
    $form.Controls.SetChildIndex($topPanel, 1)

    # 左侧：项目列表（参考 more_tool_manager.ps1:237-261 的布局方式）
    # 教训：PS 5.1 WinForms 下 Dock=Fill 多层嵌套（SplitContainer→GroupBox→ListBox）
    #       偶发失效，导致 ListBox 高度异常、首行被裁 / 首屏不渲染
    #       （表现为 warehouse.json 第 1 个项目"消失"、GroupBox 标题被列表覆盖）。
    #       弃用 GroupBox + Dock，改用 leftPanel 内手动 SetBounds + Layout 事件同步。
    $leftPanel = $mainSplit.Panel1
    $leftPanel.Padding = New-Object System.Windows.Forms.Padding(6)
    $leftPanel.BackColor = [System.Drawing.Color]::FromArgb(245,245,250)

    $lblProjects = New-Object System.Windows.Forms.Label
    $lblProjects.Text = '项目列表（点击查看详情，可多选删除）'
    $lblProjects.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)
    $lblProjects.ForeColor = [System.Drawing.Color]::DimGray
    $leftPanel.Controls.Add($lblProjects)

    $projectList = New-Object System.Windows.Forms.ListBox
    $projectList.SelectionMode = 'MultiExtended'
    $projectList.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10)
    # 参考 more_tool_manager.ps1:259-260：IntegralHeight=False 避免 ListBox
    # 按整行高度自动取整导致首屏不绘制 / 首行被裁。
    $projectList.IntegralHeight = $false
    $projectList.BorderStyle = 'FixedSingle'; $projectList.BackColor = [System.Drawing.Color]::White
    $leftPanel.Controls.Add($projectList)

    # 手动布局同步（参考 more_tool_manager.ps1:328）：创建时立即执行一次，避免依赖
    # Add_Layout 首次触发；同时挂接到 Layout 事件，在窗体缩放/拖动分隔条时保持同步。
    $syncProjectList = {
        $w = $leftPanel.ClientSize.Width
        $h = $leftPanel.ClientSize.Height
        if ($w -lt 10 -or $h -lt 10) { return }
        $lblProjects.SetBounds(2, 2, $w - 4, 20)
        # 标题下方留 8px 间距，防止 ListBox 首行与按钮区/标题区紧贴或被遮挡
        $projectList.SetBounds(2, 30, $w - 4, $h - 34)
    }.GetNewClosure()
    & $syncProjectList
    $leftPanel.Add_Layout($syncProjectList)

    # 右侧：再拆分为左右两栏（左栏需求，右栏执行；给执行区更大空间）
    $rightSplit = New-Object System.Windows.Forms.SplitContainer
    $rightSplit.Dock = 'Fill'
    $rightSplit.Orientation = 'Vertical'
    $mainSplit.Panel2.Controls.Add($rightSplit)
    # 同上：SplitterDistance 在 Add 后设置，避免按比例重算
    $rightSplit.SplitterDistance = 420

    # 右-左栏：项目信息 + 需求操作 + 需求列表
    # 使用 TableLayoutPanel 替代混合 Dock=Top+Fill，避免 WinForms Dock 竞争导致 ListView 被遮挡或行不渲染。
    $rlPanel = $rightSplit.Panel1
    $rlTable = New-Object System.Windows.Forms.TableLayoutPanel
    $rlTable.Dock = 'Fill'
    $rlTable.RowCount = 4
    $rlTable.ColumnCount = 1
    [void]$rlTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 90)))   # 项目信息
    [void]$rlTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))       # 操作按钮
    [void]$rlTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))   # 列表标题
    [void]$rlTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))   # 需求列表（占据剩余全部空间）
    $rlPanel.Controls.Add($rlTable)

    $projectInfoLabel = New-Object System.Windows.Forms.Label
    $projectInfoLabel.Text = '未选择项目'; $projectInfoLabel.Dock = 'Fill'
    $projectInfoLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9); $projectInfoLabel.BackColor = [System.Drawing.Color]::FromArgb(245,245,250)
    [void]$rlTable.Controls.Add($projectInfoLabel, 0, 0)

    $opBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $opBtnPanel.Dock = 'Fill'; $opBtnPanel.Height = 80; $opBtnPanel.FlowDirection = 'LeftToRight'; $opBtnPanel.WrapContents = $true; $opBtnPanel.AutoSize = $true
    [void]$rlTable.Controls.Add($opBtnPanel, 0, 1)

    $btnOverwriteAdd = New-Object System.Windows.Forms.Button; $btnOverwriteAdd.Text = '覆盖新增'; $btnOverwriteAdd.Size = New-Object System.Drawing.Size(75,28); $opBtnPanel.Controls.Add($btnOverwriteAdd)
    $btnAddDemand = New-Object System.Windows.Forms.Button; $btnAddDemand.Text = '新增'; $btnAddDemand.Size = New-Object System.Drawing.Size(75,28); $opBtnPanel.Controls.Add($btnAddDemand)
    $btnDelDemand = New-Object System.Windows.Forms.Button; $btnDelDemand.Text = '删除'; $btnDelDemand.Size = New-Object System.Drawing.Size(75,28); $opBtnPanel.Controls.Add($btnDelDemand)
    $btnToggleStatus = New-Object System.Windows.Forms.Button; $btnToggleStatus.Text = '切换状态'; $btnToggleStatus.Size = New-Object System.Drawing.Size(75,28); $opBtnPanel.Controls.Add($btnToggleStatus)
    $btnView = New-Object System.Windows.Forms.Button; $btnView.Text = '查看'; $btnView.Size = New-Object System.Drawing.Size(75,28); $opBtnPanel.Controls.Add($btnView)
    $btnMergeAll = New-Object System.Windows.Forms.Button; $btnMergeAll.Text = '全部合并'; $btnMergeAll.Size = New-Object System.Drawing.Size(75,28); $btnMergeAll.BackColor = [System.Drawing.Color]::LightGreen; $opBtnPanel.Controls.Add($btnMergeAll)
    $btnMerge = New-Object System.Windows.Forms.Button; $btnMerge.Text = '合并'; $btnMerge.Size = New-Object System.Drawing.Size(75,28); $btnMerge.BackColor = [System.Drawing.Color]::LightGreen; $opBtnPanel.Controls.Add($btnMerge)

    $lblDemand = New-Object System.Windows.Forms.Label; $lblDemand.Text = '需求编号列表（序号 / 需求编号 / 是否合并）'; $lblDemand.Dock = 'Fill'; $lblDemand.BackColor = [System.Drawing.Color]::LightYellow; $lblDemand.TextAlign = 'MiddleLeft'
    [void]$rlTable.Controls.Add($lblDemand, 0, 2)
    $demandList = New-Object System.Windows.Forms.ListView
    $demandList.Dock = 'Fill'; $demandList.View = 'Details'; $demandList.FullRowSelect = $true; $demandList.GridLines = $true; $demandList.MultiSelect = $true
    $demandList.BorderStyle = 'FixedSingle'; $demandList.BackColor = [System.Drawing.Color]::White
    $demandList.ForeColor = [System.Drawing.Color]::Black
    $demandList.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10)
    [void]$demandList.Columns.Add('序号', 50); [void]$demandList.Columns.Add('需求编号', 180); [void]$demandList.Columns.Add('是否合并', 80)
    [void]$rlTable.Controls.Add($demandList, 0, 3)

    # 右-右栏：脚本执行情况（日志） + 操作面板
    # 同样使用 TableLayoutPanel 避免 Dock=Top+Fill 混用导致的标题错位/内容被遮挡。
    $rrPanel = $rightSplit.Panel2
    $rrPanel.Padding = New-Object System.Windows.Forms.Padding(4)
    $rrTable = New-Object System.Windows.Forms.TableLayoutPanel
    $rrTable.Dock = 'Fill'
    $rrTable.RowCount = 3
    $rrTable.ColumnCount = 1
    [void]$rrTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))  # 标题
    [void]$rrTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))  # 日志框（占据剩余空间）
    [void]$rrTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 0)))    # 操作面板：初始隐藏，高度为0
    $rrPanel.Controls.Add($rrTable)

    $lblExec = New-Object System.Windows.Forms.Label; $lblExec.Text = '脚本执行情况'; $lblExec.Dock = 'Fill'; $lblExec.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9, [System.Drawing.FontStyle]::Bold); $lblExec.TextAlign = 'MiddleLeft'
    [void]$rrTable.Controls.Add($lblExec, 0, 0)

    $logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.Dock = 'Fill'; $logBox.Multiline = $true; $logBox.ScrollBars = 'Both'
    $logBox.ReadOnly = $true; $logBox.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9, [System.Drawing.FontStyle]::Regular)
    $logBox.BackColor = [System.Drawing.Color]::White; $logBox.ForeColor = [System.Drawing.Color]::Black
    $logBox.BorderStyle = 'FixedSingle'
    $logBox.Text = "可视化界面已启动。`r`n左侧选择项目，右侧管理需求并执行合并。`r`n"
    $logBox.SelectionStart = 0
    $logBox.ScrollToCaret()
    [void]$rrTable.Controls.Add($logBox, 0, 1)

    $opPanel = New-Object System.Windows.Forms.Panel
    $opPanel.Dock = 'Fill'; $opPanel.BorderStyle = 'FixedSingle'; $opPanel.BackColor = [System.Drawing.Color]::FromArgb(250,250,235); $opPanel.Visible = $false
    [void]$rrTable.Controls.Add($opPanel, 0, 2)

    $opLabel = New-Object System.Windows.Forms.Label; $opLabel.Text = '合并过程中需要操作时，选项将显示在此，选择后点击"确定"继续。'; $opLabel.Dock = 'Top'; $opLabel.Height = 48; $opLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9); $opPanel.Controls.Add($opLabel)
    $opFlow = New-Object System.Windows.Forms.FlowLayoutPanel; $opFlow.Dock = 'Top'; $opFlow.Height = 120; $opFlow.WrapContents = $true; $opFlow.AutoSize = $false; $opPanel.Controls.Add($opFlow)
    $opConfirm = New-Object System.Windows.Forms.Button; $opConfirm.Text = '确定'; $opConfirm.Dock = 'Bottom'; $opConfirm.Height = 32; $opConfirm.Enabled = $false; $opPanel.Controls.Add($opConfirm)

    # ---------- 事件绑定 ----------
    $btnAddProject.Add_Click({ Show-ProjectForm -EditKey '' })
    $btnEditProject.Add_Click({
        $sel = @($ui.ProjectList.SelectedItems | Where-Object { $null -ne $_ })
        if ($sel.Count -ne 1) { [System.Windows.Forms.MessageBox]::Show('请选择且仅选择一个项目进行修改。','提示','OK','Information'); return }
        Show-ProjectForm -EditKey $sel[0].ToString()
    })
    $btnDeleteProject.Add_Click({
        $sel = @($ui.ProjectList.SelectedItems | Where-Object { $null -ne $_ })
        if ($sel.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('请选择要删除的项目（可多选）。','提示','OK','Information'); return }
        Delete-Projects -Keys (@($sel | ForEach-Object { $_.ToString() }))
    })
    $projectList.Add_SelectedIndexChanged({
        # 防御：列表刷新（Items.Clear/重新 Add）期间 SelectedItems 可能包含 null 占位项，
        # 直接取 $sel[0].ToString() 会抛"不能对 Null 值表达式调用方法"。先过滤 null。
        # 使用 $ui.ProjectList 避免闭包在 PowerShell 5.1 中捕获局部变量异常。
        $sel = @($ui.ProjectList.SelectedItems | Where-Object { $null -ne $_ })
        if ($sel.Count -eq 1) { Select-Project -Key $sel[0].ToString() }
        elseif ($sel.Count -eq 0) { Select-Project -Key '' }
    })

    $btnOverwriteAdd.Add_Click({ Demand-OverwriteAdd })
    $btnAddDemand.Add_Click({ Demand-PlainAdd })
    $btnDelDemand.Add_Click({ Demand-Delete })
    $btnToggleStatus.Add_Click({ Demand-ToggleStatus })
    $btnView.Add_Click({ Demand-View })
    $btnMergeAll.Add_Click({ Demand-MergeAll })
    $btnMerge.Add_Click({ Demand-MergeSelected })

    $opConfirm.Add_Click({
        if ($null -eq $script:opSelected) { return }
        $next = $script:opNext
        $choice = $script:opSelected
        Hide-OperationPanel
        if ($next) { & $next $choice }
    })

    # 初始禁用需求操作按钮，待选择项目后启用
    foreach ($b in @($btnOverwriteAdd, $btnAddDemand, $btnDelDemand, $btnToggleStatus, $btnView, $btnMergeAll, $btnMerge)) { $b.Enabled = $false }

    # 保存句柄
    $ui.ProjectList      = $projectList
    $ui.SyncProjectList  = $syncProjectList
    $ui.ProjectInfoLabel = $projectInfoLabel
    $ui.DemandList       = $demandList
    $ui.LogBox           = $logBox
    $ui.RrTable          = $rrTable
    $ui.OpPanel          = $opPanel
    $ui.OpLabel          = $opLabel
    $ui.OpFlow           = $opFlow
    $ui.OpConfirm        = $opConfirm
    $ui.BtnOverwriteAdd  = $btnOverwriteAdd
    $ui.BtnAddDemand     = $btnAddDemand
    $ui.BtnDelDemand     = $btnDelDemand
    $ui.BtnToggleStatus  = $btnToggleStatus
    $ui.BtnView          = $btnView
    $ui.BtnMergeAll      = $btnMergeAll
    $ui.BtnMerge         = $btnMerge
    $ui.BtnAddProject    = $btnAddProject
    $ui.BtnEditProject   = $btnEditProject
    $ui.BtnDeleteProject = $btnDeleteProject

    return $form
}

# =========================================================================
# 入口
# =========================================================================
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

Load-Warehouse
$mainForm = [System.Windows.Forms.Form](Build-MainForm | Where-Object { $_ -is [System.Windows.Forms.Form] } | Select-Object -Last 1)
$mainForm.Add_Shown({
    # 参考 more_tool_manager（more_tool_manager.ps1:817-848）：
    # WinForms 控件在窗体首次显示前可能未完成最终布局，此时填充 Dock=Fill 的
    # ListBox 会出现首项/首屏不渲染的问题。将项目列表填充移到 Shown 事件
    # （布局完成后）执行，并在消息泵空闲后再强制刷新一次兜底。
    # 先强制同步一次左侧布局，确保 ListBox 在最终尺寸确定后再填充数据。
    try { & $ui.SyncProjectList } catch { }
    Refresh-ProjectList
    try {
        $ui.ProjectList.Refresh()
        $ui.ProjectList.Update()
    } catch { }
    # 额外保险：延迟 50ms 后再次强制刷新（给 WinForms 消息泵时间完成布局）
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 50
    $timer.Add_Tick({
        $timer.Stop()
        $timer.Dispose()
        $ui.ProjectList.Refresh()
        $ui.ProjectList.Update()
    }.GetNewClosure())
    $timer.Start()
    Add-LogNow '界面渲染完成，可以进行项目与需求管理。' ([System.Drawing.Color]::DarkGreen)
})
[System.Windows.Forms.Application]::Run($mainForm)
