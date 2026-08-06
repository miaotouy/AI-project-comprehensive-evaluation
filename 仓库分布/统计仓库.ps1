param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string[]]$Projects,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$languageByExtension = [ordered]@{
    '.ts' = 'TypeScript'; '.tsx' = 'TypeScript'; '.mts' = 'TypeScript'; '.cts' = 'TypeScript'
    '.js' = 'JavaScript'; '.jsx' = 'JavaScript'; '.mjs' = 'JavaScript'; '.cjs' = 'JavaScript'
    '.vue' = 'Vue'; '.svelte' = 'Svelte'; '.astro' = 'Astro'
    '.py' = 'Python'; '.pyi' = 'Python'
    '.rs' = 'Rust'; '.go' = 'Go'
    '.java' = 'Java'; '.kt' = 'Kotlin'; '.kts' = 'Kotlin'
    '.swift' = 'Swift'; '.m' = 'Objective-C'; '.mm' = 'Objective-C++'
    '.c' = 'C'; '.h' = 'C/C++ Header'; '.cc' = 'C++'; '.cpp' = 'C++'; '.cxx' = 'C++'; '.hpp' = 'C/C++ Header'
    '.cs' = 'C#'; '.fs' = 'F#'; '.fsx' = 'F#'
    '.rb' = 'Ruby'; '.php' = 'PHP'; '.lua' = 'Lua'; '.dart' = 'Dart'
    '.sh' = 'Shell'; '.bash' = 'Shell'; '.zsh' = 'Shell'; '.fish' = 'Shell'; '.ps1' = 'PowerShell'
    '.html' = 'HTML'; '.htm' = 'HTML'; '.css' = 'CSS'; '.scss' = 'SCSS'; '.sass' = 'Sass'; '.less' = 'Less'; '.styl' = 'Stylus'
    '.sql' = 'SQL'; '.proto' = 'Protocol Buffers'; '.graphql' = 'GraphQL'; '.gql' = 'GraphQL'
}

$documentPattern = '(?i)\.(md|mdx|rst|adoc|asciidoc|txt)$'
$testPattern = '(?i)(^|/)(__tests__|tests?|specs?|e2e|integration-tests?|playwright|cypress)(/|$)|(^|/)[^/]+\.(test|spec)\.[^/]+$|(^|/)(test_[^/]+|[^/]+_test)\.py$'

function Get-LineCount([string]$Path) {
    $count = 0
    $reader = [System.IO.File]::OpenText($Path)
    try {
        while ($null -ne $reader.ReadLine()) { $count++ }
    }
    finally {
        $reader.Dispose()
    }
    return $count
}

function Convert-Groups($Table, [string]$NameProperty) {
    return @($Table.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{
            $NameProperty = $_.Key
            Files = $_.Value.Files
            Lines = $_.Value.Lines
            Bytes = $_.Value.Bytes
        }
    } | Sort-Object Lines, Files -Descending)
}

if (-not $Projects -or $Projects.Count -eq 0) {
    $Projects = @(Get-ChildItem -LiteralPath $WorkspaceRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
        Select-Object -ExpandProperty Name)
}

$results = foreach ($projectName in $Projects) {
    $projectRoot = Join-Path $WorkspaceRoot $projectName
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.git'))) {
        Write-Warning "Skipping non-Git directory: $projectRoot"
        continue
    }

    Push-Location $projectRoot
    try {
        $trackedFiles = @(git -c core.quotepath=false ls-files)
        $commit = (git rev-parse HEAD).Trim()
        $branch = (git branch --show-current).Trim()
    }
    finally {
        Pop-Location
    }

    $languages = @{}
    $topLevels = @{}
    $areas = @{}
    $docLocations = @{}
    $docAreas = @{}
    $testLocations = @{}
    $testAreas = @{}
    $totalBytes = 0L
    $sourceFiles = 0
    $sourceLines = 0L
    $documentFiles = 0
    $documentLines = 0L
    $testFiles = 0
    $testSourceLines = 0L

    foreach ($relativePath in $trackedFiles) {
        $normalizedPath = $relativePath.Replace('\', '/')
        $absolutePath = Join-Path $projectRoot $relativePath
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) { continue }

        $bytes = (Get-Item -LiteralPath $absolutePath).Length
        $totalBytes += $bytes
        $topLevel = if ($normalizedPath.Contains('/')) { $normalizedPath.Split('/')[0] } else { '(root)' }
        $pathParts = @($normalizedPath.Split('/'))
        $area = if ($pathParts.Count -ge 3) { "$($pathParts[0])/$($pathParts[1])" } elseif ($pathParts.Count -eq 2) { $pathParts[0] } else { '(root)' }
        if (-not $topLevels.ContainsKey($topLevel)) { $topLevels[$topLevel] = @{ Files = 0; Lines = 0L; Bytes = 0L } }
        $topLevels[$topLevel].Files++
        $topLevels[$topLevel].Bytes += $bytes
        if (-not $areas.ContainsKey($area)) { $areas[$area] = @{ Files = 0; Lines = 0L; Bytes = 0L } }
        $areas[$area].Files++
        $areas[$area].Bytes += $bytes

        $extension = [System.IO.Path]::GetExtension($relativePath).ToLowerInvariant()
        $language = $languageByExtension[$extension]
        $lineCount = $null
        if ($language) {
            try { $lineCount = Get-LineCount $absolutePath } catch { $lineCount = 0 }
            $sourceFiles++
            $sourceLines += $lineCount
            $topLevels[$topLevel].Lines += $lineCount
            $areas[$area].Lines += $lineCount
            if (-not $languages.ContainsKey($language)) { $languages[$language] = @{ Files = 0; Lines = 0L; Bytes = 0L } }
            $languages[$language].Files++
            $languages[$language].Lines += $lineCount
            $languages[$language].Bytes += $bytes
        }

        if ($normalizedPath -match $documentPattern) {
            if ($null -eq $lineCount) {
                try { $lineCount = Get-LineCount $absolutePath } catch { $lineCount = 0 }
            }
            $documentFiles++
            $documentLines += $lineCount
            if (-not $docLocations.ContainsKey($topLevel)) { $docLocations[$topLevel] = @{ Files = 0; Lines = 0L; Bytes = 0L } }
            $docLocations[$topLevel].Files++
            $docLocations[$topLevel].Lines += $lineCount
            $docLocations[$topLevel].Bytes += $bytes
            if (-not $docAreas.ContainsKey($area)) { $docAreas[$area] = @{ Files = 0; Lines = 0L; Bytes = 0L } }
            $docAreas[$area].Files++
            $docAreas[$area].Lines += $lineCount
            $docAreas[$area].Bytes += $bytes
        }

        if ($normalizedPath -match $testPattern) {
            $testFiles++
            if ($language) { $testSourceLines += $lineCount }
            if (-not $testLocations.ContainsKey($topLevel)) { $testLocations[$topLevel] = @{ Files = 0; Lines = 0L; Bytes = 0L } }
            $testLocations[$topLevel].Files++
            if ($language) { $testLocations[$topLevel].Lines += $lineCount }
            $testLocations[$topLevel].Bytes += $bytes
            if (-not $testAreas.ContainsKey($area)) { $testAreas[$area] = @{ Files = 0; Lines = 0L; Bytes = 0L } }
            $testAreas[$area].Files++
            if ($language) { $testAreas[$area].Lines += $lineCount }
            $testAreas[$area].Bytes += $bytes
        }
    }

    [pscustomobject]@{
        Project = $projectName
        Commit = $commit
        Branch = $branch
        TrackedFiles = $trackedFiles.Count
        TrackedBytes = $totalBytes
        SourceFiles = $sourceFiles
        SourceLines = $sourceLines
        Languages = Convert-Groups $languages 'Language'
        TopLevels = Convert-Groups $topLevels 'Path'
        Areas = Convert-Groups $areas 'Path'
        Documents = [pscustomobject]@{
            Files = $documentFiles
            Lines = $documentLines
            Locations = Convert-Groups $docLocations 'Path'
            Areas = Convert-Groups $docAreas 'Path'
        }
        Tests = [pscustomobject]@{
            Files = $testFiles
            SourceLines = $testSourceLines
            Locations = Convert-Groups $testLocations 'Path'
            Areas = Convert-Groups $testAreas 'Path'
        }
    }
}

$json = $results | ConvertTo-Json -Depth 8
if ($OutputPath) {
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
}
else {
    $json
}
