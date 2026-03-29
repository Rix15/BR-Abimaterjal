# =============================================================================
# config.ps1 — GitHub Issues Sync ühisseaded
# Laetakse sisse: . "$PSScriptRoot\config.ps1"
# Salvestatud: UTF-8 with BOM
# =============================================================================

# =============================================================================
# KESKKONNA VALIK — muuda seda ühte rida: "test" | "prod"
# =============================================================================
$ENV_PROFILE = "bikerental"

# --- Profiilid ---------------------------------------------------------------
$_profiles = @{
    test = @{
        REPO           = "RixTestOrg01/Repo03"
        ORG            = "RixTestOrg01"
        ORG_ID         = "O_kgDODdrjOg"
        PROJECT_ID     = "PVT_kwDODdrjOs4BQnnb"
        PROJECT_NUMBER = 4
        TYPE_EPIC      = "IT_kwDODdrjOs4B4YjC"
        TYPE_FEATURE   = "IT_kwDODdrjOs4BuVKz"
        TYPE_TASK      = "IT_kwDODdrjOs4BuVKx"
        TYPE_BUG       = "IT_kwDODdrjOs4BuVKy"
    }
    prod = @{
        REPO           = "TalTech-ITB/ServiceFlow"
        ORG            = "TalTech-ITB"
        ORG_ID         = "O_kgDOD2AcDQ"
        PROJECT_ID     = "PVT_kwDOD2AcDc4BQnqy"
        PROJECT_NUMBER = 17
        TYPE_EPIC      = "IT_kwDOD2AcDc4B2tO9"
        TYPE_FEATURE   = "IT_kwDOD2AcDc4B2Eja"
        TYPE_TASK      = "IT_kwDOD2AcDc4B2EjY"
        TYPE_BUG       = "IT_kwDOD2AcDc4B2EjZ"
    }
    bikerental = @{
        REPO           = "TalTech-ITB/BC-Dev"
        ORG            = "TalTech-ITB"
        ORG_ID         = "O_kgDOD2AcDQ"
        PROJECT_ID     = "PVT_kwDOD2AcDc4BOeza"
        PROJECT_NUMBER = 2
        TYPE_EPIC      = "IT_kwDOD2AcDc4B2tO9"
        TYPE_FEATURE   = "IT_kwDOD2AcDc4B2Eja"
        TYPE_TASK      = "IT_kwDOD2AcDc4B2EjY"
        TYPE_BUG       = "IT_kwDOD2AcDc4B2EjZ"
    }
}

if (-not $_profiles.ContainsKey($ENV_PROFILE)) {
    throw "Tundmatu profiil '$ENV_PROFILE'. Lubatud: $($_profiles.Keys -join ', ')"
}

$_p            = $_profiles[$ENV_PROFILE]
$REPO           = $_p.REPO
$ORG            = $_p.ORG
$REPO_NAME      = ($REPO -split '/')[1]
$ORG_ID         = $_p.ORG_ID
$PROJECT_ID     = $_p.PROJECT_ID
$PROJECT_NUMBER = $_p.PROJECT_NUMBER
$TYPE_EPIC      = $_p.TYPE_EPIC
$TYPE_FEATURE   = $_p.TYPE_FEATURE
$TYPE_TASK      = $_p.TYPE_TASK
$TYPE_BUG       = $_p.TYPE_BUG

Write-Host "  Profiil: $ENV_PROFILE → $REPO" -ForegroundColor DarkGray

# --- Väljundkaustad ----------------------------------------------------------
$BASE_DIR       = "$PSScriptRoot"
$BODIES_DIR     = "$BASE_DIR\Bodies"
$EPICS_DIR      = "$BODIES_DIR\epics"
$FEATURES_DIR   = "$BODIES_DIR\features"
$TASKS_DIR      = "$BODIES_DIR\tasks"
$META_DIR       = "$BASE_DIR\metadata"

# --- Issue tüübi nimi → kausta teisendus -------------------------------------
# Kõik tundmatud tüübid lähevad features/ alla (turvaline vaikeväärtus)
$TYPE_FOLDER_MAP = @{
    "Epic"    = "epics"
    "Feature" = "features"
    "Task"    = "tasks"
    "Bug"     = "tasks"
}

# --- UTF-8 seadistus (eestikeelsed tähed) ------------------------------------
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding =
    New-Object System.Text.UTF8Encoding

# --- UTF-8 BOM encoder (failide kirjutamiseks) --------------------------------
$Utf8BomEncoding = New-Object System.Text.UTF8Encoding $true
