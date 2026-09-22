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
    [string]$IssueTitle = "",

    [Parameter(Mandatory = $false)]
    [string]$IssueLabels = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "./parsed"
)

# Fonction utilitaire pour télécharger une pièce jointe (URL GitHub / user-attachments)
function Telecharger-FichierJoint {
    param(
        [string]$Url,
        [string]$DestinationPath
    )

    $headers = @{}
    $token = $env:GH_TOKEN
    if (-not $token) { $token = $env:GITHUB_TOKEN }
    if ($token) {
        $headers["Authorization"] = "token $token"
    }

    try {
        Write-Host "📥 Téléchargement de la pièce jointe : $Url" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -Headers $headers -UseBasicParsing -TimeoutSec 30
        if ((Test-Path $DestinationPath) -and (Get-Item $DestinationPath).Length -gt 0) {
            return $true
        }
    } catch {
        Write-Warning "Téléchargement avec jeton échoué : $_. Tentative sans en-tête d'authentification..."
        try {
            Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing -TimeoutSec 30
            if ((Test-Path $DestinationPath) -and (Get-Item $DestinationPath).Length -gt 0) {
                return $true
            }
        } catch {
            Write-Warning "Téléchargement sans en-tête échoué : $_. Tentative avec curl..."
            if (Get-Command "curl.exe" -ErrorAction SilentlyContinue) {
                & curl.exe -s -L -o "$DestinationPath" "$Url"
                if ((Test-Path $DestinationPath) -and (Get-Item $DestinationPath).Length -gt 0) {
                    return $true
                }
            }
            throw "Impossible de télécharger le fichier joint ($Url) : $_"
        }
    }
    return $false
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "📝 Analyse du formulaire de l'Issue GitHub..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Détection du type de scénario
# ---------------------------------------------------------------------------
$operation = "unknown"

# 1.1 Détection par Labels
$labelsList = @()
if (-not [string]::IsNullOrWhiteSpace($IssueLabels)) {
    $labelsList = $IssueLabels -split '[,;|]' | ForEach-Object { $_.Trim().ToLowerInvariant() }
}

if ($labelsList -contains "admin-creation" -or $labelsList -contains "admin-create") {
    $operation = "admin_create"
} elseif ($labelsList -contains "user-modification" -or $labelsList -contains "user-modify") {
    $operation = "user_modify"
} elseif ($labelsList -contains "admin-bulk") {
    $operation = "admin_bulk"
} elseif ($labelsList -contains "admin-reverse-engineering" -or $labelsList -contains "admin-import") {
    $operation = "admin_import"
}

# 1.2 Détection par Titre de l'Issue (si non déterminé par les labels)
if ($operation -eq "unknown" -and -not [string]::IsNullOrWhiteSpace($IssueTitle)) {
    if ($IssueTitle -match '\[(?:Création Admin|Creation Admin|Admin Create)\]') {
        $operation = "admin_create"
    } elseif ($IssueTitle -match '\[(?:Modification|User Modify)\]') {
        $operation = "user_modify"
    } elseif ($IssueTitle -match '\[(?:Masse Admin|Admin Bulk|Bulk)\]') {
        $operation = "admin_bulk"
    } elseif ($IssueTitle -match '\[(?:Import Entra ID|Import Entra|Admin Import)\]') {
        $operation = "admin_import"
    }
}

# 1.3 Détection par balises ou en-têtes Markdown du corps (Fallback)
if ($operation -eq "unknown") {
    if ($IssueBody -match '<!--\s*SCENARIO:\s*user_modify\s*-->' -or $IssueBody -match 'Nom de l''application à modifier' -or $IssueBody -match '###\s*Justification métier') {
        $operation = "user_modify"
    } elseif ($IssueBody -match '<!--\s*SCENARIO:\s*admin_create\s*-->' -or $IssueBody -match 'Nom de la Team GitHub') {
        $operation = "admin_create"
    } elseif ($IssueBody -match '<!--\s*SCENARIO:\s*admin_bulk\s*-->' -or $IssueBody -match 'Archive ZIP') {
        $operation = "admin_bulk"
    } elseif ($IssueBody -match '<!--\s*SCENARIO:\s*admin_import\s*-->' -or $IssueBody -match '(?i)(?:catalogues?|applications?).*?import') {
        $operation = "admin_import"
    }
}

[System.IO.File]::WriteAllText((Join-Path $OutputDir "operation_type.txt"), $operation, [System.Text.Encoding]::UTF8)
Write-Host "👉 Scénario identifié : $operation" -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# 2. Extraction du contenu YAML (Scénarios A et B)
# ---------------------------------------------------------------------------
$yamlPath = Join-Path $OutputDir "app.yaml"
$yamlContent = $null

# 2.1 Extraction depuis un bloc Markdown ```yaml ... ```
$yamlMatch = [regex]::Match($IssueBody, '```ya?ml\s*\r?\n([\s\S]*?)\r?\n```')
if ($yamlMatch.Success) {
    $yamlContent = $yamlMatch.Groups[1].Value.Trim()
    [System.IO.File]::WriteAllText($yamlPath, $yamlContent, [System.Text.Encoding]::UTF8)
    Write-Host "📄 Fichier YAML extrait depuis un bloc de code Markdown." -ForegroundColor Green
} else {
    # 2.2 Extraction depuis une pièce jointe glissée-déposée
    $attachmentMatch = [regex]::Match($IssueBody, '\[([^\]]*\.ya?ml)\]\((https:\/\/github\.com\/[^\)]+)\)')
    if (-not $attachmentMatch.Success) {
        $attachmentMatch = [regex]::Match($IssueBody, '\((https:\/\/github\.com\/(?:user-attachments\/files|[^\/]+\/[^\/]+\/files)\/[^\)]+)\)')
    }
    if (-not $attachmentMatch.Success) {
        $attachmentMatch = [regex]::Match($IssueBody, '(https:\/\/github\.com\/(?:user-attachments\/files|[^\/]+\/[^\/]+\/files)\/[^\s\)]+)')
    }

    if ($attachmentMatch.Success) {
        $fileUrl = if ($attachmentMatch.Groups.Count -gt 2 -and $attachmentMatch.Groups[2].Value) {
            $attachmentMatch.Groups[2].Value.Trim()
        } else {
            $attachmentMatch.Groups[1].Value.Trim()
        }

        try {
            $downloaded = Telecharger-FichierJoint -Url $fileUrl -DestinationPath $yamlPath
            if ($downloaded) {
                $yamlContent = [System.IO.File]::ReadAllText($yamlPath, [System.Text.Encoding]::UTF8)
                Write-Host "📄 Fichier YAML téléchargé avec succès depuis la pièce jointe." -ForegroundColor Green
            }
        } catch {
            Write-Error "Erreur lors du téléchargement du fichier YAML joint : $_"
        }
    }
}

if ($yamlContent) {
    # Extraction du nom d'application depuis le YAML
    if ($yamlContent -match '(?m)^\s*app_name\s*:\s*["'']?([a-zA-Z0-9_-]+)["'']?') {
        $extractedAppName = $Matches[1].Trim().ToLowerInvariant()
        [System.IO.File]::WriteAllText((Join-Path $OutputDir "app_name.txt"), $extractedAppName, [System.Text.Encoding]::UTF8)
        Write-Host "🏷️ app_name extrait du YAML : $extractedAppName" -ForegroundColor Gray
    }
}

# Safeguard : si app_name n'a pas été trouvé dans le YAML, extraction depuis le titre
if (-not (Test-Path (Join-Path $OutputDir "app_name.txt")) -and -not [string]::IsNullOrWhiteSpace($IssueTitle)) {
    if ($IssueTitle -match '\[(?:Création Admin|Creation Admin|Admin Create|Modification)\]\s*([a-zA-Z0-9_-]+)') {
        $extractedAppName = $Matches[1].Trim().ToLowerInvariant()
        [System.IO.File]::WriteAllText((Join-Path $OutputDir "app_name.txt"), $extractedAppName, [System.Text.Encoding]::UTF8)
        Write-Host "🏷️ app_name extrait depuis le titre : $extractedAppName" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# 3. Extraction de la Team GitHub (Scénario B)
# ---------------------------------------------------------------------------
if ($operation -eq "admin_create") {
    $teamMatch = [regex]::Match($IssueBody, '(?i)###\s*.*?Team GitHub.*?\r?\n\s*`?([a-zA-Z0-9_-]+)`?')
    if (-not $teamMatch.Success) {
        $teamMatch = [regex]::Match($IssueBody, '(?i)(?:team|équipe)\s*(?:github)?\s*:\s*`?([a-zA-Z0-9_-]+)`?')
    }
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
    $importMatch = [regex]::Match($IssueBody, '(?i)###\s*.*?(?:catalogues?|applications?).*?import.*?\r?\n([\s\S]*?)(?:\r?\n###|\Z)')
    if ($importMatch.Success) {
        $targetApps = $importMatch.Groups[1].Value.Trim()
        [System.IO.File]::WriteAllText((Join-Path $OutputDir "target_applications.txt"), $targetApps, [System.Text.Encoding]::UTF8)
        Write-Host "🎯 Catalogues/Applications cibles pour import : $targetApps" -ForegroundColor Gray
    }
}

Write-Host "✅ Analyse du formulaire terminée." -ForegroundColor Green
exit 0
