# =============================================================================
# push_issues.ps1 — Laeb lokaalselt muudetud issue'd GitHubi + loob uued
#
# Käivitamine:
#   cd C:\repo\ITB2204-ISA4\Abimaterjal\Issues
#   .\push_issues.ps1              # päris push
#   .\push_issues.ps1 -WhatIf     # eelvaade (kuivkäivitus)
#
# Eeltingimused:
#   - Käivita kõigepealt .\Pull_issues.ps1, et saada värske kohalik koopia
#   - gh auth status — repo, read:org, read:project skoop
#   - PowerShell 7+
#
# Tööpõhimõte:
#   A) UUED ISSUED (number: new)
#      1. Loob issue GitHubis (gh issue create)
#      2. Määrab issue tüübi (GraphQL updateIssue)
#      3. Lisab projekti (GraphQL addProjectV2ItemById)
#      4. Seob vanema külge (GraphQL addSubIssue), kui parent_number on olemas
#      5. Määrab projekti staatuse (GraphQL updateProjectV2ItemFieldValue)
#      6. Nimetab faili ümber → {number}.md ja uuendab frontmatter
#
#   B) OLEMASOLEVAD ISSUED (number: 1..N)
#      1. Loeb kõik Bodies/{epics,features,tasks}/*.md failid
#      2. Parsib YAML frontmatter-i ja body
#      3. Tuvastab muudetud väljad (body_hash võrdlus + frontmatter diff)
#      4. Kontrollib iga muudetud issue värskust (updated_at vs synced_at)
#      5. Laeb muudatused GitHubi (gh issue edit, gh issue close/reopen, GraphQL)
#
# Piirangud:
#   - Ei kustuta ühtegi issue'd (puudub õigus live repos)
#   - Ei muuda issue tüüpi ega vanema seost olemasolevatele (nõuab org-admin)
#
# Salvestatud: UTF-8 with BOM
# =============================================================================

[CmdletBinding(SupportsShouldProcess)]
param()

. "$PSScriptRoot\config.ps1"

# =============================================================================
# ABIFUNKTSIOONID
# =============================================================================

# GraphQL päring (sama mis Pull_issues.ps1-s)
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

# Parsib YAML frontmatter'i .md failist.
# Tagastab hashtable frontmatter väljadega + eraldi 'body' võti.
function Read-IssueFrontmatter {
    param([string]$Path)

    $raw = [System.IO.File]::ReadAllText($Path, $Utf8BomEncoding)

    # Eraldame frontmatter (--- ... ---) ja body
    if ($raw -notmatch '(?s)^---\r?\n(.+?)\r?\n---\r?\n(.*)$') {
        Write-Warning "  Frontmatter puudub: $Path"
        return $null
    }
    $yamlBlock = $Matches[1]
    $body      = $Matches[2]

    $fm = @{}
    foreach ($line in $yamlBlock -split '\r?\n') {
        if ($line -match '^(\w[\w_]*)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim()

            # Eemalda jutumärgid
            if ($val -match '^"(.*)"$') { $val = $Matches[1] -replace '\\"', '"' }
            elseif ($val -match "^'(.*)'$") { $val = $Matches[1] }

            # YAML null
            if ($val -eq '~' -or $val -eq 'null' -or $val -eq '') { $val = $null }

            # Inline list: ["a", "b"]
            if ($null -ne $val -and $val -match '^\[.*\]$') {
                $inner = $val.Trim('[', ']').Trim()
                if ($inner -eq '') {
                    $val = @()
                } else {
                    $val = @($inner -split ',\s*' | ForEach-Object { $_.Trim('"', "'", ' ') } | Where-Object { $_ -ne '' })
                }
            }

            $fm[$key] = $val
        }
    }

    $fm['_body'] = $body
    $fm['_path'] = $Path
    return $fm
}

# Arvutab SHA-256 hashi stringist
function Get-BodyHash {
    param([string]$Text)
    $bytes     = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha256    = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($bytes)
    return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
}

# Teisendab ISO 8601 stringi DateTime objektiks (UTC)
function Parse-IsoTimestamp {
    param([string]$Value)
    if ($null -eq $Value -or $Value -eq '~' -or $Value -eq '') { return $null }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$dt)) {
        return $dt.ToUniversalTime()
    }
    return $null
}

# Kausta nimi → issue type ID (config.ps1 muutujad)
function Get-IssueTypeId {
    param([string]$TypeName)
    switch ($TypeName) {
        'Epic'    { return $TYPE_EPIC }
        'Feature' { return $TYPE_FEATURE }
        'Task'    { return $TYPE_TASK }
        'Bug'     { return $TYPE_BUG }
        default   { return $TYPE_TASK }
    }
}

# Hangib issue GraphQL node ID numbri järgi (retry: 3s, 5s)
function Get-IssueNodeId {
    param([int]$Number)
    $delays = @(0, 3, 5)  # esimene katse kohe, teine 3s, kolmas 5s
    for ($i = 0; $i -lt $delays.Count; $i++) {
        if ($delays[$i] -gt 0) {
            Write-Host "  ⏳ Ootan $($delays[$i])s enne uut katset ($($i+1)/3)..." -ForegroundColor Yellow
            Start-Sleep -Seconds $delays[$i]
        }
        $raw = gh issue view $Number --repo $REPO --json id --jq '.id' 2>&1
        if ($LASTEXITCODE -eq 0 -and $raw) {
            return $raw.Trim()
        }
        if ($i -lt $delays.Count - 1) {
            Write-Warning "  Node ID päring ebaõnnestus #$Number (katse $($i+1)/3): $raw"
        }
    }
    Write-Warning "  ✗ Node ID päring ebaõnnestus #$Number kõigil 3 katsel: $raw"
    return $null
}

# Määrab issue tüübi GraphQL-iga
function Set-IssueType {
    param([string]$NodeId, [string]$TypeId)
    $q = 'mutation($id: ID!, $typeId: ID!) { updateIssue(input: {id: $id, issueTypeId: $typeId}) { issue { number } } }'
    $result = Invoke-GQL -Query $q -Vars @{ id = $NodeId; typeId = $TypeId }
    if (-not $result -or $result.errors) {
        Write-Warning "  Issue tüübi määramine ebaõnnestus"
        return $false
    }
    return $true
}

# Lisab issue projekti, tagastab project item ID
function Add-IssueToProject {
    param([string]$NodeId)
    $q = 'mutation($projectId: ID!, $contentId: ID!) { addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) { item { id } } }'
    $result = Invoke-GQL -Query $q -Vars @{ projectId = $PROJECT_ID; contentId = $NodeId }
    if (-not $result -or $result.errors) {
        Write-Warning "  Projekti lisamine ebaõnnestus"
        return $null
    }
    return $result.data.addProjectV2ItemById.item.id
}

# Seob child issue parent issue külge (sub-issue)
function Set-ParentIssue {
    param([string]$ParentNodeId, [string]$ChildNodeId)
    $q = 'mutation($parentId: ID!, $childId: ID!) { addSubIssue(input: {issueId: $parentId, subIssueId: $childId}) { issue { number } subIssue { number } } }'
    $result = Invoke-GQL -Query $q -Vars @{ parentId = $ParentNodeId; childId = $ChildNodeId }
    if (-not $result -or $result.errors) {
        Write-Warning "  Parent seose loomine ebaõnnestus"
        return $false
    }
    return $true
}

# Kirjutab faili UTF-8 with BOM kodeeringus
function Write-Utf8Bom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8BomEncoding)
}

# --- Abimuutja: project status field ID (cached) ---
$statusFieldId = $null
$statusOptions = @{}   # option name → option id

# --- Abimuutja: project sprint/iteration field ID (cached) ---
$sprintFieldId = $null
$sprintOptions = @{}   # iteration title → iteration id

function Ensure-ProjectStatusMeta {
    # Laeme projekt metaandmed, et saada Status välja ID ja valikud
    if ($null -ne $script:statusFieldId) { return }

    $projFile = "$META_DIR\project.json"
    if (-not (Test-Path $projFile)) {
        Write-Warning "  project.json puudub — projekti staatust ei saa uuendada"
        return
    }

    $projMeta = Get-Content $projFile -Raw | ConvertFrom-Json
    foreach ($field in $projMeta.fields.nodes) {
        if ($field.name -eq 'Status' -and $field.options) {
            $script:statusFieldId = $field.id
            foreach ($opt in $field.options) {
                $script:statusOptions[$opt.name] = $opt.id
            }
        }
        if ($field.configuration -and ($field.name -eq 'Sprint' -or $field.name -eq 'Iteration')) {
            $script:sprintFieldId = $field.id
            foreach ($iter in $field.configuration.iterations) {
                $script:sprintOptions[$iter.title] = $iter.id
            }
            foreach ($iter in $field.configuration.completedIterations) {
                $script:sprintOptions[$iter.title] = $iter.id
            }
        }
    }
}

# =============================================================================
# 1. LOE KÕIK KOHALIKUD ISSUE FAILID — eraldi uued ja olemasolevad
# =============================================================================

Write-Host "`n[1/6] Loeb kohalikud issue failid..." -ForegroundColor Cyan

$localIssues = @{}     # number → fm  (olemasolevad)
$newIssues   = @()     # fm massiiv   (number: new)
$fileCount   = 0

foreach ($dir in @($EPICS_DIR, $FEATURES_DIR, $TASKS_DIR)) {
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem -Path $dir -Filter '*.md' -File | ForEach-Object {
        $fm = Read-IssueFrontmatter -Path $_.FullName
        if ($null -eq $fm) { return }

        $numVal = $fm['number']
        if ($numVal -eq 'new' -or $numVal -eq '0') {
            # Uus issue — pole veel GitHubis
            $newIssues += $fm
        } elseif ($null -ne $numVal) {
            $num = [int]$numVal
            $localIssues[$num] = $fm
        }
        $fileCount++
    }
}

Write-Host "  Loetud: $fileCount faili ($($newIssues.Count) uut, $($localIssues.Count) olemasolevat)"

if ($fileCount -eq 0) {
    Write-Host "`nÜhtegi issue faili ei leitud. Loo fail Bodies/ alla või käivita .\Pull_issues.ps1" -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# 2. LOO UUED ISSUED GITHUBIS
# =============================================================================

$createOk   = 0
$createFail = 0
$nodeIdFailures = @() # issue'd, mille Node ID päring ebaõnnestus
$createdTitles = @{}   # title → number  (uute loodud issued ristviitamiseks)

if ($newIssues.Count -gt 0) {
    # Sordi: Epicud → Features → Taskid, et vanemad luuakse enne lapsi
    $typePriority = @{ 'Epic' = 1; 'Feature' = 2; 'Task' = 3 }
    $newIssues = $newIssues | Sort-Object {
        $folder = Split-Path (Split-Path $_['_path'] -Parent) -Leaf
        $t = $_['type']
        if (-not $t) { $t = switch ($folder) { 'epics' { 'Epic' }; 'features' { 'Feature' }; default { 'Task' } } }
        if ($typePriority.ContainsKey($t)) { $typePriority[$t] } else { 9 }
    }

    Write-Host "`n[2/6] Loob $($newIssues.Count) uut issue'd GitHubis..." -ForegroundColor Cyan
    Write-Host "  Järjekord: $( ($newIssues | ForEach-Object { $_['type'] }) -join ' → ')" -ForegroundColor DarkGray

    foreach ($fm in $newIssues) {
        $title     = $fm['title']
        $typeName  = $fm['type']
        $body      = $fm['_body']
        $filePath  = $fm['_path']
        $folder    = Split-Path (Split-Path $filePath -Parent) -Leaf   # "epics"/"features"/"tasks"

        # Tuletame type kausta nimest, kui frontmatteris puudub
        if (-not $typeName) {
            $typeName = switch ($folder) {
                'epics'    { 'Epic' }
                'features' { 'Feature' }
                'tasks'    { 'Task' }
                default    { 'Task' }
            }
        }

        $issueLabel = "(uus) $title"
        Write-Host "`n  $issueLabel" -ForegroundColor Yellow

        # --- Duplikaadi kontroll ---
        $dupCheck = gh issue list --repo $REPO --state all --search "`"$title`"" --json number,title 2>&1
        if ($LASTEXITCODE -eq 0 -and $dupCheck) {
            $existing = ($dupCheck | ConvertFrom-Json) | Where-Object { $_.title -eq $title } | Select-Object -First 1
            if ($existing) {
                Write-Warning "  Juba olemas: #$($existing.number) — vahelan."
                $createFail++
                continue
            }
        }

        # --- Ehita gh issue create argumendid ---
        $createArgs = @("issue", "create", "--repo", $REPO, "--title", $title, "--body", $body)

        # Labels
        if ($fm['labels'] -is [array] -and $fm['labels'].Count -gt 0) {
            $createArgs += @("--label", ($fm['labels'] -join ','))
        }

        # Milestone
        if ($fm['milestone']) {
            $createArgs += @("--milestone", $fm['milestone'])
        }

        # Assignees
        if ($fm['assignees'] -is [array] -and $fm['assignees'].Count -gt 0) {
            $createArgs += @("--assignee", ($fm['assignees'] -join ','))
        }

        if ($PSCmdlet.ShouldProcess($issueLabel, "gh issue create")) {
            $url = (gh @createArgs) 2>&1
            if ($url -notmatch '/issues/(\d+)') {
                Write-Warning "  ✗ Issue loomine ebaõnnestus: $url"
                $createFail++
                continue
            }
            $number = [int]$Matches[1]
            Write-Host "  ✓ Loodud: #$number" -ForegroundColor Green

            # --- Node ID (retry: 3s, 5s) ---
            $nodeId = Get-IssueNodeId -Number $number
            if (-not $nodeId) {
                Write-Host "  ✗ Node ID päring ebaõnnestus #$number — tüüp/projekt/parent jäävad seadmata" -ForegroundColor Red
                $nodeIdFailures += @{ Number = $number; Title = $title; Type = $typeName }
                # Issue ise on loodud, aga metaandmeid ei saa määrata
                $createdTitles[$title] = $number
                $createOk++
                Start-Sleep -Milliseconds 500
                continue
            }

            # --- Määra tüüp ---
            $typeId = Get-IssueTypeId $typeName
            if ($typeId) {
                Write-Host "  → Tüüp: $typeName" -ForegroundColor DarkGray
                Set-IssueType -NodeId $nodeId -TypeId $typeId | Out-Null
            }

            # --- Lisa projekti ---
            Write-Host "  → Lisan projekti..." -ForegroundColor DarkGray
            $projectItemId = Add-IssueToProject -NodeId $nodeId
            if ($projectItemId) {
                Write-Host "  ✓ Projektis (item: $projectItemId)" -ForegroundColor Green
            }

            # --- Seo parent külge ---
            $parentNum = $fm['parent_number']
            # Ristviide: kui parent_number puudub, aga parent_title viitab äsja loodud issue'le
            if ((-not $parentNum -or $parentNum -eq '~' -or $parentNum -eq '') -and $fm['parent_title'] -and $fm['parent_title'] -ne '~') {
                $refTitle = $fm['parent_title']
                if ($createdTitles.ContainsKey($refTitle)) {
                    $parentNum = $createdTitles[$refTitle]
                    Write-Host "  → Ristviide: parent_title '$refTitle' → #$parentNum" -ForegroundColor DarkGray
                }
            }
            if ($null -ne $parentNum -and $parentNum -ne '~' -and $parentNum -ne '') {
                $parentNodeId = Get-IssueNodeId -Number ([int]$parentNum)
                if ($parentNodeId) {
                    Write-Host "  → Seon parent #$parentNum külge..." -ForegroundColor DarkGray
                    $parentOk = Set-ParentIssue -ParentNodeId $parentNodeId -ChildNodeId $nodeId
                    if ($parentOk) {
                        Write-Host "  ✓ Parent: #$parentNum" -ForegroundColor Green
                    }
                }
            }

            # --- Projekti staatus ---
            $localStatus = $fm['project_status']
            if ($null -ne $localStatus -and $localStatus -ne '~' -and $null -ne $projectItemId) {
                Ensure-ProjectStatusMeta
                if ($null -ne $script:statusFieldId -and $script:statusOptions.ContainsKey($localStatus)) {
                    $optionId = $script:statusOptions[$localStatus]
                    $mutation = @'
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId
    itemId: $itemId
    fieldId: $fieldId
    value: { singleSelectOptionId: $optionId }
  }) {
    projectV2Item { id }
  }
}
'@
                    $resp = Invoke-GQL -Query $mutation -Vars @{
                        projectId = $PROJECT_ID
                        itemId    = $projectItemId
                        fieldId   = $script:statusFieldId
                        optionId  = $optionId
                    }
                    if ($resp -and -not $resp.errors) {
                        Write-Host "  ✓ Staatus → $localStatus" -ForegroundColor Green
                    }
                }
            }

            # --- Projekti sprint ---
            $localSprint = $fm['project_sprint']
            if ($null -ne $localSprint -and $localSprint -ne '~' -and $null -ne $projectItemId) {
                Ensure-ProjectStatusMeta
                if ($null -ne $script:sprintFieldId -and $script:sprintOptions.ContainsKey($localSprint)) {
                    $iterationId = $script:sprintOptions[$localSprint]
                    $sprintMutation = @'
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $iterationId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId
    itemId: $itemId
    fieldId: $fieldId
    value: { iterationId: $iterationId }
  }) {
    projectV2Item { id }
  }
}
'@
                    $resp = Invoke-GQL -Query $sprintMutation -Vars @{
                        projectId   = $PROJECT_ID
                        itemId      = $projectItemId
                        fieldId     = $script:sprintFieldId
                        iterationId = $iterationId
                    }
                    if ($resp -and -not $resp.errors) {
                        Write-Host "  ✓ Sprint → $localSprint" -ForegroundColor Green
                    }
                }
            }

            # --- Nimeta fail ümber ja uuenda frontmatter ---
            $now      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $bodyHash = Get-BodyHash $body

            # Ehita uus frontmatter
            $parentTitle = if ($fm['parent_title']) { $fm['parent_title'] } else { '~' }
            $epicNum     = if ($fm['epic_number'])  { $fm['epic_number']  } else { '~' }
            $epicTitle   = if ($fm['epic_title'])   { $fm['epic_title']   } else { '~' }
            $msNum       = if ($fm['milestone_number']) { $fm['milestone_number'] } else { '~' }
            $msDue       = if ($fm['milestone_due'])    { $fm['milestone_due']    } else { '~' }
            $closedAt    = if ($fm['closed_at'])    { $fm['closed_at']    } else { '~' }
            $subIssues   = if ($fm['sub_issues'] -is [array] -and $fm['sub_issues'].Count -gt 0) {
                '[' + (($fm['sub_issues'] | ForEach-Object { "`"$_`"" }) -join ', ') + ']'
            } else { '[]' }
            $labelsYaml  = if ($fm['labels'] -is [array] -and $fm['labels'].Count -gt 0) {
                '[' + (($fm['labels'] | ForEach-Object { "`"$_`"" }) -join ', ') + ']'
            } else { '[]' }
            $assignYaml  = if ($fm['assignees'] -is [array] -and $fm['assignees'].Count -gt 0) {
                '[' + (($fm['assignees'] | ForEach-Object { "`"$_`"" }) -join ', ') + ']'
            } else { '[]' }
            $msYaml      = if ($fm['milestone']) { "`"$($fm['milestone'])`"" } else { '~' }
            $statusYaml  = if ($localStatus) { $localStatus } else { '~' }
            $sprintYaml  = if ($fm['project_sprint'] -and $fm['project_sprint'] -ne '~') { "`"$($fm['project_sprint'])`"" } else { '~' }
            $itemIdYaml  = if ($projectItemId) { $projectItemId } else { '~' }

            # Escape title for YAML if needed
            $titleYaml = $title
            if ($title -match '[:\[\]{}#&*!|>''"%@`]' -or $title -match '^\s' -or $title -match '\s$') {
                $titleYaml = "`"$($title -replace '"', '\"')`""
            }
            $parentTitleYaml = $parentTitle
            if ($parentTitle -ne '~' -and ($parentTitle -match '[:\[\]{}#&*!|>''"%@`]' -or $parentTitle -match '^\s')) {
                $parentTitleYaml = "`"$($parentTitle -replace '"', '\"')`""
            }
            $epicTitleYaml = $epicTitle
            if ($epicTitle -ne '~' -and ($epicTitle -match '[:\[\]{}#&*!|>''"%@`]' -or $epicTitle -match '^\s')) {
                $epicTitleYaml = "`"$($epicTitle -replace '"', '\"')`""
            }

            $newFm = @"
---
number: $number
title: $titleYaml
type: $typeName
state: open
parent_number: $(if ($parentNum -and $parentNum -ne '~') { $parentNum } else { '~' })
parent_title: $parentTitleYaml
epic_number: $epicNum
epic_title: $epicTitleYaml
labels: $labelsYaml
milestone: $msYaml
milestone_number: $msNum
milestone_due: $msDue
assignees: $assignYaml
project_status: $statusYaml
project_sprint: $sprintYaml
project_item_id: $itemIdYaml
sub_issues: $subIssues
created_at: $now
updated_at: $now
closed_at: $closedAt
synced_at: $now
body_hash: $bodyHash
---

"@
            $newContent = $newFm + $body
            $newPath    = Join-Path (Split-Path $filePath -Parent) "$number.md"

            Write-Utf8Bom -Path $newPath -Content $newContent

            # Eemalda vana fail (kui erinev nimest)
            if ($filePath -ne $newPath -and (Test-Path $filePath)) {
                Remove-Item $filePath -Force
                Write-Host "  → Fail: $(Split-Path $filePath -Leaf) → $number.md" -ForegroundColor DarkGray
            }

            $createdTitles[$title] = $number
            $createOk++
            Start-Sleep -Milliseconds 500   # rate-limit paus
        }
    }

    Write-Host "`n  Uued issued: $createOk loodud, $createFail ebaõnnestunud"
} else {
    Write-Host "`n[2/6] Uusi issue'sid pole — vahelan." -ForegroundColor DarkGray
}

# =============================================================================
# 2. TUVASTA MUUDETUD ISSUED
# =============================================================================

Write-Host "`n[3/6] Tuvastab muudetud issued..." -ForegroundColor Cyan

$changedIssues = @{}   # number → @{ changes = @(...); fm = $fm }

foreach ($num in $localIssues.Keys) {
    $fm   = $localIssues[$num]
    $body = $fm['_body']

    # Kontrolli kas body on muudetud (body_hash võrdlus)
    $syncedHash  = $fm['body_hash']
    $currentHash = Get-BodyHash $body
    $bodyChanged = ($null -ne $syncedHash -and $syncedHash -ne $currentHash)

    # Kontrolli kas title on muudetud
    # NB: Title-t ei saa otseselt võrrelda, kuna YAML escaping muudab seda.
    # Push-ime title alati koos body-ga kui midagi on muudetud.

    $changes = @()

    if ($bodyChanged) {
        $changes += 'body'
    }

    # Märgi kõik muudetavad muudatused, mida saab kontrollida frontmatterist.
    # Kuna meil pole "vana" frontmatter-i eraldi, siis push-ime kõik
    # frontmatter väljad mis on olemas, AGA ainult siis, kui vähemalt body
    # on muudetud VÕI kasutaja on faili muutnud (faili mtime > synced_at).

    $syncedAt = Parse-IsoTimestamp $fm['synced_at']
    $fileMtime = (Get-Item $fm['_path']).LastWriteTimeUtc

    $fileModified = ($null -ne $syncedAt -and $fileMtime -gt $syncedAt.AddSeconds(5))

    if (-not $bodyChanged -and -not $fileModified) {
        continue   # Fail pole muutunud — jätame vahele
    }

    if ($fileModified -and -not $bodyChanged) {
        $changes += 'frontmatter'
    }

    $changedIssues[$num] = @{
        changes     = $changes
        fm          = $fm
        bodyChanged = $bodyChanged
    }
}

Write-Host "  Muudetud issued: $($changedIssues.Count)"

# Initsialiseeri kokkuvõtte muutujad (kasutatakse ka siis kui uuendamist pole)
$staleIssues = @()
$freshIssues = @()
$pushOk      = 0
$pushFail    = 0

if ($changedIssues.Count -eq 0) {
    Write-Host "`nOlemasolevad issued pole muudetud — vahelan uuendamise." -ForegroundColor DarkGray
} else {

# Loetle muudatused
foreach ($num in ($changedIssues.Keys | Sort-Object { [int]$_ })) {
    $entry   = $changedIssues[$num]
    $fm      = $entry.fm
    $changes = $entry.changes -join ', '
    Write-Host "  #$num $($fm['title']) — [$changes]" -ForegroundColor DarkGray
}

# =============================================================================
# 3. VÄRSKUSE KONTROLL — ära kirjuta üle GitHubis tehtud muudatusi
# =============================================================================

Write-Host "`n[4/6] Kontrollib issue värskust GitHubis..." -ForegroundColor Cyan

# Pärime muudetud issue'de updated_at GraphQL-iga (korraga kuni 100)
$numbersToCheck = @($changedIssues.Keys | Sort-Object { [int]$_ })

# Ehitame GraphQL päringu, mis küsib kõiki muudetud issue'sid korraga
$freshQuery = @'
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, after: $cursor, states: [OPEN, CLOSED]) {
      pageInfo { hasNextPage endCursor }
      nodes { number updatedAt }
    }
  }
}
'@

$ghUpdatedAt = @{}   # number → datetime
$cursor = $null

do {
    $vars = @{ owner = $ORG; name = $REPO_NAME }
    if ($cursor) { $vars['cursor'] = $cursor }

    $resp = Invoke-GQL -Query $freshQuery -Vars $vars
    if (-not $resp) { Write-Warning "  Värskuse kontroll ebaõnnestus"; break }

    foreach ($node in $resp.data.repository.issues.nodes) {
        $n = [int]$node.number
        if ($changedIssues.ContainsKey($n)) {
            $dt = [datetime]::MinValue
            if ([datetime]::TryParse([string]$node.updatedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$dt)) {
                $ghUpdatedAt[$n] = $dt.ToUniversalTime()
            }
        }
    }

    if ($resp.data.repository.issues.pageInfo.hasNextPage) {
        $cursor = $resp.data.repository.issues.pageInfo.endCursor
    } else {
        break
    }
} while ($true)

# Kontrolli konflikte
$staleIssues  = @()
$freshIssues  = @()

foreach ($num in $numbersToCheck) {
    $fm       = $changedIssues[$num].fm
    $syncedAt = Parse-IsoTimestamp $fm['synced_at']

    if ($null -eq $syncedAt) {
        Write-Warning "  #$num — synced_at puudub, jätame vahele ohutuse pärast"
        $staleIssues += $num
        continue
    }

    if ($ghUpdatedAt.ContainsKey($num)) {
        $ghTime = $ghUpdatedAt[$num]
        # Lisa 2 sekundi tolerants (GitHub ajatempli täpsus)
        if ($ghTime -gt $syncedAt.AddSeconds(2)) {
            Write-Warning "  #$num — GitHubis muudetud pärast viimast pull-i! (GH: $($ghTime.ToString('o')) > synced: $($syncedAt.ToString('o')))"
            Write-Warning "         Käivita .\Pull_issues.ps1 ja tee muudatused uuesti."
            $staleIssues += $num
            continue
        }
    }

    $freshIssues += $num
}

if ($staleIssues.Count -gt 0) {
    Write-Host "`n  ⚠ $($staleIssues.Count) issue'd vahele jäetud (vananenud): $($staleIssues -join ', ')" -ForegroundColor Yellow
}

if ($freshIssues.Count -eq 0) {
    Write-Host "`nÜhtegi olemasolevat issue'd ei saa push-ida. Käivita .\Pull_issues.ps1 kõigepealt." -ForegroundColor Yellow
}

Write-Host "  Värsked (push-itavad): $($freshIssues.Count)"

# =============================================================================
# 4. PUSH MUUDATUSED GITHUBI
# =============================================================================

Write-Host "`n[5/6] Push-ib muudatused GitHubi..." -ForegroundColor Cyan

foreach ($num in ($freshIssues | Sort-Object { [int]$_ })) {
    $entry = $changedIssues[$num]
    $fm    = $entry.fm
    $body  = $fm['_body']

    $issueLabel = "#$num $($fm['title'])"

    # =================================================================
    # 4a. Title ja body (gh issue edit)
    # =================================================================

    $editArgs = @()

    # Title — push-ime alati kui fail on muudetud
    if ($fm['title']) {
        # Eemalda YAML escape jutumärgid
        $cleanTitle = $fm['title']
        $editArgs += @("--title", $cleanTitle)
    }

    # Body — ainult kui body_hash erineb
    if ($entry.bodyChanged) {
        $editArgs += @("--body", $body)
    }

    # Milestone
    if ($fm.ContainsKey('milestone') -and $null -ne $fm['milestone']) {
        $editArgs += @("--milestone", $fm['milestone'])
    }

    if ($editArgs.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess($issueLabel, "gh issue edit (title/body/milestone)")) {
            $result = gh issue edit $num -R $REPO @editArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  ✗ #$num — gh issue edit ebaõnnestus: $result"
                $pushFail++
                continue
            }
            Write-Host "  ✓ #$num — title/body/milestone uuendatud" -ForegroundColor Green
        }
    }

    # =================================================================
    # 4b. Labels (delta: add/remove)
    # =================================================================

    $localLabels = @()
    if ($fm.ContainsKey('labels') -and $fm['labels'] -is [array]) {
        $localLabels = @($fm['labels'])
    }

    # Pärime praegused labels GitHubist
    $ghLabelsRaw = gh api "repos/$REPO/issues/$num/labels" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $ghLabels = @(($ghLabelsRaw | ConvertFrom-Json) | ForEach-Object { $_.name })

        $toAdd    = @($localLabels | Where-Object { $_ -notin $ghLabels })
        $toRemove = @($ghLabels | Where-Object { $_ -notin $localLabels })

        if ($toAdd.Count -gt 0) {
            $addStr = $toAdd -join ','
            if ($PSCmdlet.ShouldProcess($issueLabel, "Labels lisa: $addStr")) {
                gh issue edit $num -R $REPO --add-label $addStr 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ #$num — labels lisatud: $addStr" -ForegroundColor Green
                }
            }
        }

        if ($toRemove.Count -gt 0) {
            $removeStr = $toRemove -join ','
            if ($PSCmdlet.ShouldProcess($issueLabel, "Labels eemalda: $removeStr")) {
                gh issue edit $num -R $REPO --remove-label $removeStr 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ #$num — labels eemaldatud: $removeStr" -ForegroundColor Green
                }
            }
        }
    }

    # =================================================================
    # 4c. Assignees (delta: add/remove)
    # =================================================================

    $localAssignees = @()
    if ($fm.ContainsKey('assignees') -and $fm['assignees'] -is [array]) {
        $localAssignees = @($fm['assignees'])
    }

    $ghAssigneesRaw = gh api "repos/$REPO/issues/$num" --jq '.assignees[].login' 2>&1
    $ghAssignees = @()
    if ($LASTEXITCODE -eq 0 -and $ghAssigneesRaw) {
        $ghAssignees = @($ghAssigneesRaw -split '\r?\n' | Where-Object { $_ -ne '' })
    }

    if ($LASTEXITCODE -eq 0) {
        $assignAdd    = @($localAssignees | Where-Object { $_ -notin $ghAssignees })
        $assignRemove = @($ghAssignees | Where-Object { $_ -notin $localAssignees })

        if ($assignAdd.Count -gt 0) {
            $addStr = $assignAdd -join ','
            if ($PSCmdlet.ShouldProcess($issueLabel, "Assignees lisa: $addStr")) {
                gh issue edit $num -R $REPO --add-assignee $addStr 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ #$num — assignees lisatud: $addStr" -ForegroundColor Green
                }
            }
        }

        if ($assignRemove.Count -gt 0) {
            $removeStr = $assignRemove -join ','
            if ($PSCmdlet.ShouldProcess($issueLabel, "Assignees eemalda: $removeStr")) {
                gh issue edit $num -R $REPO --remove-assignee $removeStr 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ #$num — assignees eemaldatud: $removeStr" -ForegroundColor Green
                }
            }
        }
    }

    # =================================================================
    # 4d. State (open/closed)
    # =================================================================

    $localState = $fm['state']
    if ($null -ne $localState) {
        # Pärime GitHubist praeguse oleku
        $ghStateRaw = gh api "repos/$REPO/issues/$num" --jq '.state' 2>&1
        if ($LASTEXITCODE -eq 0) {
            $ghState = $ghStateRaw.Trim().ToLower()

            if ($localState -eq 'closed' -and $ghState -eq 'open') {
                if ($PSCmdlet.ShouldProcess($issueLabel, "Sulge issue")) {
                    gh issue close $num -R $REPO 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  ✓ #$num — suletud" -ForegroundColor Green
                    }
                }
            }
            elseif ($localState -eq 'open' -and $ghState -eq 'closed') {
                if ($PSCmdlet.ShouldProcess($issueLabel, "Ava issue uuesti")) {
                    gh issue reopen $num -R $REPO 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  ✓ #$num — taasavatud" -ForegroundColor Green
                    }
                }
            }
        }
    }

    # =================================================================
    # 4e. Project board status (GraphQL)
    # =================================================================

    $localStatus  = $fm['project_status']
    $projectItemId = $fm['project_item_id']

    if ($null -ne $localStatus -and $null -ne $projectItemId -and $projectItemId -ne '~') {
        Ensure-ProjectStatusMeta

        if ($null -ne $script:statusFieldId -and $script:statusOptions.ContainsKey($localStatus)) {
            $optionId = $script:statusOptions[$localStatus]

            $mutation = @'
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId
    itemId: $itemId
    fieldId: $fieldId
    value: { singleSelectOptionId: $optionId }
  }) {
    projectV2Item { id }
  }
}
'@

            if ($PSCmdlet.ShouldProcess($issueLabel, "Projekti staatus → $localStatus")) {
                $resp = Invoke-GQL -Query $mutation -Vars @{
                    projectId = $PROJECT_ID
                    itemId    = $projectItemId
                    fieldId   = $script:statusFieldId
                    optionId  = $optionId
                }
                if ($resp -and -not $resp.errors) {
                    Write-Host "  ✓ #$num — projekti staatus → $localStatus" -ForegroundColor Green
                } else {
                    Write-Warning "  ✗ #$num — projekti staatuse uuendamine ebaõnnestus"
                }
            }
        }
    }

    # =================================================================
    # 4f. Project board sprint/iteration (GraphQL)
    # =================================================================

    $localSprint = $fm['project_sprint']

    if ($null -ne $localSprint -and $localSprint -ne '~' -and $null -ne $projectItemId -and $projectItemId -ne '~') {
        Ensure-ProjectStatusMeta

        if ($null -ne $script:sprintFieldId -and $script:sprintOptions.ContainsKey($localSprint)) {
            $iterationId = $script:sprintOptions[$localSprint]

            $sprintMutation = @'
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $iterationId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId
    itemId: $itemId
    fieldId: $fieldId
    value: { iterationId: $iterationId }
  }) {
    projectV2Item { id }
  }
}
'@

            if ($PSCmdlet.ShouldProcess($issueLabel, "Projekti sprint → $localSprint")) {
                $resp = Invoke-GQL -Query $sprintMutation -Vars @{
                    projectId   = $PROJECT_ID
                    itemId      = $projectItemId
                    fieldId     = $script:sprintFieldId
                    iterationId = $iterationId
                }
                if ($resp -and -not $resp.errors) {
                    Write-Host "  ✓ #$num — projekti sprint → $localSprint" -ForegroundColor Green
                } else {
                    Write-Warning "  ✗ #$num — projekti sprindi uuendamine ebaõnnestus"
                }
            }
        }
    }

    $pushOk++
}

}  # end else ($changedIssues.Count -gt 0)

# =============================================================================
# 5. KOKKUVÕTE
# =============================================================================

Write-Host "`n[6/6] Kokkuvõte" -ForegroundColor Cyan

$action = if ($WhatIfPreference) { "Eelvaade" } else { "Push" }

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " $action lõpetatud!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Uued issued:        $createOk loodud, $createFail ebaõnnestunud  (leitud: $($newIssues.Count))"
Write-Host "  Muudetud issued:    $($changedIssues.Count)"
Write-Host "  Vahele jäetud:      $($staleIssues.Count) (vananenud)"
Write-Host "  Edukalt push-itud:  $pushOk"
if ($pushFail -gt 0) {
    Write-Host "  Ebaõnnestunud:      $pushFail" -ForegroundColor Red
}

if ($nodeIdFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "  ✗ Node ID ebaõnnestumised ($($nodeIdFailures.Count)):" -ForegroundColor Red
    Write-Host "    Need issued loodi, aga tüüp/projekt/parent jäid seadmata (GraphQL eventual consistency)." -ForegroundColor Red
    foreach ($nf in $nodeIdFailures) {
        Write-Host "    - #$($nf.Number) [$($nf.Type)] $($nf.Title)" -ForegroundColor Red
    }
    Write-Host "    → Paranda käsitsi või käivita push uuesti." -ForegroundColor Red
}

if ($staleIssues.Count -gt 0) {
    Write-Host ""
    Write-Host "  ⚠ Vananenud issue'd ($($staleIssues -join ', ')):" -ForegroundColor Yellow
    Write-Host "    Käivita .\Pull_issues.ps1, tee muudatused uuesti ja proovi uuesti." -ForegroundColor Yellow
}

if (-not $WhatIfPreference -and ($pushOk -gt 0 -or $createOk -gt 0)) {
    Write-Host ""
    Write-Host "  Soovitus: käivita .\Pull_issues.ps1 et sünkroniseerida synced_at ajatemplid." -ForegroundColor DarkGray
}
