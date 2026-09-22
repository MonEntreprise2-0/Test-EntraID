# ============================================================================
# SCRIPT D'ORCHESTRATION : Deployer-Declarations.ps1
# ============================================================================
# Rôle :
#   Orchestre le déploiement CD vers Microsoft Entra ID :
#   - Applique l'état désiré de façon ordonnée et idempotente (Synchroniser-EtatEntra)
#   - Génère le compte-rendu Markdown pour la PR de déploiement
#   - Met à jour automatiquement le fichier .github/CODEOWNERS pour les nouvelles applications
#
# Auteur : Ardian Cloud IAM & DevOps
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DeclarationsDir = "declaration",

    [Parameter(Mandatory = $false)]
    [string]$OutputSummaryFile = "deployment_summary.md",

    [Parameter(Mandatory = $false)]
    [int]$PrNumber = 0
)

$moduleRoot = Join-Path $PSScriptRoot "../modules"
$resolvedModules = (Resolve-Path $moduleRoot).Path
$env:PSModulePath = "$resolvedModules$([System.IO.Path]::PathSeparator)$($env:PSModulePath)"

Import-Module ValidationSyntaxe -Force
Import-Module ConnexionGraph -Force
Import-Module GestionCatalogues -Force
Import-Module GestionAccessPackages -Force
Import-Module SynchronisationEntra -Force
Import-Module RapportsEtNotifications -Force

# 1. Connexion à Microsoft Graph
try {
    Connect-GraphSession | Out-Null
    Write-Host "✅ Connecté avec succès à Microsoft Graph API." -ForegroundColor Green
} catch {
    Write-Error "Échec de connexion à Microsoft Graph API : $_"
    exit 1
}

# 2. Chargement des déclarations YAML
$yamlFiles = Get-ChildItem -Path $DeclarationsDir -Recurse -Filter "*.yaml" | Where-Object { $_.Name -notlike "_*" }
if ($yamlFiles.Count -eq 0) {
    Write-Host "ℹ️ Aucun fichier YAML à déployer dans $DeclarationsDir." -ForegroundColor Cyan
    exit 0
}

$declarations = [System.Collections.Generic.List[PSObject]]::new()
foreach ($yf in $yamlFiles) {
    try {
        $doc = Lire-DeclarationYaml -Path $yf.FullName
        $declarations.Add($doc)
    } catch {
        Write-Error "Erreur lors de la lecture de $($yf.FullName) : $_"
        exit 1
    }
}

# 3. Synchronisation ordonnée vers Entra ID
$syncResult = Synchroniser-EtatEntra -Declarations $declarations

if (-not $syncResult.Success) {
    Write-Error "❌ Le déploiement Entra ID s'est achevé avec des erreurs."
    exit 1
}

# 4. Formatage du rapport post-déploiement
$summaryMd = Formater-RapportDeploiementCD -DeployedResources $syncResult.DeployedResources

if ($OutputSummaryFile) {
    [System.IO.File]::WriteAllText($OutputSummaryFile, $summaryMd, [System.Text.Encoding]::UTF8)
}

if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $summaryMd -Encoding UTF8
}

Write-Host "`n" + $summaryMd

# 5. Mise à jour automatique de CODEOWNERS
Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host "📝 ACTUALISATION DE LA GOUVERNANCE (CODEOWNERS)" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

$codeownersPath = Join-Path $PSScriptRoot "..\.github\CODEOWNERS"
$codeownersContent = if (Test-Path $codeownersPath) { Get-Content $codeownersPath -Raw -Encoding UTF8 } else { "# CODEOWNERS`n* @MonEntreprise2-0/admins`n" }

$changedCodeowners = $false
$ownerOrg = if ($env:GITHUB_REPOSITORY_OWNER) { $env:GITHUB_REPOSITORY_OWNER } else { "MonEntreprise2-0" }

# Extraction de l'équipe assignée depuis le commit de merge ou les variables
$assignedTeam = "admins"
try {
    $gitLog = git log -n 5 --pretty=%B 2>$null
    if ($gitLog -match 'GITHUB_TEAM:\s*([a-zA-Z0-9_-]+)') {
        $assignedTeam = $Matches[1].Trim()
    }
} catch {
    Write-Verbose "Impossible d'extraire la team depuis git log : $_"
}

$appDirs = Get-ChildItem -Path $DeclarationsDir -Directory | Where-Object { $_.Name -notlike "_*" }
foreach ($appDir in $appDirs) {
    $appName = $appDir.Name.ToLowerInvariant()
    $rulePrefix = "/declaration/$appName/"

    if (-not $codeownersContent.Contains($rulePrefix)) {
        $newRule = "$rulePrefix @$ownerOrg/$assignedTeam"
        Write-Host "➕ Nouvelle application détectée sans règle CODEOWNERS : $appName" -ForegroundColor Yellow
        Write-Host "   Ajout de la règle : $newRule" -ForegroundColor Green
        $codeownersContent += "`n$newRule"
        $changedCodeowners = $true
    }
}

if ($changedCodeowners) {
    [System.IO.File]::WriteAllText($codeownersPath, ($codeownersContent.Trim() + "`n"), [System.Text.Encoding]::UTF8)
    Write-Host "✅ Fichier CODEOWNERS actualisé." -ForegroundColor Green
} else {
    Write-Host "ℹ️ Le fichier CODEOWNERS est déjà à jour." -ForegroundColor Gray
}

exit 0
