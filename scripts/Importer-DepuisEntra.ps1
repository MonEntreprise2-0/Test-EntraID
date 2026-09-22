# ============================================================================
# SCRIPT D'ORCHESTRATION : Importer-DepuisEntra.ps1
# ============================================================================
# Rôle :
#   Orchestre l'import et la rétro-ingénierie (Reverse Engineering) d'applications
#   et de catalogues existants depuis Microsoft Entra ID (Scénario D).
#   Vérifie la stricte conformité de la nomenclature des Access Packages.
#
# Auteur : Ardian Cloud IAM & DevOps
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Applications,

    [Parameter(Mandatory = $false)]
    [string]$DeclarationDir = "declaration",

    [Parameter(Mandatory = $false)]
    [string]$FallbackApproverEmail = "OrlaineLEKANEGUETSA@monentreprise123.onmicrosoft.com",

    [Parameter(Mandatory = $false)]
    [string]$OutputList = "imported_apps.txt",

    [Parameter(Mandatory = $false)]
    [string]$ErrorFile = "import_errors.txt",

    [Parameter(Mandatory = $false)]
    [string]$SummaryFile = "import_summary.md"
)

$moduleRoot = Join-Path $PSScriptRoot "../modules"
$resolvedModules = (Resolve-Path $moduleRoot).Path
$env:PSModulePath = "$resolvedModules$([System.IO.Path]::PathSeparator)$($env:PSModulePath)"

Import-Module ConnexionGraph -Force
Import-Module GestionCatalogues -Force
Import-Module GestionAccessPackages -Force
Import-Module ImportationEntra -Force

# Connexion à Microsoft Graph
try {
    Connect-GraphSession | Out-Null
    Write-Host "✅ Connecté à Microsoft Graph API." -ForegroundColor Green
} catch {
    $msg = "Échec de connexion à Microsoft Graph API : $_"
    Write-Error $msg
    if ($ErrorFile) { [System.IO.File]::WriteAllText($ErrorFile, $msg, [System.Text.Encoding]::UTF8) }
    exit 1
}

# Découpage des applications cibles
$rawList = $Applications -split '[,;\r\n]+'
$appNames = [System.Collections.Generic.List[string]]::new()
foreach ($item in $rawList) {
    $clean = $item.Trim()
    if (-not [string]::IsNullOrWhiteSpace($clean)) {
        $appNames.Add($clean)
    }
}

if ($appNames.Count -eq 0) {
    $msg = "Aucune application spécifiée pour l'import."
    Write-Error $msg
    if ($ErrorFile) { [System.IO.File]::WriteAllText($ErrorFile, $msg, [System.Text.Encoding]::UTF8) }
    exit 1
}

Write-Host "🔄 Démarrage de l'import pour $($appNames.Count) application(s)..." -ForegroundColor Cyan

$importedApps = [System.Collections.Generic.List[string]]::new()
$errors = [System.Collections.Generic.List[string]]::new()
$summaryRows = [System.Collections.Generic.List[string]]::new()

foreach ($appName in $appNames) {
    Write-Host "`nTraitement de l'application : '$appName'..." -ForegroundColor Yellow
    try {
        $res = Exporter-CatalogueVersYaml -TargetCatalogName $appName -DeclarationDir $DeclarationDir -FallbackApproverEmail $FallbackApproverEmail
        if ($res.Success) {
            $importedApps.Add($res.AppName)
            $statusText = if ($res.WasOverwritten) { "✅ Réécrit / Écrasé avec succès" } else { "✅ Importé avec succès" }
            $summaryRows.Add("| 📦 **$($res.CatalogName)** | ``$($res.AppName)`` | $($res.PackagesImported) | $statusText |")
        }
    } catch {
        $err = $_.Exception.Message
        Write-Host "❌ Erreur sur '$appName' : $err" -ForegroundColor Red
        $errors.Add("Application '$appName' : $err")
        $summaryRows.Add("| 📦 **$appName** | - | 0 | ❌ Échec : $err |")
    }
}

# Écriture de la liste des applications importées
if ($OutputList -and $importedApps.Count -gt 0) {
    [System.IO.File]::WriteAllLines($OutputList, $importedApps.ToArray(), [System.Text.Encoding]::UTF8)
}

# Génération du résumé Markdown
$sbSummary = [System.Text.StringBuilder]::new()
$sbSummary.AppendLine("## 📋 Résumé de l'importation depuis Microsoft Entra ID") | Out-Null
$sbSummary.AppendLine() | Out-Null
$sbSummary.AppendLine("| Catalogue Entra ID | Application Git (app_name) | Access Packages | Statut |") | Out-Null
$sbSummary.AppendLine("|---|---|---|---|") | Out-Null
foreach ($row in $summaryRows) {
    $sbSummary.AppendLine($row) | Out-Null
}

if ($SummaryFile) {
    [System.IO.File]::WriteAllText($SummaryFile, $sbSummary.ToString(), [System.Text.Encoding]::UTF8)
}

if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $sbSummary.ToString() -Encoding UTF8
}

# Gestion des erreurs bloquantes
if ($errors.Count -gt 0) {
    $fullError = ($errors -join "`n`n")
    if ($ErrorFile) {
        [System.IO.File]::WriteAllText($ErrorFile, $fullError, [System.Text.Encoding]::UTF8)
    }
    Write-Error "❌ Échec de l'import pour une ou plusieurs applications.`n$fullError"
    exit 1
}

Write-Host "`n🎉 Toutes les applications ont été importées avec succès !" -ForegroundColor Green
exit 0
