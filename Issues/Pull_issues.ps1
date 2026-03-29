# =============================================================================
# Pull_issues.ps1 — Sünkroniseerib GitHubi issue'd kohalikku Bodies/ kausta
#
# Käivitamine:
#   cd C:\repo\ITB2204-ISA4\Abimaterjal\Issues
#   .\Pull_issues.ps1
#
# Väljund:
#   Bodies\epics\{number}.md
#   Bodies\features\{number}.md
#   Bodies\tasks\{number}.md
#   metadata\milestones.json
#   metadata\labels.json
#   metadata\project.json
#   metadata\index.json     ← number → { title, type, folder, state }
#   metadata\hierarchy.md  ← human-readable Epic→Feature→Task tree (AI kontekst)
#
# Salvestatud: UTF-8 with BOM
# =============================================================================

. "$PSScriptRoot\config.ps1"

# =============================================================================
# 0. KAUSTAD
# =============================================================================

foreach ($dir in @($EPICS_DIR, $FEATURES_DIR, $TASKS_DIR, $META_DIR)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "  Loodud: $dir" -ForegroundColor DarkGray
    }
}

# =============================================================================
# ABIFUNKTSIOONID
# =============================================================================

# GraphQL päring koos vigade käsitlusega.
# Tagastab parsitud objekti või $null vea korral.
function Invoke-GQL {
    param([string]$Query, [hashtable]$Vars = @{})

    $ghArgs = @("api", "graphql", "-f", "query=$Query")
    foreach ($k in $Vars.Keys) {
        $ghArgs += "-f"
        $ghArgs += "$k=$($Vars[$k])"
    }

    $raw = gh @ghArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "GraphQL VIGA: $raw"
        return $null
    }
    return $raw | ConvertFrom-Json
}

# Kirjutab faili UTF-8 with BOM kodeeringus
function Write-Utf8Bom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8BomEncoding)
}

# Teisendab GitHub API kuupäeva ISO 8601 UTC stringiks.
# ConvertFrom-Json muudab ISO stringid automaatselt [datetime] objektideks,
# mis string-interpolatsioonis kasutavad locale-formaati (nt 03/03/2026 01:18:39).
# See funktsioon tagab alati "2026-03-03T01:18:39Z" kuju.
function Format-IsoTimestamp {
    param($Value)
    if ($null -eq $Value) { return '~' }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    # Kui on juba string (nt "2026-03-03T01:18:39Z"), proovime parsida
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$dt)) {
        return $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return "$Value"   # tagavarana tagastame nagu on
}

# Teisendab stringi YAML-ohutuks (jutumärkides kui sisaldab erimärke)
function Format-YamlString {
    param([string]$Value)
    if ($null -eq $Value -or $Value -eq '') { return '""' }
    # Vaja jutumärke kui string sisaldab: koolon, jutumärgid, newline, #, erimärgid jne.
    if ($Value -match '[:\[\]{}#&*!|>''"%@`]' -or $Value -match '^\s' -or $Value -match '\s$' -or $Value -match '\n') {
        $escaped = $Value -replace '"', '\"' -replace '\r?\n', '\n'
        return "`"$escaped`""
    }
    return $Value
}

# Teisendab massiivi YAML inline-listiks ["a", "b"]
function Format-YamlList {
    param($Items)
    if ($null -eq $Items -or @($Items).Count -eq 0) { return '[]' }
    $quoted = @($Items) | ForEach-Object { "`"$_`"" }
    return '[' + ($quoted -join ', ') + ']'
}

# Leiab Epic-sõlme issue hierarhias:
# Task → parent (Feature) → parent (Epic)
# Feature → parent (Epic)
function Get-EpicFromParentChain {
    param($Issue)

    $p = $Issue.parent
    if ($null -eq $p) { return $null }

    # Kui otsene vanem on Epic, tagasta see
    if ($p.issueType -and $p.issueType.name -eq 'Epic') { return $p }

    # Vaatame vanema vanemat (Task → Feature → Epic)
    $gp = $p.parent
    if ($null -ne $gp -and $gp.issueType -and $gp.issueType.name -eq 'Epic') { return $gp }

    return $null
}

# Määrab kausta nime issue tüübi põhjal
function Get-TargetFolder {
    param([string]$TypeName)
    if ($TYPE_FOLDER_MAP.ContainsKey($TypeName)) {
        return $TYPE_FOLDER_MAP[$TypeName]
    }
    return 'features'   # turvaline vaikeväärtus
}

# Ehitab YAML frontmatter + body sisu ühe issue jaoks
function Build-IssueMarkdown {
    param($Issue, $ProjectStatusMap)

    $num        = $Issue.number
    $title      = Format-YamlString $Issue.title
    $typeName   = if ($Issue.issueType) { $Issue.issueType.name } else { 'Unknown' }
    $state      = $Issue.state.ToLower()

    # --- Milestone ---
    $msTitle  = if ($Issue.milestone) { Format-YamlString $Issue.milestone.title } else { '~' }
    $msNumber = if ($Issue.milestone) { $Issue.milestone.number } else { '~' }
    $msDue    = if ($Issue.milestone -and $Issue.milestone.dueOn) { $Issue.milestone.dueOn } else { '~' }

    # --- Assignees ---
    $assignees = @()
    if ($Issue.assignees -and $Issue.assignees.nodes) {
        $assignees = @($Issue.assignees.nodes | ForEach-Object { $_.login })
    }

    # --- Labels ---
    $labels = @()
    if ($Issue.labels -and $Issue.labels.nodes) {
        $labels = @($Issue.labels.nodes | ForEach-Object { $_.name })
    }

    # --- Parent ---
    $parentNumber = '~'
    $parentTitle  = '~'
    if ($Issue.parent) {
        $parentNumber = $Issue.parent.number
        $parentTitle  = Format-YamlString $Issue.parent.title
    }

    # --- Epic (kuni 2 tasandit ülesse) ---
    $epicNumber = '~'
    $epicTitle  = '~'
    $epic = Get-EpicFromParentChain $Issue
    if ($null -ne $epic) {
        $epicNumber = $epic.number
        $epicTitle  = Format-YamlString $epic.title
    } elseif ($typeName -eq 'Epic') {
        $epicNumber = $num     # Epic ise ongi oma "epic"
        $epicTitle  = $title
    }

    # --- Sub-issues ---
    $subIssues = @()
    if ($Issue.subIssues -and $Issue.subIssues.nodes) {
        $subIssues = @($Issue.subIssues.nodes | ForEach-Object { $_.number })
    }

    # --- Projekti staatus, sprint ja item ID ---
    $projectStatus = '~'
    $projectSprint = '~'
    $projectItemId = '~'
    if ($ProjectStatusMap.ContainsKey($num)) {
        $projectStatus = Format-YamlString $ProjectStatusMap[$num].status
        if ($ProjectStatusMap[$num].iteration) {
            $projectSprint = Format-YamlString $ProjectStatusMap[$num].iteration
        }
        if ($ProjectStatusMap[$num].itemId) {
            $projectItemId = $ProjectStatusMap[$num].itemId
        }
    }

    # --- Body hash (SHA256) muudatuste tuvastamiseks ---
    $body = if ($Issue.body) { $Issue.body } else { '' }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $sha256    = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($bodyBytes)
    $bodyHash  = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })

    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $fm = @"
---
number: $num
title: $title
type: $typeName
state: $state
parent_number: $parentNumber
parent_title: $parentTitle
epic_number: $epicNumber
epic_title: $epicTitle
labels: $(Format-YamlList $labels)
milestone: $msTitle
milestone_number: $msNumber
milestone_due: $msDue
assignees: $(Format-YamlList $assignees)
project_status: $projectStatus
project_sprint: $projectSprint
project_item_id: $projectItemId
sub_issues: $(Format-YamlList $subIssues)
created_at: $(Format-IsoTimestamp $Issue.createdAt)
updated_at: $(Format-IsoTimestamp $Issue.updatedAt)
closed_at: $(Format-IsoTimestamp $Issue.closedAt)
synced_at: $now
body_hash: $bodyHash
---

"@

    return $fm + $body
}

# =============================================================================
# 1. REPO METAANDMED — milestones & labels
# =============================================================================

Write-Host "`n[1/7] Fetching repo metadata (milestones, labels)..." -ForegroundColor Cyan

$milestonesRaw = gh api "repos/$REPO/milestones?state=all&per_page=100" --paginate 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Milestones päring ebaõnnestus: $milestonesRaw"
    $milestones = @()
} else {
    $milestones = $milestonesRaw | ConvertFrom-Json
}
$milestoneFile = "$META_DIR\milestones.json"
$milestones | ConvertTo-Json -Depth 5 | ForEach-Object {
    [System.IO.File]::WriteAllText($milestoneFile, $_, $Utf8BomEncoding)
}
Write-Host "  Milestones: $($milestones.Count) → metadata\milestones.json"

$labelsRawOutput = gh api "repos/$REPO/labels?per_page=100" --paginate 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Labels päring ebaõnnestus: $labelsRawOutput"
    $labelsRaw = @()
} else {
    $labelsRaw = $labelsRawOutput | ConvertFrom-Json
}
$labelsFile = "$META_DIR\labels.json"
$labelsRaw | ConvertTo-Json -Depth 5 | ForEach-Object {
    [System.IO.File]::WriteAllText($labelsFile, $_, $Utf8BomEncoding)
}
Write-Host "  Labels:     $($labelsRaw.Count) → metadata\labels.json"

# =============================================================================
# 2. PROJEKT METAANDMED — field definitions
# =============================================================================

Write-Host "`n[2/7] Fetching project metadata (fields, options)..." -ForegroundColor Cyan

$projectQuery = @'
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      title number url
      fields(first: 50) {
        nodes {
          ... on ProjectV2Field { id name dataType }
          ... on ProjectV2SingleSelectField {
            id name
            options { id name color description }
          }
          ... on ProjectV2IterationField {
            id name
            configuration {
              iterations           { id title startDate duration }
              completedIterations  { id title startDate duration }
            }
          }
        }
      }
    }
  }
}
'@

$projectMeta = Invoke-GQL -Query $projectQuery -Vars @{ projectId = $PROJECT_ID }
if ($projectMeta) {
    $projectMeta.data.node | ConvertTo-Json -Depth 10 | ForEach-Object {
        [System.IO.File]::WriteAllText("$META_DIR\project.json", $_, $Utf8BomEncoding)
    }
    $fieldCount = @($projectMeta.data.node.fields.nodes).Count
    Write-Host "  Project:    '$($projectMeta.data.node.title)' → metadata\project.json ($fieldCount fields)"
} else {
    Write-Warning "  Projekti metaandmed ei õnnestunud — project.json jäetakse vahele."
}

# =============================================================================
# 3. KÕIK ISSUED — pagineeritud GraphQL päring
# =============================================================================

Write-Host "`n[3/7] Fetching all issues (paginated)..." -ForegroundColor Cyan

$issuesQuery = @'
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, after: $cursor, states: [OPEN, CLOSED]) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title body state createdAt updatedAt closedAt
        issueType { id name }
        parent {
          number title
          issueType { name }
          parent { number title issueType { name } }
        }
        subIssues(first: 50) { totalCount nodes { number title } }
        assignees(first: 10) { nodes { login } }
        labels(first: 20)    { nodes { name } }
        milestone { title number dueOn }
      }
    }
  }
}
'@

$allIssues = @()
$cursor    = $null
$page      = 1

do {
    $vars = @{ owner = $ORG; name = $REPO_NAME }
    if ($cursor) { $vars['cursor'] = $cursor }

    $resp = Invoke-GQL -Query $issuesQuery -Vars $vars
    if (-not $resp) { Write-Warning "  Lehekülg $page ebaõnnestus — katkestan."; break }

    $pageData  = $resp.data.repository.issues
    $allIssues += $pageData.nodes
    Write-Host "  Lehekülg $page — $($pageData.nodes.Count) issue'd (kokku: $($allIssues.Count))"

    if ($pageData.pageInfo.hasNextPage) {
        $cursor = $pageData.pageInfo.endCursor
        $page++
    } else {
        break
    }
} while ($true)

Write-Host "  Kokku: $($allIssues.Count) issue'd"

# Kontrolli sub-issues kärpimist (max 50 per issue)
$truncated = @($allIssues | Where-Object {
    $_.subIssues -and $_.subIssues.totalCount -gt @($_.subIssues.nodes).Count
})
if ($truncated.Count -gt 0) {
    Write-Warning "Sub-issues kärpimus: $($truncated.Count) issue'l on rohkem sub-issue'sid kui päringuga saadi (max 50):"
    $truncated | ForEach-Object {
        Write-Warning "  #$($_.number) $($_.title): $($_.subIssues.totalCount) sub-issues"
    }
}

# =============================================================================
# 4. PROJEKTI STAATUSED — issue number → status string
# =============================================================================

Write-Host "`n[4/7] Fetching project item statuses..." -ForegroundColor Cyan

$projectItemQuery = @'
query($projectId: ID!, $cursor: String) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content { ... on Issue { number } }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2SingleSelectField { name } }
              }
              ... on ProjectV2ItemFieldIterationValue {
                title
                field { ... on ProjectV2IterationField { name } }
              }
            }
          }
        }
      }
    }
  }
}
'@

# number (int) → @{ status = "In Progress"; iteration = "Sprint 2"; itemId = "PVTI_..." }
$projectStatusMap = @{}
$cursor = $null

do {
    $vars = @{ projectId = $PROJECT_ID }
    if ($cursor) { $vars['cursor'] = $cursor }

    $resp = Invoke-GQL -Query $projectItemQuery -Vars $vars
    if (-not $resp) { Write-Warning "  Projekti staatus päring ebaõnnestus"; break }

    $itemsPage = $resp.data.node.items
    foreach ($item in $itemsPage.nodes) {
        if (-not $item.content -or $null -eq $item.content.number) { continue }
        $n = $item.content.number
        $statusVal    = $null
        $iterationVal = $null
        foreach ($fv in $item.fieldValues.nodes) {
            if ($fv.field -and $fv.field.name -eq 'Status')    { $statusVal    = $fv.name  }
            if ($fv.field -and $fv.field.name -eq 'Iteration') { $iterationVal = $fv.title }
            if ($fv.field -and $fv.field.name -eq 'Sprint')    { $iterationVal = $fv.title }
        }
        $projectStatusMap[$n] = @{ status = $statusVal; iteration = $iterationVal; itemId = $item.id }
    }

    if ($itemsPage.pageInfo.hasNextPage) {
        $cursor = $itemsPage.pageInfo.endCursor
    } else {
        break
    }
} while ($true)

Write-Host "  Projekti staatused: $($projectStatusMap.Count) kirjet"

# =============================================================================
# 5. FAILIDE KIRJUTAMINE
# =============================================================================

Write-Host "`n[5/7] Writing issue files..." -ForegroundColor Cyan

$counts        = @{ epics = 0; features = 0; tasks = 0; unknown = 0 }
$writtenFiles  = @{}   # number → kirjutatud failitee (index.json jaoks)

foreach ($issue in $allIssues) {
    $typeName = if ($issue.issueType) { $issue.issueType.name } else { 'Unknown' }
    $folder   = Get-TargetFolder $typeName

    switch ($folder) {
        'epics'    { $targetDir = $EPICS_DIR;    $counts.epics++    }
        'features' { $targetDir = $FEATURES_DIR; $counts.features++ }
        'tasks'    { $targetDir = $TASKS_DIR;    $counts.tasks++    }
        default    { $targetDir = $FEATURES_DIR; $counts.unknown++  }
    }

    $filePath = "$targetDir\$($issue.number).md"
    $content  = Build-IssueMarkdown -Issue $issue -ProjectStatusMap $projectStatusMap
    Write-Utf8Bom -Path $filePath -Content $content
    $writtenFiles[$issue.number] = @{
        path   = "Bodies\$folder\$($issue.number).md"
        folder = $folder
        type   = $typeName
        title  = $issue.title
        state  = $issue.state.ToLower()
    }
}

Write-Host "  Kirjutatud: $($counts.epics) epics, $($counts.features) features, $($counts.tasks) tasks$(if ($counts.unknown -gt 0) { ", $($counts.unknown) unknown" })"

# =============================================================================
# INDEX.JSON — number → { title, type, folder, path, state }
# Pure GitHub data — no dependency on local planning files.
# =============================================================================

$index = [ordered]@{}
foreach ($num in ($writtenFiles.Keys | Sort-Object { [int]$_ })) {
    $entry = $writtenFiles[$num]
    $index["$num"] = [ordered]@{
        number = [int]$num
        title  = $entry.title
        type   = $entry.type
        folder = $entry.folder
        path   = $entry.path
        state  = $entry.state
    }
}

$index | ConvertTo-Json -Depth 5 | ForEach-Object {
    [System.IO.File]::WriteAllText("$META_DIR\index.json", $_, $Utf8BomEncoding)
}
Write-Host "  Index: $($index.Count) kirjet → metadata\index.json"

# =============================================================================
# 6. PUHASTUS — eemalda vanad/valesse kausta jäänud failid
# =============================================================================

Write-Host "`n[6/7] Cleaning up stale files..." -ForegroundColor Cyan

# Ehitame seti: "epics\1", "features\7", "tasks\28" jne (folder\number)
$validFiles = [System.Collections.Generic.HashSet[string]]::new()
foreach ($num in $writtenFiles.Keys) {
    $entry = $writtenFiles[$num]
    [void]$validFiles.Add("$($entry.folder)\$num.md")
}

$removedCount = 0
foreach ($dir in @($EPICS_DIR, $FEATURES_DIR, $TASKS_DIR)) {
    $folderName = Split-Path $dir -Leaf   # "epics", "features", "tasks"
    Get-ChildItem -Path $dir -Filter '*.md' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $relKey = "$folderName\$($_.Name)"   # e.g. "tasks\65.md"
        if (-not $validFiles.Contains($relKey)) {
            Remove-Item $_.FullName -Force
            Write-Host "  Eemaldatud: Bodies\$relKey" -ForegroundColor DarkYellow
            $removedCount++
        }
    }
}

if ($removedCount -eq 0) {
    Write-Host "  Vanad failid puuduvad — midagi ei eemaldatud."
} else {
    Write-Host "  Eemaldatud kokku: $removedCount faili" -ForegroundColor Yellow
}

# =============================================================================
# 7. HIERARCHY.MD — inimloetav puuvaade kõigile AI ja meeskonna töövoogudele
# =============================================================================

Write-Host "`n[7/7] Building hierarchy.md..." -ForegroundColor Cyan

# Indekseerime kõik issued numbri järgi kiireks lookup'iks
$byNumber = @{}
foreach ($iss in $allIssues) { $byNumber[[int]$iss.number] = $iss }

# Abifunktsioon: YAML frontmatteris salvestatud labels massiiv → inimloetav string
function Format-Labels {
    param($Issue)
    if (-not $Issue.labels -or -not $Issue.labels.nodes -or @($Issue.labels.nodes).Count -eq 0) { return '' }
    $names = @($Issue.labels.nodes | ForEach-Object { $_.name })
    return ' `' + ($names -join '` `') + '`'
}

# Abifunktsioon: ühe issue rea sümbol sõltuvalt olekust
function Get-StateIcon {
    param($Issue)
    if ($Issue.state -eq 'CLOSED') { return '[x]' }
    return '[ ]'
}

# Abifunktsioon: projekti staatus badge
function Format-Status {
    param([int]$Number)
    if (-not $projectStatusMap.ContainsKey($Number)) { return '' }
    $s = $projectStatusMap[$Number]
    $parts = @()
    if ($s.status)    { $parts += "**$($s.status)**" }
    if ($s.iteration) { $parts += $s.iteration }
    if ($parts.Count -eq 0) { return '' }
    return ' · ' + ($parts -join ' · ')
}

# Bild puud mälus: epic → features (sorted) → tasks (sorted)
$epics    = $allIssues | Where-Object { $_.issueType -and $_.issueType.name -eq 'Epic' } |
            Sort-Object { [int]$_.number }

$features = $allIssues | Where-Object { $_.issueType -and $_.issueType.name -eq 'Feature' } |
            Sort-Object { [int]$_.number }

$tasks    = $allIssues | Where-Object {
                $_.issueType -and ($_.issueType.name -eq 'Task' -or $_.issueType.name -eq 'Bug')
            } | Sort-Object { [int]$_.number }

# Grupeeri features ja tasks vanema järgi
$featuresByParent = @{}
foreach ($f in $features) {
    $pk = if ($f.parent) { [int]$f.parent.number } else { 0 }
    if (-not $featuresByParent.ContainsKey($pk)) { $featuresByParent[$pk] = @() }
    $featuresByParent[$pk] += $f
}

$tasksByParent = @{}
foreach ($t in $tasks) {
    $pk = if ($t.parent) { [int]$t.parent.number } else { 0 }
    if (-not $tasksByParent.ContainsKey($pk)) { $tasksByParent[$pk] = @() }
    $tasksByParent[$pk] += $t
}

# --- Kirjuta hierarchy.md ---------------------------------------------------
$sb      = [System.Text.StringBuilder]::new()
$syncTs  = Get-Date -Format 'yyyy-MM-dd HH:mm'

[void]$sb.AppendLine("# Issue hierarhia — $REPO")
[void]$sb.AppendLine("")
[void]$sb.AppendLine('> Genereeritud automaatselt `Pull_issues.ps1` poolt · ' + $syncTs)
[void]$sb.AppendLine("> Muuda GitHubis, käivita sync uuesti — ära muuda seda faili käsitsi.")
[void]$sb.AppendLine("")

# Tabel kokkuvõte
$openEpics    = @($epics    | Where-Object { $_.state -ne 'CLOSED' }).Count
$openFeatures = @($features | Where-Object { $_.state -ne 'CLOSED' }).Count
$openTasks    = @($tasks    | Where-Object { $_.state -ne 'CLOSED' }).Count
$doneEpics    = $epics.Count    - $openEpics
$doneFeatures = $features.Count - $openFeatures
$doneTasks    = $tasks.Count    - $openTasks

[void]$sb.AppendLine("| Tüüp | Kokku | Avatud | Suletud |")
[void]$sb.AppendLine("|------|------:|-------:|--------:|")
[void]$sb.AppendLine("| Epic | $($epics.Count) | $openEpics | $doneEpics |")
[void]$sb.AppendLine("| Feature | $($features.Count) | $openFeatures | $doneFeatures |")
[void]$sb.AppendLine("| Task/Bug | $($tasks.Count) | $openTasks | $doneTasks |")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

foreach ($epic in $epics) {
    $en         = [int]$epic.number
    $stateIcon  = if ($epic.state -eq 'CLOSED') { '~~' } else { '' }
    $stateClose = if ($epic.state -eq 'CLOSED') { '~~' } else { '' }
    $status     = Format-Status $en
    $epicFeatures = if ($featuresByParent.ContainsKey($en)) { $featuresByParent[$en] } else { @() }

    [void]$sb.AppendLine("## Epic #$en — $stateIcon$($epic.title)$stateClose$status")
    [void]$sb.AppendLine("")

    if (@($epicFeatures).Count -eq 0) {
        [void]$sb.AppendLine("_Puuduvad Features._")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("---")
        [void]$sb.AppendLine("")
        continue
    }

    foreach ($feat in $epicFeatures) {
        $fn         = [int]$feat.number
        $ms         = if ($feat.milestone) { " · $($feat.milestone.title)" } else { '' }
        $lbls       = Format-Labels $feat
        $fStatus    = Format-Status $fn
        $fState     = if ($feat.state -eq 'CLOSED') { ' ✓' } else { '' }
        $assignStr  = ''
        if ($feat.assignees -and $feat.assignees.nodes -and @($feat.assignees.nodes).Count -gt 0) {
            $logins   = @($feat.assignees.nodes | ForEach-Object { "@$($_.login)" })
            $assignStr = ' · ' + ($logins -join ', ')
        }

        [void]$sb.AppendLine("### $(Get-StateIcon $feat) Feature #$fn — $($feat.title)$fState")
        [void]$sb.AppendLine("")

        # Meta rida
        $metaParts = @()
        if ($feat.milestone) { $metaParts += "**Milestone:** $($feat.milestone.title)" }
        if ($lbls)           { $metaParts += "**Labels:**$lbls" }
        if ($assignStr)      { $metaParts += "**Assignees:**$assignStr" }
        $statusStr = Format-Status $fn
        if ($statusStr)      { $metaParts += "**Staatus:**$statusStr" }
        if ($metaParts.Count -gt 0) {
            [void]$sb.AppendLine(($metaParts -join ' · '))
            [void]$sb.AppendLine("")
        }

        # Tasks
        $featTasks = if ($tasksByParent.ContainsKey($fn)) { $tasksByParent[$fn] } else { @() }

        if (@($featTasks).Count -eq 0) {
            [void]$sb.AppendLine("  _Puuduvad Tasks._")
        } else {
            foreach ($task in $featTasks) {
                $tn        = [int]$task.number
                $tStatus   = Format-Status $tn
                $tLbls     = Format-Labels $task
                $tMs       = if ($task.milestone) { " · $($task.milestone.title)" } else { '' }
                $tAssign   = ''
                if ($task.assignees -and $task.assignees.nodes -and @($task.assignees.nodes).Count -gt 0) {
                    $logins  = @($task.assignees.nodes | ForEach-Object { "@$($_.login)" })
                    $tAssign = ' · ' + ($logins -join ', ')
                }
                $bugBadge  = if ($task.issueType -and $task.issueType.name -eq 'Bug') { ' 🐛' } else { '' }
                [void]$sb.AppendLine("  - $(Get-StateIcon $task) **#$tn** $($task.title)$bugBadge$tStatus$tMs$tLbls$tAssign")
            }
        }
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")
}

# Kõik features, mille otsene vanem EI ole epics listis
$knownEpicNumbers = [System.Collections.Generic.HashSet[int]]::new(
    [int[]]@($epics | ForEach-Object { [int]$_.number })
)
$orphanFeatures = @($features | Where-Object {
    $directParentNum = if ($_.parent) { [int]$_.parent.number } else { $null }
    $null -eq $directParentNum -or -not $knownEpicNumbers.Contains($directParentNum)
})

if ($orphanFeatures.Count -gt 0) {
    [void]$sb.AppendLine("## ⚠️ Features ilma Epic vanemata")
    [void]$sb.AppendLine("")
    foreach ($f in $orphanFeatures) {
        $pInfo = if ($f.parent) { "parent: #$([int]$f.parent.number) ($($f.parent.title))" } else { "parent: puudub" }
        [void]$sb.AppendLine("- **#$([int]$f.number)** $($f.title) · _$pInfo_")
    }
    [void]$sb.AppendLine("")
}

$knownFeatureNumbers = [System.Collections.Generic.HashSet[int]]::new(
    [int[]]@($features | ForEach-Object { [int]$_.number })
)
$orphanTasks = @($tasks | Where-Object {
    $directParentNum = if ($_.parent) { [int]$_.parent.number } else { $null }
    $null -eq $directParentNum -or -not $knownFeatureNumbers.Contains($directParentNum)
})
if ($orphanTasks.Count -gt 0) {
    [void]$sb.AppendLine("## ⚠️ Tasks ilma Feature vanemata")
    [void]$sb.AppendLine("")
    foreach ($t in $orphanTasks) {
        $pInfo = if ($t.parent) { "parent: #$([int]$t.parent.number) ($($t.parent.title))" } else { "parent: puudub" }
        [void]$sb.AppendLine("- **#$([int]$t.number)** $($t.title) · _$pInfo_")
    }
    [void]$sb.AppendLine("")
}

$hierarchyPath = "$META_DIR\hierarchy.md"
[System.IO.File]::WriteAllText($hierarchyPath, $sb.ToString(), $Utf8BomEncoding)
Write-Host "  Hierarchy: $($epics.Count) epics, $($features.Count) features, $($tasks.Count) tasks → metadata\hierarchy.md"

# =============================================================================
# KOKKUVÕTE
# =============================================================================

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Sünkroniseerimine lõpetatud!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host " Epics:        $($counts.epics)"
Write-Host " Features:     $($counts.features)"
Write-Host " Tasks/Bugs:   $($counts.tasks)"
Write-Host " Kokku issued: $($allIssues.Count)"
Write-Host " Metadata:     $META_DIR"
Write-Host " Bodies:       $BODIES_DIR"
Write-Host ""
Write-Host " Failid:" -ForegroundColor Gray
Write-Host "   Bodies\epics\{nr}.md       — $($counts.epics) faili" -ForegroundColor Gray
Write-Host "   Bodies\features\{nr}.md    — $($counts.features) faili" -ForegroundColor Gray
Write-Host "   Bodies\tasks\{nr}.md       — $($counts.tasks) faili" -ForegroundColor Gray
Write-Host "   metadata\milestones.json" -ForegroundColor Gray
Write-Host "   metadata\labels.json" -ForegroundColor Gray
Write-Host "   metadata\project.json" -ForegroundColor Gray
Write-Host "   metadata\index.json" -ForegroundColor Gray
Write-Host "   metadata\hierarchy.md     ← AI töövoo kontekstifail" -ForegroundColor Green
