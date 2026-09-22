# ============================================================================
# SCRIPT D'ORCHESTRATION : Traiter-DemandeIssue.ps1
# ============================================================================
# Rôle :
#   Analyse le formulaire de l'Issue GitHub, détecte le scénario (A, B, C, D),
#   extrait les données déclaratives (YAML, noms d'apps, team, zip URL)
#   et prépare les fichiers pour l'ouverture de la Pull Request.
#
# Auteur : Ardian Cloud IAM & DevOps
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IssueBody,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "./parsed"
)

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "📝 Analyse du corps de l'Issue GitHub..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Détection du type de scénario
# ---------------------------------------------------------------------------
$operation = "unknown"

if ($IssueBody -match '<!--\s*SCENARIO:\s*user_modify\s*-->' -or $IssueBody -match '### ✏️ Nom de l''application à modifier') {
    $operation = "user_modify"
} elseif ($IssueBody -match '<!--\s*SCENARIO:\s*admin_create\s*-->' -or $IssueBody -match '### 👥 Nom de la Team GitHub Propriétaire') {
    $operation = "admin_create"
} elseif ($IssueBody -match '<!--\s*SCENARIO:\s*admin_bulk\s*-->' -or $IssueBody -match '### 📦 Archive ZIP') {
    $operation = "admin_bulk"
} elseif ($IssueBody -match '<!--\s*SCENARIO:\s*admin_import\s*-->' -or $IssueBody -match '### 📋 Applications Entra ID à importer') {
    $operation = "admin_import"
}

[System.IO.File]::WriteAllText((Join-Path $OutputDir "operation_type.txt"), $operation, [System.Text.Encoding]::UTF8)
Write-Host "👉 Scénario identifié : $operation" -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# 2. Extraction du contenu YAML (Scénarios A et B)
# ---------------------------------------------------------------------------
$yamlMatch = [regex]::Match($IssueBody, '```ya?ml\s*\r?\n([\s\S]*?)\r?\n```')
if ($yamlMatch.Success) {
    $yamlContent = $yamlMatch.Groups[1].Value.Trim()
    $yamlPath = Join-Path $OutputDir "app.yaml"
    [System.IO.File]::WriteAllText($yamlPath, $yamlContent, [System.Text.Encoding]::UTF8)
    Write-Host "📄 Fichier YAML extrait vers $yamlPath." -ForegroundColor Green

    # Extraction du nom d'application depuis le YAML
    if ($yamlContent -match 'app_name:\s*["'']?([a-z0-9-]+)["'']?') {
        $extractedAppName = $Matches[1].Trim()
        [System.IO.File]::WriteAllText((Join-Path $OutputDir "app_name.txt"), $extractedAppName, [System.Text.Encoding]::UTF8)
        Write-Host "🏷️ app_name extrait : $extractedAppName" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# 3. Extraction de la Team GitHub (Scénario B)
# ---------------------------------------------------------------------------
if ($operation -eq "admin_create") {
    $teamMatch = [regex]::Match($IssueBody, '### 👥 Nom de la Team GitHub Propriétaire\s*\r?\n\s*`?([a-zA-Z0-9_-]+)`?')
    if ($teamMatch.Success) {
        $team = $teamMatch.Groups[1].Value.Trim()
        [System.IO.File]::WriteAllText((Join-Path $OutputDir "github_team.txt"), $team, [System.Text.Encoding]::UTF8)
        Write-Host "👥 Team GitHub extraite : $team" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# 4. Extraction de l'URL de l'archive ZIP (Scénario C)
# ---------------------------------------------------------------------------
if ($operation -eq "admin_bulk") {
    $zipMatch = [regex]::Match($IssueBody, '\[.*?\]\((https:\/\/github\.com\/[^\/]+\/[^\/]+\/assets\/[^\)]+|https:\/\/github\.com\/user-attachments\/files\/[^\)]+)\)')
    if (-not $zipMatch.Success) {
        $zipMatch = [regex]::Match($IssueBody, '(https:\/\/github\.com\/[^\s\)]+\.zip)')
    }
    if ($zipMatch.Success) {
        $zipUrl = $zipMatch.Groups[1].Value.Trim()
        [System.IO.File]::WriteAllText((Join-Path $OutputDir "zip_url.txt"), $zipUrl, [System.Text.Encoding]::UTF8)
        Write-Host "📦 URL ZIP extraite : $zipUrl" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# 5. Extraction des applications cibles (Scénario D - Import)
# ---------------------------------------------------------------------------
if ($operation -eq "admin_import") {
    $importMatch = [regex]::Match($IssueBody, '### 📋 Applications Entra ID à importer\s*\r?\n([\s\S]*?)(?:\r?\n###|\Z)')
    if ($importMatch.Success) {
        $targetApps = $importMatch.Groups[1].Value.Trim()
        [System.IO.File]::WriteAllText((Join-Path $OutputDir "target_applications.txt"), $targetApps, [System.Text.Encoding]::UTF8)
        Write-Host "🎯 Applications cibles pour import : $targetApps" -ForegroundColor Gray
    }
}

Write-Host "✅ Analyse du formulaire terminée." -ForegroundColor Green
exit 0
