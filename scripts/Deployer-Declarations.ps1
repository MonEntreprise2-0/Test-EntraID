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

# Détection automatique du numéro de Pull Request
if ($PrNumber -le 0) {
    if ($env:PR_NUMBER) {
        $PrNumber = [int]$env:PR_NUMBER
    } else {
        # 1. Analyse de l'historique git log récent (conversion explicite en chaîne unique pour $Matches)
        try {
            $gitLogRaw = git log -n 10 --pretty=%B 2>$null
            $gitLogText = if ($gitLogRaw) { ($gitLogRaw | Out-String) } else { "" }
            if ($gitLogText -match 'Merge pull request #(\d+)') {
                $PrNumber = [int]$Matches[1]
            } elseif ($gitLogText -match '\(#(\d+)\)') {
                $PrNumber = [int]$Matches[1]
            }
        } catch {
            Write-Verbose "Impossible d'extraire le numéro de PR depuis git log : $_"
        }

        # 2. Fallback robuste via GitHub REST API si commit SHA et repository disponibles
        if ($PrNumber -le 0 -and ($env:GITHUB_TOKEN -or $env:GH_PAT) -and $env:GITHUB_REPOSITORY -and $env:GITHUB_SHA) {
            try {
                $ghToken = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_PAT }
                $ghUri = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)/commits/$($env:GITHUB_SHA)/pulls"
                $ghHeaders = @{
                    "Authorization" = "Bearer $ghToken"
                    "Accept"        = "application/vnd.github.v3+json"
                    "User-Agent"    = "Ardian-GitOps-Engine"
                }
                $ghPulls = Invoke-RestMethod -Uri $ghUri -Headers $ghHeaders -Method Get -ErrorAction Stop
                if ($ghPulls -and $ghPulls.Count -gt 0 -and $ghPulls[0].number) {
                    $PrNumber = [int]$ghPulls[0].number
                    Write-Host "🔍 PR #$PrNumber détectée via l'API GitHub pour le commit $($env:GITHUB_SHA)." -ForegroundColor Cyan
                }
            } catch {
                Write-Verbose "Impossible de récupérer la PR associée au commit via l'API GitHub : $_"
            }
        }
    }
}

# Initialisation du Live PR Logging
$liveCommentId = 0
if ($PrNumber -gt 0) {
    Write-Host "📡 Initialisation du Live Logging sur la Pull Request #$PrNumber..." -ForegroundColor Cyan
    $liveCommentId = New-LivePRComment -PrNumber $PrNumber -InitialMessage "### 🚀 Déploiement Microsoft Entra ID en cours...`n`n*Initialisation de l'orchestration CD PowerShell...*"
}

# 1. Connexion à Microsoft Graph
try {
    Connect-GraphSession | Out-Null
    Write-Host "✅ Connecté avec succès à Microsoft Graph API." -ForegroundColor Green
} catch {
    Write-Error "Échec de connexion à Microsoft Graph API : $_"
    if ($liveCommentId -gt 0) {
        Update-LivePRComment -CommentId $liveCommentId -Message "### ❌ Échec du déploiement Microsoft Entra ID`n`nImpossible de se connecter à Microsoft Graph API : $_"
    }
    exit 1
}

# 2. Chargement des déclarations YAML
$yamlFiles = Get-ChildItem -Path $DeclarationsDir -Recurse -Filter "*.yaml" | Where-Object { $_.Name -notlike "_*" }
if ($yamlFiles.Count -eq 0) {
    Write-Host "ℹ️ Aucun fichier YAML à déployer dans $DeclarationsDir." -ForegroundColor Cyan
    if ($liveCommentId -gt 0) {
        Update-LivePRComment -CommentId $liveCommentId -Message "### ℹ️ Déploiement Microsoft Entra ID`n`nAucun fichier YAML à déployer dans le répertoire `$DeclarationsDir`."
    }
    exit 0
}

$declarations = [System.Collections.Generic.List[PSObject]]::new()
foreach ($yf in $yamlFiles) {
    try {
        $doc = Lire-DeclarationYaml -Path $yf.FullName
        $declarations.Add($doc)
    } catch {
        Write-Error "Erreur lors de la lecture de $($yf.FullName) : $_"
        if ($liveCommentId -gt 0) {
            Update-LivePRComment -CommentId $liveCommentId -Message "### ❌ Erreur de lecture YAML`n`nErreur lors de la lecture de ``$($yf.FullName)`` : $_"
        }
        exit 1
    }
}

# 3. Synchronisation ordonnée vers Entra ID avec retour en direct
$syncResult = Synchroniser-EtatEntra -Declarations $declarations -LiveCommentId $liveCommentId

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

# Si le live comment n'avait pas été initialisé mais qu'on a un numéro de PR, on poste le rapport final
if ($liveCommentId -le 0 -and $PrNumber -gt 0) {
    Write-Host "📡 Publication du rapport final sur la Pull Request #$PrNumber..." -ForegroundColor Cyan
    $null = New-LivePRComment -PrNumber $PrNumber -InitialMessage $summaryMd
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
    $gitLogRaw = git log -n 5 --pretty=%B 2>$null
    $gitLogText = if ($gitLogRaw) { ($gitLogRaw | Out-String) } else { "" }
    if ($gitLogText -match 'GITHUB_TEAM:\s*([a-zA-Z0-9_-]+)') {
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
