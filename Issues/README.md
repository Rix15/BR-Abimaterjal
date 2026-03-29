# Issues — GitHub Sync

This folder contains scripts that **pull** and **push** the live state of all
GitHub Issues from [TalTech-ITB/ServiceFlow](https://github.com/TalTech-ITB/ServiceFlow).

- `Pull_issues.ps1` downloads the current GitHub state into `Bodies/` and
  `metadata/` (read-only, safe to re-run any time).
- `push_issues.ps1` **creates new** and **updates existing** issues on GitHub.
  For existing issues it compares locally edited `.md` files and pushes only
  changed fields (title, body, labels, milestone, assignees, state, parent,
  project status).  For new issues it creates them, sets the issue type,
  adds them to the project board, and links parent-child relationships.

**GitHub remains the single source of truth.** Pull first, edit locally, push
back. The push script never deletes issues.

---

## Folder structure

```
Issues/
├── README.md              ← this file
├── config.ps1             ← shared constants (repo, org IDs, folder map)
├── Pull_issues.ps1        ← pull: GitHub → local
├── push_issues.ps1        ← push: local → GitHub
│
├── Bodies/
│   ├── epics/
│   │   └── {number}.md   ← one file per Epic issue
│   ├── features/
│   │   └── {number}.md   ← one file per Feature / User Story issue
│   └── tasks/
│       └── {number}.md   ← one file per Task or Bug issue
│
└── metadata/
    ├── milestones.json    ← all repo milestones (title, due date, state)
    ├── labels.json        ← all repo labels (name, colour, description)
    ├── project.json       ← project fields, status options, sprint iterations
    ├── index.json         ← flat map: issue number → title, type, folder, state
    └── hierarchy.md       ← human-readable Epic → Feature → Task tree (AI context)
```

---

## File naming

Files are named after the **GitHub issue number** (`87.md`), not the original
planning code (`us02_1_t1.md`).  This means:

- A file is created once and never renamed, even if the issue is reparented,
  retitled, or re-typed on GitHub.
- The folder (`epics/`, `features/`, `tasks/`) reflects the current issue type.
  If an issue's type changes on GitHub, re-running sync will write the new
  content; moving the file to the correct folder is then a one-command cleanup
  (the old file lingers until removed manually, but `index.json` always reflects
  the current folder).

### New issues (not yet on GitHub)

New issue files use a **temporary filename** (any name ending in `.md`) and
have `number: new` in the frontmatter.  After `push_issues.ps1` creates them
on GitHub, they are **automatically renamed** from the temp name to
`{number}.md` and the frontmatter is rewritten with the real GitHub number and
metadata.

---

## File format

Every `.md` file starts with a YAML frontmatter block followed by the exact
issue body from GitHub:

```yaml
---
number: 87
title: "Tööaja automaattäide ja rea summa arvutus"
type: Task
state: open
parent_number: 14
parent_title: "Materjalide ja töötundide andmemudel"
epic_number: 3
epic_title: "EPIC 3: Mobiilne laohaldus ja välispetsialisti tegevused (Mobile Operations)"
labels: ["must-have", "page", "codeunit"]
milestone: "Sprint 3: Mobiilne laohaldus"
milestone_number: 3
milestone_due: 2025-04-15
assignees: ["username"]
project_status: "In Progress"
project_item_id: PVTI_lADOD2AcDc4BQnqyzgfYzjE
sub_issues: []
created_at: 2025-01-10T12:00:00Z
updated_at: 2025-03-01T09:30:00Z
closed_at: ~
synced_at: 2026-03-03T10:00:00Z
body_hash: a1b2c3d4e5f6...
---

{exact GitHub issue body text follows here}
```

The `parent_number` / `parent_title` always refer to the direct parent (one
level up).  The `epic_number` / `epic_title` walk up the chain a second level
if needed (Task → Feature → Epic), so every file knows its top-level Epic
regardless of its own type.

---

## Creating new issues

`push_issues.ps1` can **create brand-new issues** on GitHub.  Place a `.md`
file in the correct `Bodies/` subfolder with `number: new` in the frontmatter.

### Minimal frontmatter for a new issue

```yaml
---
number: new
title: "My new issue title"
type: Epic          # Epic | Feature | Task | Bug
state: open
parent_number: ~    # existing GitHub number, or ~ if none / resolved via parent_title
parent_title: ~     # used for cross-referencing other new issues (see below)
labels: ["label1", "label2"]
milestone: ~        # milestone title string, or ~
assignees: ["username1"]
project_status: Todo
---

Issue body text goes here (Markdown).
```

### Required fields

| Field | Required | Notes |
|-------|----------|-------|
| `number` | **yes** | Must be literally `new` (or `0`) |
| `title` | **yes** | The GitHub issue title |
| `type` | recommended | `Epic`, `Feature`, `Task`, or `Bug`. If omitted, inferred from folder name |
| `state` | no | Defaults to `open` |
| `parent_number` | no | The GitHub issue number of the parent. Set `~` if no parent or if using `parent_title` cross-reference |
| `parent_title` | no | **Cross-reference**: exact title of another new issue being created in the same batch (see below) |
| `labels` | no | Array of label name strings. Labels must already exist in the repo |
| `milestone` | no | Milestone title string. Must already exist in the repo |
| `assignees` | no | Array of GitHub usernames |
| `project_status` | no | Board column name: `Todo`, `In progress`, `Done`, etc. |

### Folder placement

Place the file in the correct subfolder based on issue type:

| Type | Folder |
|------|--------|
| Epic | `Bodies/epics/` |
| Feature | `Bodies/features/` |
| Task / Bug | `Bodies/tasks/` |

### Filename convention for new issues

Use **any descriptive filename** ending in `.md`:
- `new_my_epic.md`
- `new_us_login_flow.md`
- `new_task_fix_bug.md`

The script will **rename** the file to `{number}.md` after successful creation.

### Parent-child cross-referencing (new-to-new)

When creating multiple related issues in one batch (e.g., an Epic + Feature +
Task), use `parent_title` to link them **by title** — the script resolves them
automatically.

**How it works:**
1. The script sorts new issues by type priority: **Epic → Feature → Task**
2. Parents are always created before children
3. After each issue is created, the script records `title → number`
4. When processing children, if `parent_number` is `~` but `parent_title`
   matches a just-created issue, the parent number is resolved automatically

**Example — 3 files created together:**

`Bodies/epics/new_reporting.md`:
```yaml
---
number: new
title: "EPIC 8: Aruandlus ja analüütika"
type: Epic
state: open
parent_number: ~
labels: ["must-have"]
project_status: Todo
---
Aruandluse epicu kirjeldus.
```

`Bodies/features/new_us_dashboard.md`:
```yaml
---
number: new
title: "Juhtpaneeli aruanded"
type: Feature
state: open
parent_number: ~
parent_title: "EPIC 8: Aruandlus ja analüütika"
labels: ["must-have", "page"]
milestone: "Sprint 4: Aruandlus"
project_status: Todo
---
Kasutajana tahan näha koondvaateid.
```

`Bodies/tasks/new_task_kpi_page.md`:
```yaml
---
number: new
title: "Loo KPI lehekülg"
type: Task
state: open
parent_number: ~
parent_title: "Juhtpaneeli aruanded"
labels: ["must-have", "page"]
milestone: "Sprint 4: Aruandlus"
assignees: ["dev1"]
project_status: Todo
---
Loo BC-s KPI page.
```

**Result after push:**
- Epic created as `#65`, Feature as `#66` (parent → `#65`), Task as `#67` (parent → `#66`)
- Files renamed: `new_reporting.md` → `65.md`, etc.
- All three have correct issue type, project board status, and parent-child links

### Linking to existing issues

To parent a new issue under an **already existing** GitHub issue, use
`parent_number` with the real number:

```yaml
parent_number: 14
```

You can also set both for clarity (but `parent_number` takes precedence when
it's a real number):

```yaml
parent_number: 14
parent_title: "Materjalide ja töötundide andmemudel"
```

### What the create flow does (6 steps per issue)

1. **Duplicate check** — searches GitHub for an issue with the exact same title;
   skips if found
2. **`gh issue create`** — creates via REST with title, body, labels, milestone,
   assignees
3. **Set issue type** — GraphQL `updateIssue` mutation (Epic/Feature/Task/Bug)
4. **Add to project** — GraphQL `addProjectV2ItemById` mutation
5. **Set parent** — GraphQL `addSubIssue` mutation (if `parent_number` or
   `parent_title` resolves to a valid issue)
6. **Set project status** — GraphQL `updateProjectV2ItemFieldValue` (e.g. Todo)

After all steps, the file is rewritten with real GitHub metadata and renamed.

### Fields you do NOT need to set for new issues

These are auto-populated after creation:

| Field | Auto-set to |
|-------|-------------|
| `number` | Real GitHub issue number |
| `parent_number` | Resolved from cross-reference or kept as-is |
| `parent_title` | Kept from frontmatter |
| `epic_number` / `epic_title` | Kept from frontmatter (or `~`) |
| `project_item_id` | From `addProjectV2ItemById` response |
| `body_hash` | SHA-256 of the body at creation time |
| `created_at` / `updated_at` / `synced_at` | Current UTC timestamp |
| `sub_issues` | Empty `[]` (populated on next pull) |

> **Note:** `created_at` and `updated_at` are stored as ISO 8601 strings
> (`2026-03-03T13:01:48Z`).  `synced_at` is always in ISO 8601 and represents
> the moment the local file was last written — used for conflict detection by
> `push_issues.ps1`.  `body_hash` is a SHA-256 hex digest of the issue body at
> sync time — the push script compares it against the current local body to
> detect whether you actually edited anything.  `project_item_id` is the
> GitHub Projects V2 item ID needed to update the project board status column.

---

## How the pull works

`Pull_issues.ps1` runs seven phases in sequence:

| Phase | What it does |
|-------|-------------|
| **1** | Fetches all milestones and labels via the GitHub REST API → `metadata/milestones.json`, `metadata/labels.json` |
| **2** | Fetches project field definitions (status options, sprint iterations) via GraphQL → `metadata/project.json` |
| **3** | Pages through every issue in the repo (open + closed) via a GraphQL query that fetches title, body, type, parent chain, sub-issues, labels, milestone, and assignees in one round-trip per 100 issues |
| **4** | Fetches the project board status (e.g. “In Progress”, “Done”), sprint iteration, and **project item ID** for each issue via a second paginated GraphQL query |
| **5** | Writes one `.md` per issue (YAML frontmatter incl. `project_item_id` and `body_hash` + body) and writes `metadata/index.json` |
| **6** | Builds `metadata/hierarchy.md` — a human-readable Epic → Feature → Task tree with state checkboxes, labels, milestones and project statuses, generated entirely from the in-memory data already fetched in phases 3–4 (no extra API calls) |

Re-running is always safe — every file is simply overwritten with the latest
data from GitHub.  Closed issues are kept on disk with `state: closed` and a
`closed_at` timestamp; nothing is ever deleted automatically.

---

## Prerequisites

1. **GitHub CLI** installed and authenticated:
   ```powershell
   gh auth status
   ```
   Required OAuth scopes: `repo`, `read:org`, `read:project`

2. **PowerShell 7+** (uses `ConvertFrom-Json -AsHashtable` and other PS7 features)

---

## Running the pull

```powershell
cd C:\repo\ITB2204-ISA4\Abimaterjal\Issues
.\Pull_issues.ps1
```

Expected output:

```
[1/7] Fetching repo metadata (milestones, labels)...
  Milestones: 6 → metadata\milestones.json
  Labels:     19 → metadata\labels.json

[2/7] Fetching project metadata (fields, options)...
  Project: 'ServiceFlow' → metadata\project.json (16 fields)

[3/7] Fetching all issues (paginated)...
  Lehekülg 1 — 64 issue'd (kokku: 64)
  Kokku: 64 issue'd

[4/7] Fetching project item statuses...
  Projekti staatused: 64 kirjet

[5/7] Writing issue files...
  Kirjutatud: 6 epics, 21 features, 37 tasks
  Index: 64 kirjet → metadata\index.json

[6/7] Cleaning up stale files...
  Vanad failid puuduvad — midagi ei eemaldatud.

[7/7] Building hierarchy.md...
  Hierarchy: 6 epics, 21 features, 37 tasks → metadata\hierarchy.md

========================================
 Sünkroniseerimine lõpetatud!
========================================
  Bodies\epics\{nr}.md       — 6 faili
  Bodies\features\{nr}.md    — 21 faili
  Bodies\tasks\{nr}.md       — 37 faili
  metadata\milestones.json
  metadata\labels.json
  metadata\project.json
  metadata\index.json
  metadata\hierarchy.md     ← AI töövoo kontekstifail
```

---

## Relationship to IssueLoomine/

| Folder | Purpose | Direction |
|--------|---------|-----------|
| `IssueLoomine/` | **Legacy** — created initial issues from planning files (3-step scripts). No longer needed for new issues. | local → GitHub (create only) |
| `Issues/` — `Pull_issues.ps1` | Mirrors the live GitHub state locally | GitHub → local |
| `Issues/` — `push_issues.ps1` | **Creates new** and **updates existing** issues | local → GitHub (create + update) |

`Issues/` has no dependency on any file in `IssueLoomine/`.

---

## hierarchy.md — AI workflow context file

`metadata/hierarchy.md` is regenerated every pull and is the primary input for
AI-assisted development sessions.  It shows the full project tree at a glance:

```markdown
## Epic #1 — EPIC 1: Projekti vundament ja baasandmed (Foundation)

### [ ] Feature #7 — Projekti infrastruktuuri ja AL keskkonna seadistamine
**Milestone:** Sprint 1: Vundament · **Labels:** `must-have` `setup`

  - [ ] **#28** Initsialiseeri AL projekt ja seadista app.json · Sprint 1 `must-have` `setup`
  - [x] **#29** GitHub repositoorium ja branchide kaitsereeglid · Sprint 1 `must-have`
  - [ ] **#30** VS Code workspace setup tiimile · Sprint 1 `must-have` `setup`
```

**Typical AI session:**
> "Read `metadata/hierarchy.md` and `Bodies/features/11.md`. Let's complete
> Feature #11. Which tasks are open and what does each one need?"

The AI immediately has: which Epic the feature belongs to, the full acceptance
criteria body, and the complete task list with real completion state — without
opening any other file.

When a task is closed on GitHub and you re-run `Pull_issues.ps1`, its checkbox
flips from `[ ]` to `[x]` automatically.

---

## push_issues.ps1 — Create & update issues

`push_issues.ps1` reads every `.md` file under `Bodies/`, **creates new issues**
(where `number: new`) and **updates existing ones** by detecting which fields
changed since the last pull and pushing only the deltas to GitHub.

### What can be pushed

| Field | How it's pushed |
|-------|-----------------|
| Title, body | `gh issue edit` (REST) |
| Labels (add/remove delta) | `gh issue edit --add-label / --remove-label` |
| Milestone | `gh issue edit --milestone` |
| Assignees (add/remove delta) | `gh issue edit --add-assignee / --remove-assignee` |
| Open → closed | `gh issue close` |
| Closed → open | `gh issue reopen` |
| Project board status | GraphQL `updateProjectV2ItemFieldValue` (uses `project_item_id`) |

> **Not supported for existing issues (require org-admin or not yet implemented):**
> deleting issues, changing issue type, reparenting.  These must be done on
> GitHub directly.  (New issues DO get type, parent, and project assignment
> during creation.)

### Safety mechanisms

1. **Body hash** — the pull stores `body_hash` (SHA-256 of the GitHub body).
   If the local body still matches this hash, the body is skipped even if other
   frontmatter fields changed.  Only genuinely edited bodies are pushed.

2. **Freshness check** — before pushing, the script re-fetches `updated_at`
   from GitHub for every issue it intends to update.  If GitHub's timestamp is
   newer than `synced_at`, the issue is **skipped with a warning** — you must
   pull first to incorporate the remote changes.

3. **Dry-run mode** — run with `-WhatIf` to see what would be pushed without
   touching GitHub.

4. **No deletions** — the script never deletes issues or removes them from the
   project board.

### Running the push

```powershell
cd C:\repo\ITB2204-ISA4\Abimaterjal\Issues

# Preview changes (no writes)
.\push_issues.ps1 -WhatIf

# Push for real
.\push_issues.ps1
```

### Typical workflow — editing existing issues

```
1. .\Pull_issues.ps1              # get latest from GitHub
2. edit Bodies/tasks/42.md         # change title, body, labels, etc.
3. .\push_issues.ps1 -WhatIf      # preview
4. .\push_issues.ps1              # push
5. .\Pull_issues.ps1              # re-sync to confirm & update synced_at
```

### Typical workflow — creating new issues

```
1. .\Pull_issues.ps1                          # get latest (know existing numbers)
2. Create .md files in Bodies/{type}/ with number: new
   (use parent_title for cross-references between new issues)
3. .\push_issues.ps1 -WhatIf                  # preview — check create count
4. .\push_issues.ps1                          # create on GitHub
5. .\Pull_issues.ps1                          # re-sync all metadata
```

### Output summary

The script always shows a summary at the end:

```
========================================
 Push lõpetatud!
========================================
  Uued issued:        3 loodud, 0 ebaõnnestunud  (leitud: 3)
  Muudetud issued:    2
  Vahele jäetud:      0 (vananenud)
  Edukalt push-itud:  2
```

### Readiness checklist

- [x] YAML frontmatter with all editable fields
- [x] `synced_at` in correct UTC ISO 8601
- [x] `created_at` / `updated_at` in ISO 8601 UTC
- [x] `index.json` for quick lookup
- [x] Clean pull/create separation
- [x] `Invoke-GQL` helper stable (no `$args` collision)
- [x] REST calls paginated and error-handled
- [x] `project_item_id` in frontmatter ✅
- [x] `body_hash` in frontmatter ✅
- [x] Pre-push freshness check ✅
- [x] Dry-run mode (`-WhatIf`) ✅
- [x] New issue creation (`number: new`) ✅
- [x] Issue type assignment (Epic/Feature/Task/Bug) on create ✅
- [x] Project board add + status set on create ✅
- [x] Parent-child linking on create ✅
- [x] New-to-new cross-reference via `parent_title` ✅
- [x] Type-priority sorting (Epic → Feature → Task) ✅
- [x] Duplicate title check before create ✅
- [x] Auto file rename after create ✅

---

## Environment profiles (test / prod)

`config.ps1` supports switching between test and production environments via
`$ENV_PROFILE`:

```powershell
$ENV_PROFILE = "test"   # or "prod"
```

| Profile | Repo | Project |
|---------|------|---------|
| `test` | `RixTestOrg01/Repo03` | Project #4 |
| `prod` | `TalTech-ITB/ServiceFlow` | Project #17 |

Always test against the test org first. The issue type IDs and project IDs
differ per org — both sets are stored in `config.ps1`.
