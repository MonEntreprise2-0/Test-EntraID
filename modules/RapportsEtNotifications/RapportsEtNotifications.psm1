# ============================================================================
# MODULE : RapportsEtNotifications
# ============================================================================
# Rôle :
#   Construit et formate les synthèses et rapports en Markdown pour les
#   commentaires de Pull Request GitHub et les GITHUB_STEP_SUMMARY.
#   Génère les blocs d'alerte GitHub (CAUTION, NOTE) pour les blocages SSoT
#   et les approbations requises.
# ============================================================================

<#
.SYNOPSIS
    Génère le commentaire Markdown complet pour l'Étape 2 de la validation CI.
.PARAMETER DiffReport
    Objet de résultat retourné par Comparer-EtatEntra.
.PARAMETER SSoTReport
    Objet de résultat retourné par Valider-RessourcesEntraId.
.PARAMETER ChangedFiles
    Liste des chemins de fichiers déclaratifs modifiés.
#>
function Formater-RapportPlanCI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $DiffReport = $null,

        [Parameter(Mandatory = $false)]
        $SSoTReport = $null,

        [Parameter(Mandatory = $false)]
        [string[]]$ChangedFiles = @()
    )

    $sb = [System.Text.StringBuilder]::new()

    # Cas 1 : Ressources bloquantes manquantes dans Entra ID (Échec SSoT)
    if ($SSoTReport -and -not $SSoTReport.IsValid) {
        $sb.AppendLine("## ❌ Étape 2 : Contrôle des Ressources — Échec du contrôle SSoT (Ressources manquantes dans Entra ID)") | Out-Null
        $sb.AppendLine() | Out-Null
        $sb.AppendLine("> [!CAUTION]") | Out-Null
        $sb.AppendLine("> ### 🚫 Ressources bloquantes à créer dans Entra ID :") | Out-Null
        $sb.AppendLine("> **Certaines ressources (groupes, rôles applicatifs ou utilisateurs) déclarées dans votre fichier YAML n'existent pas dans Microsoft Entra ID.**") | Out-Null
        $sb.AppendLine(">") | Out-Null
        $sb.AppendLine("> 💡 **Procédure de déblocage (Sans recréer d'Issue) :**") | Out-Null
        $sb.AppendLine("> 1. Créez les ressources manquantes directement dans le portail Microsoft Entra ID.") | Out-Null
        $sb.AppendLine("> 2. Cliquez sur le bouton **""Re-run jobs""** de cette Pull Request pour relancer immédiatement la vérification.") | Out-Null
        $sb.AppendLine(">") | Out-Null
        $sb.AppendLine("> **Détail des ressources manquantes détectées :**") | Out-Null

        if ($SSoTReport.MissingApps) {
            foreach ($app in $SSoTReport.MissingApps) {
                $sb.AppendLine("> - 📱 Application / Service Principal manquant : ``$app``") | Out-Null
            }
        }
        if ($SSoTReport.MissingAppRoles) {
            foreach ($role in $SSoTReport.MissingAppRoles) {
                $sb.AppendLine("> - 🔑 Rôle applicatif manquant : ``$role``") | Out-Null
            }
        }
        if ($SSoTReport.MissingGroups) {
            foreach ($grp in $SSoTReport.MissingGroups) {
                $sb.AppendLine("> - 👥 Groupe Entra ID manquant : ``$grp``") | Out-Null
            }
        }
        if ($SSoTReport.MissingSites) {
            foreach ($site in $SSoTReport.MissingSites) {
                $sb.AppendLine("> - 🌐 Site SharePoint introuvable : ``$site``") | Out-Null
            }
        }
        if ($SSoTReport.MissingUsers) {
            foreach ($usr in $SSoTReport.MissingUsers) {
                $sb.AppendLine("> - 👤 Utilisateur / Owner manquant : ``$usr``") | Out-Null
            }
        }

        return $sb.ToString()
    }

    # Cas 2 : Succès SSoT — Affichage du plan de déploiement
    $sb.AppendLine("## ✅ Étape 2 : Contrôle des Ressources — Ressources validées — Plan prêt pour approbation") | Out-Null
    $sb.AppendLine() | Out-Null

    $creates = if ($DiffReport) { $DiffReport.CreatesCount } else { 0 }
    $updates = if ($DiffReport) { $DiffReport.UpdatesCount } else { 0 }
    $deletes = if ($DiffReport) { $DiffReport.DeletesCount } else { 0 }

    $sb.AppendLine("### 📋 Synthèse des Actions Prévues dans Entra ID") | Out-Null
    $sb.AppendLine() | Out-Null
    $sb.AppendLine("| Action | Nombre |") | Out-Null
    $sb.AppendLine("|--------|--------|") | Out-Null
    $sb.AppendLine("| 🆕 Créations | $creates |") | Out-Null
    $sb.AppendLine("| ✏️ Modifications | $updates |") | Out-Null
    $sb.AppendLine("| 🗑️ Suppressions | $deletes |") | Out-Null
    $sb.AppendLine() | Out-Null

    # Détails des créations prévues
    $hasCreates = $DiffReport -and ($DiffReport.CatalogsToCreate.Count -gt 0 -or $DiffReport.AccessPackagesToCreate.Count -gt 0 -or ($DiffReport.ResourceRolesToAdd -and $DiffReport.ResourceRolesToAdd.Count -gt 0))
    if ($hasCreates) {
        $sb.AppendLine("#### 🆕 Nouvelles ressources à créer / associer :") | Out-Null
        foreach ($c in $DiffReport.CatalogsToCreate) {
            $sb.AppendLine("- 📦 **Catalogue** : ``$($c.DisplayName)``") | Out-Null
        }
        foreach ($ap in $DiffReport.AccessPackagesToCreate) {
            $sb.AppendLine("- 🎁 **Access Package** : ``$($ap.DisplayName)`` (Catalogue : ``$($ap.CatalogName)``)") | Out-Null
        }
        if ($DiffReport.ResourceRolesToAdd) {
            foreach ($r in $DiffReport.ResourceRolesToAdd) {
                $sb.AppendLine("- 🔗 **Ressource à associer** : ``$($r.ResourceName)`` (Rôle: *$($r.Role)*) ➔ Access Package ``$($r.AccessPackageName)``") | Out-Null
            }
        }
        $sb.AppendLine() | Out-Null
    }

    # Détails des modifications prévues
    $hasUpdates = $DiffReport -and ($DiffReport.CatalogsToUpdate.Count -gt 0 -or $DiffReport.AccessPackagesToUpdate.Count -gt 0 -or ($DiffReport.PoliciesToUpdate -and $DiffReport.PoliciesToUpdate.Count -gt 0))
    if ($hasUpdates) {
        $sb.AppendLine("#### ✏️ Ressources existantes à mettre à jour :") | Out-Null
        foreach ($c in $DiffReport.CatalogsToUpdate) {
            $sb.AppendLine("- 📦 **Catalogue** : ``$($c.DisplayName)``") | Out-Null
        }
        foreach ($ap in $DiffReport.AccessPackagesToUpdate) {
            $sb.AppendLine("- 🎁 **Access Package** : ``$($ap.DisplayName)``") | Out-Null
        }
        if ($DiffReport.PoliciesToUpdate) {
            foreach ($p in $DiffReport.PoliciesToUpdate) {
                $sb.AppendLine("- 📜 **Politique d'assignation à mettre à jour** : ``$($p.DisplayName)`` (Access Package : ``$($p.AccessPackageName)``)") | Out-Null
            }
        }
        $sb.AppendLine() | Out-Null
    }

    # Détails des suppressions prévues
    $hasDeletes = $DiffReport -and ($DiffReport.AccessPackagesToDelete.Count -gt 0 -or ($DiffReport.ResourceRolesToDelete -and $DiffReport.ResourceRolesToDelete.Count -gt 0))
    if ($hasDeletes) {
        $sb.AppendLine("#### 🗑️ Ressources obsolètes à supprimer :") | Out-Null
        foreach ($ap in $DiffReport.AccessPackagesToDelete) {
            $sb.AppendLine("- ⚠️ **Access Package obsolète** : ``$($ap.DisplayName)``") | Out-Null
        }
        if ($DiffReport.ResourceRolesToDelete) {
            foreach ($r in $DiffReport.ResourceRolesToDelete) {
                $sb.AppendLine("- ⚠️ **Ressource à détacher** : ``$($r.ResourceName)`` (Rôle: *$($r.Role)*) ➔ Access Package ``$($r.AccessPackageName)``") | Out-Null
            }
        }
        $sb.AppendLine() | Out-Null
    }

    $sb.AppendLine("---") | Out-Null
    $sb.AppendLine() | Out-Null
    $sb.AppendLine("> [!NOTE]") | Out-Null
    $sb.AppendLine("> ### ℹ️ Étape suivante : Validation Humaine") | Out-Null
    $sb.AppendLine("> Toutes les ressources cibles existent dans Microsoft Entra ID. Un administrateur habilité doit examiner ce plan et apposer son approbation (**Approve**) sur cette Pull Request avant de procéder au merge.") | Out-Null

    return $sb.ToString()
}

<#
.SYNOPSIS
    Génère le commentaire Markdown post-déploiement pour la Pull Request après le merge CD.
.PARAMETER DeployedResources
    Liste des objets de ressources déployées (Type, DisplayName, Id, Status).
#>
function Formater-RapportDeploiementCD {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $DeployedResources
    )

    $sb = [System.Text.StringBuilder]::new()
    $sb.AppendLine("## 🚀 Déploiement Entra ID appliqué avec succès !") | Out-Null
    $sb.AppendLine() | Out-Null
    $sb.AppendLine("Toutes les ressources ont été provisionnées et sont actives dans **Microsoft Entra ID** :") | Out-Null
    $sb.AppendLine() | Out-Null
    $sb.AppendLine("| Type de Ressource | Nom dans Entra ID | Identifiant Entra ID (Object ID) | Statut |") | Out-Null
    $sb.AppendLine("|---|---|---|---|") | Out-Null

    foreach ($res in $DeployedResources) {
        $emoji = switch ($res.Type) {
            "Catalogue"               { "📦" }
            "Access Package"          { "🎁" }
            "Politique d'Assignation" { "📜" }
            default                   { "🔹" }
        }
        $sb.AppendLine("| $emoji **$($res.Type)** | ``$($res.DisplayName)`` | ``$($res.Id)`` | ✅ $($res.Status) |") | Out-Null
    }

    $sb.AppendLine() | Out-Null
    $sb.AppendLine("🔗 Consultez et gérez votre catalogue directement sur le [Portail Microsoft Entra ID](https://entra.microsoft.com/#view/Microsoft_AAD_ERM/DashboardBlade).") | Out-Null

    return $sb.ToString()
}

<#
.SYNOPSIS
    Crée un commentaire initial sur la PR GitHub et retourne son identifiant (ID).
#>
function New-LivePRComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$PrNumber,

        [Parameter(Mandatory = $false)]
        [string]$InitialMessage = "### 🚀 Déploiement Microsoft Entra ID en cours...`n`n*Initialisation de l'orchestration CD PowerShell...*"
    )

    $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_PAT }
    $repo = $env:GITHUB_REPOSITORY
    if (-not $token -or -not $repo -or $PrNumber -le 0) {
        Write-Verbose "Conditions de Live PR Logging non réunies (Token=$([bool]$token), Repo=$repo, PR=$PrNumber)."
        return 0
    }

    try {
        $uri = "https://api.github.com/repos/$repo/issues/$PrNumber/comments"
        $headers = @{
            "Authorization" = "Bearer $token"
            "Accept"        = "application/vnd.github.v3+json"
            "User-Agent"    = "Ardian-GitOps-Engine"
        }
        $body = @{ body = $InitialMessage } | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8"
        if ($resp -and $resp.id) {
            Write-Host "📡 Commentaire Live PR initialisé sur la PR #$PrNumber (ID: $($resp.id))." -ForegroundColor Cyan
            return [long]$resp.id
        }
    } catch {
        Write-Warning "⚠️ Impossible de créer le commentaire initial sur la PR #$PrNumber : $_"
    }

    return 0
}

<#
.SYNOPSIS
    Met à jour un commentaire existant sur la PR GitHub en direct.
#>
function Update-LivePRComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [long]$CommentId,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_PAT }
    $repo = $env:GITHUB_REPOSITORY
    if (-not $token -or -not $repo -or $CommentId -le 0) {
        return
    }

    try {
        $uri = "https://api.github.com/repos/$repo/issues/comments/$CommentId"
        $headers = @{
            "Authorization" = "Bearer $token"
            "Accept"        = "application/vnd.github.v3+json"
            "User-Agent"    = "Ardian-GitOps-Engine"
        }
        $body = @{ body = $Message } | ConvertTo-Json
        Invoke-RestMethod -Uri $uri -Method Patch -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8" | Out-Null
    } catch {
        Write-Warning "⚠️ Erreur lors de la mise à jour du commentaire live PR $CommentId : $_"
    }
}

<#
.SYNOPSIS
    Génère le compte-rendu Markdown pour la validation en lecture seule du scénario d'import (admin_import).
.PARAMETER YamlFiles
    Liste des fichiers déclaratifs YAML importés.
#>
function Formater-RapportImportCD {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $YamlFiles = @()
    )

    $sb = [System.Text.StringBuilder]::new()
    $sb.AppendLine("## 📥 Importation Entra ID enregistrée dans Git (Mode Lecture Seule)") | Out-Null
    $sb.AppendLine() | Out-Null
    $sb.AppendLine("> [!NOTE]") | Out-Null
    $sb.AppendLine("> ### 🔒 Sécurité & Intégrité Microsoft Entra ID") | Out-Null
    $sb.AppendLine("> Le scénario d'importation (Reverse Engineering) est **strictement en lecture seule**.") | Out-Null
    $sb.AppendLine("> Les déclarations YAML enregistrées reflètent fidèlement l'état réel existant dans Entra ID.") | Out-Null
    $sb.AppendLine("> **Aucune modification, création ou suppression n'a été appliquée à Microsoft Entra ID.**") | Out-Null
    $sb.AppendLine() | Out-Null
    $sb.AppendLine("### 📦 Applications et Catalogues synchronisés dans Git :") | Out-Null
    $sb.AppendLine() | Out-Null
    $sb.AppendLine("| Application Git | Fichier Déclaratif | Statut dans Entra ID |") | Out-Null
    $sb.AppendLine("|---|---|---|") | Out-Null

    if ($YamlFiles -and $YamlFiles.Count -gt 0) {
        foreach ($yf in $YamlFiles) {
            $fName = if ($yf.Name) { $yf.Name } elseif ($yf -is [string]) { [System.IO.Path]::GetFileName($yf) } else { [string]$yf }
            $appBase = [System.IO.Path]::GetFileNameWithoutExtension($fName)
            $sb.AppendLine("| ``$appBase`` | ``$fName`` | 🟢 Intact (Lecture seule) |") | Out-Null
        }
    } else {
        $sb.AppendLine("| - | - | 🟢 Intact (Lecture seule) |") | Out-Null
    }

    $sb.AppendLine() | Out-Null
    $sb.AppendLine("🛡️ La gouvernance CODEOWNERS a été actualisée pour attribuer la gestion de ces applications aux équipes habilitées.") | Out-Null

    return $sb.ToString()
}

Export-ModuleMember -Function Formater-RapportPlanCI, Formater-RapportDeploiementCD, Formater-RapportImportCD, New-LivePRComment, Update-LivePRComment

