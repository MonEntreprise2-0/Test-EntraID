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
    [int]$PrNumber = 0,

    [Parameter(Mandatory = $false)]
    [string[]]$ChangedFiles = @(),

    [Parameter(Mandatory = $false)]
    [switch]$All
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

# Détection de l'opération d'importation (admin_import / reverse engineering)
$isImportOperation = $false
try {
    $recentGitLog = git log -n 5 --pretty=%B 2>$null
    $recentLogText = if ($recentGitLog) { ($recentGitLog | Out-String) } else { "" }
    if ($recentLogText -match '\[admin_import\]' -or $recentLogText -match 'admin/import-entra-' -or $recentLogText -match '\[Import Entra ID\]') {
        $isImportOperation = $true
    }
} catch {
    Write-Verbose "Impossible d'analyser git log pour la détection d'import : $_"
}

if (-not $isImportOperation -and $PrNumber -gt 0 -and ($env:GITHUB_TOKEN -or $env:GH_PAT) -and $env:GITHUB_REPOSITORY) {
    try {
        $ghToken = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_PAT }
        $prUri = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)/pulls/$PrNumber"
        $ghHeaders = @{
            "Authorization" = "Bearer $ghToken"
            "Accept"        = "application/vnd.github.v3+json"
            "User-Agent"    = "Ardian-GitOps-Engine"
        }
        $prDetails = Invoke-RestMethod -Uri $prUri -Headers $ghHeaders -Method Get -ErrorAction SilentlyContinue
        if ($prDetails) {
            $headBranch = if ($prDetails.head -and $prDetails.head.ref) { $prDetails.head.ref } else { "" }
            $prTitle = if ($prDetails.title) { $prDetails.title } else { "" }
            if ($headBranch -like "*import-entra*" -or $prTitle -like "*[Import Entra ID]*" -or $prTitle -like "*admin_import*") {
                $isImportOperation = $true
            }
        }
    } catch {
        Write-Verbose "Impossible d'analyser la PR GitHub pour la détection d'import : $_"
    }
}

# Initialisation du Live PR Logging
$liveCommentId = 0
if ($PrNumber -gt 0) {
    $initMsg = if ($isImportOperation) {
        "### 📥 Enregistrement de l'importation Entra ID...`n`n*Validation en mode lecture seule (aucune écriture dans Entra ID)...*"
    } else {
        "### 🚀 Déploiement Microsoft Entra ID en cours...`n`n*Initialisation de l'orchestration CD PowerShell...*"
    }
    Write-Host "📡 Initialisation du Live Logging sur la Pull Request #$PrNumber..." -ForegroundColor Cyan
    $liveCommentId = New-LivePRComment -PrNumber $PrNumber -InitialMessage $initMsg
}

# 2. Chargement des déclarations YAML
$allYamlFiles = @(Get-ChildItem -Path $DeclarationsDir -Recurse -Filter "*.yaml" | Where-Object { $_.Name -notlike "_*" })
if ($allYamlFiles.Count -eq 0) {
    Write-Host "ℹ️ Aucun fichier YAML trouvé dans $DeclarationsDir." -ForegroundColor Cyan
    if ($liveCommentId -gt 0) {
        Update-LivePRComment -CommentId $liveCommentId -Message "### ℹ️ Déploiement Microsoft Entra ID`n`nAucun fichier YAML trouvé dans le répertoire `$DeclarationsDir`."
    }
    exit 0
}

$yamlFiles = @()

if ($All -or ($env:DEPLOY_ALL -eq 'true')) {
    Write-Host "🔄 Déploiement global forcé (-All / DEPLOY_ALL) : toutes les applications ($($allYamlFiles.Count)) seront analysées." -ForegroundColor Cyan
    $yamlFiles = $allYamlFiles
} elseif ($ChangedFiles -and $ChangedFiles.Count -gt 0) {
    Write-Host "🎯 Déploiement ciblé via paramètres : $($ChangedFiles -join ', ')" -ForegroundColor Cyan
    $normalizedTargets = @($ChangedFiles | ForEach-Object { $_.Trim().Replace('\', '/') })
    $yamlFiles = @($allYamlFiles | Where-Object {
        $fullPathNorm = $_.FullName.Replace('\', '/')
        $fileName = $_.Name
        $parentDir = $_.Directory.Name
        foreach ($target in $normalizedTargets) {
            if ($fullPathNorm -like "*$target*" -or $fileName -like "*$target*" -or $parentDir -eq $target) {
                return $true
            }
        }
        return $false
    })
} else {
    # Détection automatique via Git des fichiers modifiés
    $detectedRelFiles = @()
    try {
        $isGit = (git rev-parse --is-inside-work-tree 2>$null)
        if ($isGit -eq 'true') {
            $rawDiff = @(git diff --name-only HEAD~1 HEAD -- "$DeclarationsDir" 2>$null)
            if (-not $rawDiff -or $rawDiff.Count -eq 0) {
                $rawDiff = @(git diff-tree --no-commit-id --name-only -r HEAD -- "$DeclarationsDir" 2>$null)
            }
            if ($rawDiff -and $rawDiff.Count -gt 0) {
                $detectedRelFiles = @($rawDiff | Where-Object { $_ -match '\.ya?ml$' -and $_ -notmatch '(^|[/\\])_' })
            }
        }
    } catch {
        Write-Verbose "Détection git des fichiers modifiés impossible : $_"
    }

    if ($detectedRelFiles.Count -gt 0) {
        Write-Host "🎯 Détection automatique Git : $($detectedRelFiles.Count) fichier(s) déclaratif(s) modifié(s) :" -ForegroundColor Cyan
        $detectedRelFiles | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }

        $normalizedDetected = @($detectedRelFiles | ForEach-Object { $_.Trim().Replace('\', '/') })
        $yamlFiles = @($allYamlFiles | Where-Object {
            $fullPathNorm = $_.FullName.Replace('\', '/')
            $fileName = $_.Name
            $parentDir = $_.Directory.Name
            foreach ($d in $normalizedDetected) {
                $dBase = [System.IO.Path]::GetFileName($d)
                $dDirName = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($d))
                if ($fullPathNorm -like "*$d*" -or $fileName -eq $dBase -or ($dDirName -and $parentDir -eq $dDirName)) {
                    return $true
                }
            }
            return $false
        })
    } else {
        Write-Host "ℹ️ Aucune modification déclarative ciblée détectée via Git. Réconciliation de toutes les applications ($($allYamlFiles.Count))." -ForegroundColor Cyan
        $yamlFiles = $allYamlFiles
    }
}

if ($yamlFiles.Count -eq 0) {
    Write-Host "ℹ️ Aucun fichier déclaratif existant à déployer suite au filtrage." -ForegroundColor Cyan
    if ($liveCommentId -gt 0) {
        Update-LivePRComment -CommentId $liveCommentId -Message "### ℹ️ Déploiement Microsoft Entra ID`n`nAucun fichier déclaratif existant à déployer."
    }
    exit 0
}

Write-Host "📦 Fichiers YAML sélectionnés pour le déploiement ($($yamlFiles.Count)) :" -ForegroundColor Cyan
$yamlFiles | ForEach-Object { Write-Host "   - $($_.FullName)" -ForegroundColor White }

if ($isImportOperation) {
    Write-Host "`n====================================================" -ForegroundColor Cyan
    Write-Host "📥 SCÉNARIO D'IMPORTATION (REVERSE ENGINEERING) DÉTECTÉ" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "🔒 Le scénario d'importation depuis Microsoft Entra ID est STRICTEMENT EN LECTURE SEULE." -ForegroundColor Yellow
    Write-Host "   Les déclarations YAML importées représentent l'état existant dans Entra ID." -ForegroundColor Yellow
    Write-Host "   Aucune modification, création ou suppression ne sera appliquée à Entra ID." -ForegroundColor Green

    # 4. Formatage du rapport post-import en lecture seule
    $summaryMd = Formater-RapportImportCD -YamlFiles $yamlFiles

    if ($OutputSummaryFile) {
        [System.IO.File]::WriteAllText($OutputSummaryFile, $summaryMd, [System.Text.Encoding]::UTF8)
    }

    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $summaryMd -Encoding UTF8
    }

    if ($liveCommentId -gt 0) {
        Update-LivePRComment -CommentId $liveCommentId -Message $summaryMd
    } elseif ($PrNumber -gt 0) {
        $null = New-LivePRComment -PrNumber $PrNumber -InitialMessage $summaryMd
    }

    Write-Host "`n" + $summaryMd
} else {
    # 1. Connexion à Microsoft Graph (uniquement pour les déploiements réels)
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
}

# 5. Mise à jour automatique de CODEOWNERS
Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host "📝 ACTUALISATION DE LA GOUVERNANCE (CODEOWNERS)" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

$codeownersPath = Join-Path $PSScriptRoot "..\.github\CODEOWNERS"
$codeownersContent = if (Test-Path $codeownersPath) { Get-Content $codeownersPath -Raw -Encoding UTF8 } else { "# CODEOWNERS`n* @MonEntreprise2-0/admins`n/declaration/ @MonEntreprise2-0/admins`n" }

$ownerOrg = if ($env:GITHUB_REPOSITORY_OWNER) { $env:GITHUB_REPOSITORY_OWNER } else { "MonEntreprise2-0" }

# Extraction des métadonnées d'équipes depuis le commit de merge ou l'historique git
$assignedTeam = "admins"
$appToTeam = @{}

try {
    $gitLogRaw = git log -n 5 --pretty=%B 2>$null
    $gitLogText = if ($gitLogRaw) { ($gitLogRaw | Out-String) } else { "" }
    if ($gitLogText -match 'GITHUB_TEAM:\s*([a-zA-Z0-9_-]+)') {
        $assignedTeam = $Matches[1].Trim()
    }
    if ($gitLogText -match 'GITHUB_TEAMS_MAP:\s*([^\r\n]+)') {
        $pairs = $Matches[1].Trim() -split ';'
        foreach ($p in $pairs) {
            if ($p -match '^\s*([^=]+?)\s*=\s*(.+?)\s*$') {
                $catKey = $Matches[1].Trim().ToLowerInvariant()
                $teamVal = $Matches[2].Trim()
                $appToTeam[$catKey] = $teamVal
            }
        }
    }
} catch {
    Write-Verbose "Impossible d'extraire les équipes depuis git log : $_"
}

$lines = [System.Collections.Generic.List[string]]::new(($codeownersContent -split "`r?`n"))

# S'assurer de la présence de la règle par défaut /declaration/
$hasDeclDefault = $false
foreach ($l in $lines) {
    if ($l.Trim() -match '^\/declaration\/\s+@') {
        $hasDeclDefault = $true
        break
    }
}
if (-not $hasDeclDefault) {
    $inserted = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^\*\s+@') {
            $lines.Insert($i + 1, "/declaration/ @$ownerOrg/admins")
            $inserted = $true
            break
        }
    }
    if (-not $inserted) {
        $lines.Add("/declaration/ @$ownerOrg/admins")
    }
}

$changedCodeowners = $false
$appDirs = Get-ChildItem -Path $DeclarationsDir -Directory | Where-Object { $_.Name -notlike "_*" }
foreach ($appDir in $appDirs) {
    $dirName = $appDir.Name
    $appKey = $dirName.ToLowerInvariant()
    $cleanKey = ($appKey -replace '^(?i)cat-', '')

    # Équipe cible pour cette application
    $targetTeam = if ($appToTeam.ContainsKey($appKey)) {
        $appToTeam[$appKey]
    } elseif ($appToTeam.ContainsKey("cat-$cleanKey")) {
        $appToTeam["cat-$cleanKey"]
    } elseif ($appToTeam.ContainsKey($cleanKey)) {
        $appToTeam[$cleanKey]
    } elseif ($assignedTeam -and $assignedTeam -ne "admins") {
        $assignedTeam
    } else {
        $null
    }

    # Recherche si une règle existe déjà pour ce catalogue
    $foundIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i].Trim()
        if ($l -match "^\/declaration\/$([regex]::Escape($dirName))\/?\s+" -or
            $l -match "^\/declaration\/CAT-$([regex]::Escape($cleanKey))\/?\s+" -or
            $l -match "^\/declaration\/cat-$([regex]::Escape($cleanKey))\/?\s+") {
            $foundIndex = $i
            break
        }
    }

    if ($targetTeam) {
        # Double validation : équipe métier + admins
        $newRule = if ($targetTeam.ToLowerInvariant() -eq "admins") {
            "/declaration/$dirName/ @$ownerOrg/admins"
        } else {
            "/declaration/$dirName/ @$ownerOrg/$targetTeam @$ownerOrg/admins"
        }

        if ($foundIndex -ge 0) {
            if ($lines[$foundIndex] -ne $newRule) {
                Write-Host "🔄 Mise à jour de la règle CODEOWNERS pour $($dirName) : $newRule" -ForegroundColor Green
                $lines[$foundIndex] = $newRule
                $changedCodeowners = $true
            }
        } else {
            Write-Host "➕ Ajout de la règle CODEOWNERS pour $($dirName) : $newRule" -ForegroundColor Green
            $lines.Add($newRule)
            $changedCodeowners = $true
        }
    } else {
        # Si aucune team spécifique n'est passée dans le commit, mais qu'il n'y a pas de règle du tout pour ce dossier
        if ($foundIndex -lt 0) {
            $newRule = "/declaration/$dirName/ @$ownerOrg/admins"
            Write-Host "➕ Nouvelle application sans règle spécifique, assignation @admins : $newRule" -ForegroundColor Yellow
            $lines.Add($newRule)
            $changedCodeowners = $true
        }
    }
}

if ($changedCodeowners) {
    $newContent = ($lines -join "`n").Trim() + "`n"
    [System.IO.File]::WriteAllText($codeownersPath, $newContent, [System.Text.Encoding]::UTF8)
    Write-Host "✅ Fichier CODEOWNERS actualisé." -ForegroundColor Green
} else {
    Write-Host "ℹ️ Le fichier CODEOWNERS est déjà à jour." -ForegroundColor Gray
}

exit 0
