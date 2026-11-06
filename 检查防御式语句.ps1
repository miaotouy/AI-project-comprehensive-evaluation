<#
.SYNOPSIS
    扫描项目调查笔记中的防御式语句与 AI 套话句式。

.DESCRIPTION
    用于新建或修订调查笔记后的自检审查。规则分两级：

      high   - 必须清零。预设立场的否定对比（不是…而是）、免责套话（不代表、不将、不意味着）、
               否定式小标题与表头、连续排比否定。
      medium - 建议复核。同族变体（而非、而不是、不表示、不构成）在技术笔记中常承担有效的
               排除性精确说明，需人工(智能)判断是否属于修辞性预设对比。默认不显示。

.EXAMPLE
    pwsh -NoProfile -File "项目调查笔记/检查防御式语句.ps1" -Paths "项目调查笔记/Agent工具/AIO-Hub-Agent工具调查笔记.md"

.EXAMPLE
    pwsh -NoProfile -File "项目调查笔记/检查防御式语句.ps1" -RecentMinutes 60

.EXAMPLE
    pwsh -NoProfile -File "项目调查笔记/检查防御式语句.ps1" -Paths "项目调查笔记/某笔记.md" -IncludeVariants

.EXAMPLE
    pwsh -NoProfile -File "项目调查笔记/检查防御式语句.ps1" -SummaryOnly
#>
param(
    [Parameter(Position = 0)]
    [string[]]$Paths,

    [int]$RecentMinutes = 0,

    [switch]$SummaryOnly,

    [switch]$IncludeVariants,

    [int]$MaxDetails = 200,

    [switch]$FailOnMatch
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$notesRoot = $PSScriptRoot
$workspaceRoot = Split-Path -Parent $notesRoot

$rules = @(
    [pscustomobject]@{
        Id       = '标题/结构防御词'
        Severity = 'high'
        Regex    = '^(?:\s*#+.*|\s*\|.*|\s*[-*]\s*\*\*[^*]+\*\*.*)(?:不等于|不等同于|不代表|不意味着|(?:不是|并非).*而是)'
        Advice   = '勿将否定词用作小标题、表头或加粗标签，改为正向维度名（如「职责边界」「适用范围与代价」）'
    }
    [pscustomobject]@{
        Id       = '不是…而是'
        Severity = 'high'
        Regex    = '(?:不是|并非|并不是|并不)[^。；\n]{1,60}?，?\s*而是'
        Advice   = '删去前置否定靶子，直接陈述「是 B」或分别说明两层职责'
    }
    [pscustomobject]@{
        Id       = '不将/并不将'
        Severity = 'high'
        Regex    = '(?:并不|不)将'
        Advice   = '删去作者自述式撇清，或改为正向范围说明（「本节仅记录 X」）'
    }
    [pscustomobject]@{
        Id       = '不代表'
        Severity = 'high'
        Regex    = '(?:并不|不)代表'
        Advice   = '删去静态调查免责尾巴，或改为「仅用于/仅作用于…」'
    }
    [pscustomobject]@{
        Id       = '不等于/不等同于'
        Severity = 'high'
        Regex    = '(?:并不|不)等(?:同)?于'
        Advice   = '改为正向职责边界说明（「A 仅负责 X，Y 由 B 承担」）'
    }
    [pscustomobject]@{
        Id       = '不意味着'
        Severity = 'high'
        Regex    = '(?:并不|不)意味着'
        Advice   = '直接说明生效条件、依赖配置或实际作用范围'
    }
    [pscustomobject]@{
        Id       = '不把…视为/外推'
        Severity = 'high'
        Regex    = '不把[^，。；\n]{1,35}?(?:视为|视作|当成|当作|等同|外推|推广|归入|归为|计入|解释为)'
        Advice   = '改为正向分类或直接说明归属边界'
    }
    [pscustomobject]@{
        Id       = '不能据此/仅凭'
        Severity = 'high'
        Regex    = '不能(?:据此|因此|仅凭|只凭)|无法据此'
        Advice   = '前半句已写「未找到」时直接删掉后半句；确需保留证据边界则改说「本次检查范围是…」「X 属于运行验证范围」'
    }
    [pscustomobject]@{
        Id       = '不应据此/不能直接推定'
        Severity = 'high'
        Regex    = '不应据此|不应由此推断|不能直接(?:推定|证明|代表|套用|横比|类比|推广|读作|充当|作为|当作)'
        Advice   = '改成「这几项能力另有指标」「覆盖率需另行测量」，把否定推断换成该看什么'
    }
    [pscustomobject]@{
        Id       = '不能概括/混为'
        Severity = 'high'
        Regex    = '不能(?:概括|混为|一概|笼统)'
        Advice   = '改成「X 只适用于 A 情形」，把被否定的过度概括补上适用条件'
    }
    [pscustomobject]@{
        Id       = '不能推断/外推'
        Severity = 'high'
        Regex    = '不能(?:简单|直接|自动)?(?:外推|推断|推导|等同|视为|认定|声称)'
        Advice   = '直接说明当前证据覆盖范围；若确实做过检索，改用「本次未找到」并写明检查范围'
    }
    [pscustomobject]@{
        Id       = '三连排比否定'
        Severity = 'high'
        Regex    = '不[^，、。；\n]{2,18}[、，]\s*不[^，、。；\n]{2,18}[、，]\s*(?:也)?不'
        Advice   = '避免排比罗列「不做什么」，改为说明实际承担的职责与单一关键边界'
    }
    [pscustomobject]@{
        Id       = '不表示'
        Severity = 'high'
        Regex    = '不表示'
        Advice   = '显式防御写法。后半句只是免责则删掉；承载实际信息则转成正向陈述或归位到负责的层级'
    }
    [pscustomobject]@{
        Id       = '而非/而不是'
        Severity = 'medium'
        Regex    = '而非|而不是'
        Advice   = '技术笔记中常用于排除邻近概念；若只是修辞性预设对比，改为直接陈述'
    }
    [pscustomobject]@{
        Id       = '不构成/不算/不应视为'
        Severity = 'medium'
        Regex    = '不(?:构成|算|应(?:视为|视作|当作))'
        Advice   = '确认该否定是否承载有效分类边界；若只是免责补述，改为正向说明'
    }
)

function Resolve-TargetFiles {
    $resolved = [System.Collections.Generic.List[string]]::new()

    if (-not $Paths -or $Paths.Count -eq 0) {
        foreach ($f in (Get-ChildItem -LiteralPath $notesRoot -Recurse -Filter '*.md' -File)) {
            $resolved.Add($f.FullName)
        }
    }
    else {
        foreach ($p in $Paths) {
            $candidates = @(
                $p,
                (Join-Path $workspaceRoot $p),
                (Join-Path $notesRoot $p)
            )
            $foundPath = $null
            foreach ($c in $candidates) {
                if (Test-Path -LiteralPath $c) {
                    $foundPath = (Resolve-Path -LiteralPath $c).Path
                    break
                }
            }
            if (-not $foundPath) {
                Write-Warning "未找到路径: $p"
                continue
            }
            $item = Get-Item -LiteralPath $foundPath
            if ($item.PSIsContainer) {
                foreach ($f in (Get-ChildItem -LiteralPath $foundPath -Recurse -Filter '*.md' -File)) {
                    $resolved.Add($f.FullName)
                }
            }
            elseif ($item.Extension -ieq '.md') {
                $resolved.Add($item.FullName)
            }
        }
    }

    $uniqueFiles = $resolved | Select-Object -Unique | ForEach-Object { Get-Item -LiteralPath $_ }
    if ($RecentMinutes -gt 0) {
        $cutoff = (Get-Date).AddMinutes(-$RecentMinutes)
        $uniqueFiles = $uniqueFiles | Where-Object { $_.LastWriteTime -ge $cutoff }
    }
    return @($uniqueFiles)
}

function Get-RelativeNotePath([string]$FullPath) {
    if ($FullPath.StartsWith($notesRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($notesRoot.Length).TrimStart('\', '/').Replace('\', '/')
    }
    if ($FullPath.StartsWith($workspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($workspaceRoot.Length).TrimStart('\', '/').Replace('\', '/')
    }
    return $FullPath.Replace('\', '/')
}

$activeRules = @($rules | Where-Object { $_.Severity -eq 'high' -or $IncludeVariants })

$targetFiles = Resolve-TargetFiles
if ($targetFiles.Count -eq 0) {
    Write-Output "未匹配到需要扫描的 Markdown 文件。"
    exit 0
}

$findings = [System.Collections.Generic.List[object]]::new()

foreach ($file in $targetFiles) {
    $relPath = Get-RelativeNotePath $file.FullName
    $isAgentsMd = ($relPath -ieq 'AGENTS.md')
    $lines = [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8)

    $inCodeBlock = $false
    $inExemptSection = $false

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        $lineNum = $i + 1

        if ($line -match '^\s*(```|~~~)') {
            $inCodeBlock = -not $inCodeBlock
            continue
        }
        if ($inCodeBlock) { continue }

        # AGENTS.md 自身的规范说明段落会引用这些句式作为反例或规则名，跳过避免自命中。
        if ($isAgentsMd) {
            if ($line -match '^###\s+(?:避免防御式与套话句式|施工与验收)') {
                $inExemptSection = $true
                continue
            }
            elseif ($inExemptSection -and $line -match '^#{2,3}\s+') {
                $inExemptSection = $false
            }
            if ($inExemptSection) { continue }
        }

        foreach ($rule in $activeRules) {
            $m = [regex]::Match($line, $rule.Regex)
            if ($m.Success) {
                $snippet = $m.Value.Trim()
                if ($snippet.Length -gt 48) {
                    $snippet = $snippet.Substring(0, 45) + '...'
                }
                $findings.Add([pscustomobject]@{
                    File     = $relPath
                    Line     = $lineNum
                    RuleId   = $rule.Id
                    Severity = $rule.Severity
                    Snippet  = $snippet
                    Advice   = $rule.Advice
                    Context  = $line.Trim()
                })
            }
        }
    }
}

$highFindings = @($findings | Where-Object { $_.Severity -eq 'high' })
$mediumFindings = @($findings | Where-Object { $_.Severity -eq 'medium' })

Write-Output "=== 防御式语句扫描结果 ==="
Write-Output ("扫描文件数   : {0}" -f $targetFiles.Count)
Write-Output ("必须清理(high): {0} 处，涉及 {1} 个文件" -f $highFindings.Count, (@($highFindings | Select-Object -ExpandProperty File -Unique)).Count)
if ($IncludeVariants) {
    Write-Output ("建议复核(medium): {0} 处，涉及 {1} 个文件" -f $mediumFindings.Count, (@($mediumFindings | Select-Object -ExpandProperty File -Unique)).Count)
}
else {
    Write-Output ("建议复核(medium): 未检测，加 -IncludeVariants 查看同族变体")
}

if ($findings.Count -eq 0) {
    Write-Output "未发现防御式语句。"
    exit 0
}

Write-Output "`n--- 按规则类别统计 ---"
foreach ($g in ($findings | Group-Object RuleId | Sort-Object { $_.Group[0].Severity }, Count -Descending)) {
    $sev = $g.Group[0].Severity
    $fc = (@($g.Group | Select-Object -ExpandProperty File -Unique)).Count
    Write-Output ("  [{0,-6}] {1,-18} : {2,4} 处 ({3} 个文件)" -f $sev, $g.Name, $g.Count, $fc)
}

if ($highFindings.Count -gt 0) {
    Write-Output "`n--- 按文件统计 (Top 25) ---"
    foreach ($g in ($highFindings | Group-Object File | Sort-Object Count -Descending | Select-Object -First 25)) {
        Write-Output ("  {0,3} 处 | {1}" -f $g.Count, $g.Name)
    }

    if (-not $SummaryOnly) {
        Write-Output "`n--- high 命中明细 ---"
        foreach ($item in ($highFindings | Select-Object -First $MaxDetails)) {
            Write-Output ("[{0}:{1}] 【{2}】 匹配: {3}" -f $item.File, $item.Line, $item.RuleId, $item.Snippet)
            Write-Output ("  原文: {0}" -f $item.Context)
            Write-Output ("  建议: {0}" -f $item.Advice)
        }
        if ($highFindings.Count -gt $MaxDetails) {
            Write-Output ("`n... 其余 {0} 处已省略（可通过 -MaxDetails 调大或传入 -Paths 指定单文件查看全部）" -f ($highFindings.Count - $MaxDetails))
        }
    }
}

if ($IncludeVariants -and $mediumFindings.Count -gt 0 -and -not $SummaryOnly) {
    $mediumShown = [Math]::Min($MaxDetails, 60)
    Write-Output "`n--- medium 命中明细（前 $mediumShown 条，建议逐条判断是否为有效技术对比）---"
    foreach ($item in ($mediumFindings | Select-Object -First $mediumShown)) {
        Write-Output ("[{0}:{1}] 【{2}】" -f $item.File, $item.Line, $item.RuleId)
        Write-Output ("  原文: {0}" -f $item.Context)
    }
}

if ($FailOnMatch -and $highFindings.Count -gt 0) {
    exit 1
}
