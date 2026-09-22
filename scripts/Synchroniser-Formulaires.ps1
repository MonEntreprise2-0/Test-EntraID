# ============================================================================
# SCRIPT D'ORCHESTRATION : Synchroniser-Formulaires.ps1
# ============================================================================
# Rôle :
#   Synchronise automatiquement la liste des applications existantes dans
#   les menus déroulants des templates d'Issues GitHub (ex: 01-user-modify-app.yml).
#
# Auteur : Ardian Cloud IAM & DevOps
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DeclarationsDir = "declaration",

    [Parameter(Mandatory = $false)]
    [string]$IssueTemplatesDir = ".github/ISSUE_TEMPLATE"
)

Write-Host "🔄 Synchronisation des formulaires d'Issues GitHub..." -ForegroundColor Cyan

# 1. Détection de toutes les applications disponibles
$appDirs = Get-ChildItem -Path $DeclarationsDir -Directory | Where-Object { $_.Name -notlike "_*" } | Sort-Object Name
$appNames = [System.Collections.Generic.List[string]]::new()

foreach ($dir in $appDirs) {
    $yamlPath = Join-Path $dir.FullName "$($dir.Name).yaml"
    if (Test-Path $yamlPath) {
        $appNames.Add($dir.Name)
    }
}

Write-Host "📦 Applications déclarées détectées ($($appNames.Count)) : $($appNames -join ', ')" -ForegroundColor Gray

if ($appNames.Count -eq 0) {
    Write-Host "ℹ️ Aucune application déclarée à synchroniser." -ForegroundColor Gray
    exit 0
}

# 2. Mise à jour du template 01-user-modify-app.yml
$modifyTemplatePath = Join-Path $IssueTemplatesDir "01-user-modify-app.yml"
if (Test-Path $modifyTemplatePath) {
    $content = Get-Content $modifyTemplatePath -Raw -Encoding UTF8

    $optionsBlock = ($appNames | ForEach-Object { "        - $_" }) -join "`r`n"
    $regex = '(?s)(id:\s*app_name\s*\r?\n\s*attributes:\s*\r?\n\s*label:[^\r\n]*\r?\n\s*description:[^\r\n]*\r?\n\s*options:\s*\r?\n)(.*?)(?=\r?\n\s*validations:|\Z)'

    if ($content -match $regex) {
        $updatedContent = [regex]::Replace($content, $regex, "${1}$optionsBlock")
        [System.IO.File]::WriteAllText($modifyTemplatePath, $updatedContent, [System.Text.Encoding]::UTF8)
        Write-Host "✅ Template '$modifyTemplatePath' mis à jour." -ForegroundColor Green
    } else {
        Write-Verbose "Section options introuvable dans '$modifyTemplatePath'."
    }
}

Write-Host "🎉 Synchronisation des formulaires terminée." -ForegroundColor Green
exit 0
