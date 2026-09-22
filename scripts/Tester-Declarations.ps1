# ============================================================================
# SCRIPT D'ORCHESTRATION : Tester-Declarations.ps1
# ============================================================================
# Rôle :
#   Orchestre les validations de la CI en 2 étapes :
#   - Étape 1 : Validation de la syntaxe et conformité au schéma YAML v2
#   - Étape 2 : Contrôle bloquant SSoT (Single Source of Truth) contre Entra ID
#               et calcul différentiel (Plan) avant approbation humaine.
#
# Auteur : Ardian Cloud IAM & DevOps
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("All", "SchemaOnly", "SSoTAndPlan")]
    [string]$Stage = "All",

    [Parameter(Mandatory = $false)]
    [string]$DeclarationsDir = "declaration",

    [Parameter(Mandatory = $false)]
    [string]$OutputPlanFile = "plan_summary.md",

    [Parameter(Mandatory = $false)]
    [string[]]$ChangedFiles = @()
)

# Configuration de l'environnement de modules
$moduleRoot = Join-Path $PSScriptRoot "../modules"
$resolvedModules = (Resolve-Path $moduleRoot).Path
$env:PSModulePath = "$resolvedModules$([System.IO.Path]::PathSeparator)$($env:PSModulePath)"

Import-Module ValidationSyntaxe -Force
Import-Module ConnexionGraph -Force
Import-Module GestionCatalogues -Force
Import-Module GestionAccessPackages -Force
Import-Module SynchronisationEntra -Force
Import-Module RapportsEtNotifications -Force

# ---------------------------------------------------------------------------
# Sélection des fichiers à valider
# ---------------------------------------------------------------------------
$targetFiles = [System.Collections.Generic.List[string]]::new()

if ($ChangedFiles -and $ChangedFiles.Count -gt 0) {
    foreach ($f in $ChangedFiles) {
        if (-not [string]::IsNullOrWhiteSpace($f) -and (Test-Path $f) -and ($f.EndsWith(".yaml") -or $f.EndsWith(".yml"))) {
            $targetFiles.Add($f)
        }
    }
} else {
    $allYamls = Get-ChildItem -Path $DeclarationsDir -Recurse -Filter "*.yaml" | Where-Object { $_.Name -notlike "_*" }
    foreach ($yf in $allYamls) {
        $targetFiles.Add($yf.FullName)
    }
}

if ($targetFiles.Count -eq 0) {
    Write-Host "ℹ️ Aucun fichier déclaratif YAML à analyser." -ForegroundColor Cyan
    exit 0
}

Write-Host "🔍 Analyse de $($targetFiles.Count) fichier(s) déclaratif(s)..." -ForegroundColor Cyan

# ===========================================================================
# ÉTAPE 1 : Validation Syntaxe & Schéma
# ===========================================================================
if ($Stage -in @("All", "SchemaOnly")) {
    Write-Host "`n====================================================" -ForegroundColor Cyan
    Write-Host "📋 ÉTAPE 1 : SYNTAXE & CONFORMITÉ DU SCHÉMA YAML" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan

    $syntaxErrors = [System.Collections.Generic.List[string]]::new()
    $parsedDocs = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($file in $targetFiles) {
        Write-Host "Validation en cours : $file" -ForegroundColor Gray
        $valResult = Valider-StructureYaml -FilePath $file
        if ($valResult.IsValid) {
            Write-Host "  ✅ Conforme au schéma Ardian v2." -ForegroundColor Green
            $parsedDocs.Add($valResult.ParsedDoc)
        } else {
            Write-Host "  ❌ Échec de validation :" -ForegroundColor Red
            foreach ($err in $valResult.Errors) {
                Write-Host "     - $err" -ForegroundColor Red
                $syntaxErrors.Add("$file : $err")
            }
        }
    }

    if ($syntaxErrors.Count -gt 0) {
        Write-Error "❌ $($syntaxErrors.Count) erreur(s) de syntaxe ou de schéma détectée(s)."
        exit 1
    }

    Write-Host "✅ Étape 1 validée avec succès : tous les fichiers sont conformes." -ForegroundColor Green

    if ($Stage -eq "SchemaOnly") {
        exit 0
    }
}

# ===========================================================================
# ÉTAPE 2 : Contrôle SSoT Entra ID & Calcul du Diff (Plan)
# ===========================================================================
if ($Stage -in @("All", "SSoTAndPlan")) {
    Write-Host "`n====================================================" -ForegroundColor Cyan
    Write-Host "🔎 ÉTAPE 2 : CONTRÔLE SSoT ENTRA ID & CALCUL DU PLAN" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan

    # Chargement des documents déclaratifs s'ils ne le sont pas déjà
    $docsToInspect = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($file in $targetFiles) {
        try {
            $d = Lire-DeclarationYaml -Path $file
            $docsToInspect.Add($d)
        } catch {
            Write-Error "Erreur de lecture du fichier $file : $_"
            exit 1
        }
    }

    # 1. Connexion à Microsoft Graph
    try {
        Connect-GraphSession | Out-Null
    } catch {
        Write-Error "Échec de connexion à Microsoft Graph API : $_"
        exit 1
    }

    # 2. Contrôle bloquant SSoT
    Write-Host "Vérification de l'existence des ressources dans Microsoft Entra ID (SSoT)..." -ForegroundColor Cyan
    $ssotResult = Valider-RessourcesEntraId -Declarations $docsToInspect

    if (-not $ssotResult.IsValid) {
        Write-Host "❌ Contrôle SSoT échoué : des ressources déclarées sont manquantes dans Entra ID." -ForegroundColor Red

        # Formatage du rapport d'erreur pour la PR
        $planReport = Formater-RapportPlanCI -SSoTReport $ssotResult -ChangedFiles $targetFiles
        if ($OutputPlanFile) {
            [System.IO.File]::WriteAllText($OutputPlanFile, $planReport, [System.Text.Encoding]::UTF8)
        }

        # Écriture dans GITHUB_STEP_SUMMARY si exécuté dans GitHub Actions
        if ($env:GITHUB_STEP_SUMMARY) {
            Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $planReport -Encoding UTF8
        }

        Write-Host "`n" + $planReport
        exit 1
    }

    Write-Host "✅ Toutes les ressources cibles existent dans Entra ID." -ForegroundColor Green

    # 3. Calcul différentiel (Diff)
    Write-Host "Calcul du plan différentiel (Git vs Entra ID)..." -ForegroundColor Cyan
    $diffReport = Comparer-EtatEntra -Declarations $docsToInspect -SSoTPrerequisites $ssotResult

    # 4. Formatage du rapport final
    $finalReport = Formater-RapportPlanCI -DiffReport $diffReport -SSoTReport $ssotResult -ChangedFiles $targetFiles

    if ($OutputPlanFile) {
        [System.IO.File]::WriteAllText($OutputPlanFile, $finalReport, [System.Text.Encoding]::UTF8)
        Write-Host "📄 Rapport du plan généré dans '$OutputPlanFile'." -ForegroundColor Gray
    }

    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $finalReport -Encoding UTF8
    }

    Write-Host "`n" + $finalReport
    Write-Host "✅ Étape 2 validée avec succès. En attente de l'approbation humaine." -ForegroundColor Green
    exit 0
}
