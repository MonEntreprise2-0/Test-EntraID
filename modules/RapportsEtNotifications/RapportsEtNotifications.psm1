# ============================================================================
# MODULE : RapportsEtNotifications
# ============================================================================
# Rôle :
#   Construit et formate les synthèses et rapports en Markdown pour les
#   commentaires de Pull Request GitHub et les GITHUB_STEP_SUMMARY.
#   Génère les blocs d'alerte GitHub (CAUTION, NOTE) pour les blocages SSoT
#   et les approbations requises.
#
# Auteur : Ardian Cloud IAM & DevOps
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
                $sb.AppendLine("> - 📱 Application / Rôle applicatif manquant : ``$app``") | Out-Null
            }
        }
        if ($SSoTReport.MissingGroups) {
            foreach ($grp in $SSoTReport.MissingGroups) {
                $sb.AppendLine("> - 👥 Groupe Entra ID manquant : ``$grp``") | Out-Null
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
    if ($DiffReport -and ($DiffReport.CatalogsToCreate.Count -gt 0 -or $DiffReport.AccessPackagesToCreate.Count -gt 0)) {
        $sb.AppendLine("#### 🆕 Nouvelles ressources à créer :") | Out-Null
        foreach ($c in $DiffReport.CatalogsToCreate) {
            $sb.AppendLine("- 📦 **Catalogue** : ``$($c.DisplayName)``") | Out-Null
        }
        foreach ($ap in $DiffReport.AccessPackagesToCreate) {
            $sb.AppendLine("- 🎁 **Access Package** : ``$($ap.DisplayName)`` (Catalogue : ``$($ap.CatalogName)``)") | Out-Null
        }
        $sb.AppendLine() | Out-Null
    }

    # Détails des modifications prévues
    if ($DiffReport -and ($DiffReport.CatalogsToUpdate.Count -gt 0 -or $DiffReport.AccessPackagesToUpdate.Count -gt 0)) {
        $sb.AppendLine("#### ✏️ Ressources existantes à mettre à jour :") | Out-Null
        foreach ($c in $DiffReport.CatalogsToUpdate) {
            $sb.AppendLine("- 📦 **Catalogue** : ``$($c.DisplayName)``") | Out-Null
        }
        foreach ($ap in $DiffReport.AccessPackagesToUpdate) {
            $sb.AppendLine("- 🎁 **Access Package** : ``$($ap.DisplayName)``") | Out-Null
        }
        $sb.AppendLine() | Out-Null
    }

    # Détails des suppressions prévues
    if ($DiffReport -and $DiffReport.AccessPackagesToDelete.Count -gt 0) {
        $sb.AppendLine("#### 🗑️ Ressources obsolètes à supprimer :") | Out-Null
        foreach ($ap in $DiffReport.AccessPackagesToDelete) {
            $sb.AppendLine("- ⚠️ **Access Package obsolète** : ``$($ap.DisplayName)``") | Out-Null
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
    $sb.AppendLine("> 👑 **Propriétaires du catalogue** : les ``authorization_owners`` déclarés ont été rattachés au rôle *Catalog owner* dans Entra ID.") | Out-Null
    $sb.AppendLine() | Out-Null
    $sb.AppendLine("🔗 Consultez et gérez votre catalogue directement sur le [Portail Microsoft Entra ID](https://entra.microsoft.com/#view/Microsoft_AAD_ERM/DashboardBlade).") | Out-Null

    return $sb.ToString()
}

Export-ModuleMember -Function Formater-RapportPlanCI, Formater-RapportDeploiementCD
