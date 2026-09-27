# ============================================================================
# MODULE : SynchronisationEntra
# ============================================================================
# Rôle :
#   Moteur de calcul différentiel (Diff) et de déploiement idempotent.
#   Compare l'état souhaité (déclarations Git YAML) à l'état réel (Entra ID)
#   et applique les changements de façon ordonnée et sécurisée.
#
# Auteur : Ardian Cloud IAM & DevOps
# ============================================================================

<#
.SYNOPSIS
    Calcule le différentiel complet entre les déclarations YAML et Microsoft Entra ID.
.DESCRIPTION
    Interroge l'état actuel dans Entra ID pour tous les catalogues et packages déclarés.
    Identifie précisément les créations, modifications, suppressions et éléments inchangés.
.PARAMETER Declarations
    Liste des objets déclaratifs chargés depuis les fichiers YAML.
.PARAMETER SSoTPrerequisites
    Résultat optionnel de la validation SSoT (fourni par Valider-RessourcesEntraId).
#>
function Comparer-EtatEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Declarations,

        [Parameter(Mandatory = $false)]
        $SSoTPrerequisites = $null,

        [Parameter(Mandatory = $false)]
        $CataloguesExistants = $null
    )

    Write-Verbose "Début du calcul différentiel (Diff) Git vs Entra ID..."

    # Récupération de tous les catalogues existants dans Entra ID
    $existingCatalogs = if ($null -ne $CataloguesExistants) { $CataloguesExistants } else { Get-CatalogueEntra }
    $catalogMapByName = @{}
    $catalogMapNormalized = @{}
    if ($existingCatalogs) {
        foreach ($c in $existingCatalogs) {
            if ($c.displayName) {
                $rawKey = $c.displayName.Trim().ToLowerInvariant()
                $catalogMapByName[$rawKey] = $c
                $normKey = ($c.displayName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
                if (-not $catalogMapNormalized.ContainsKey($normKey)) {
                    $catalogMapNormalized[$normKey] = $c
                }
            }
        }
    }

    $catalogsToCreate = [System.Collections.Generic.List[object]]::new()
    $catalogsToUpdate = [System.Collections.Generic.List[object]]::new()
    $catalogsUnchanged = [System.Collections.Generic.List[object]]::new()

    $catalogResourcesToAdd = [System.Collections.Generic.List[object]]::new()

    $accessPackagesToCreate = [System.Collections.Generic.List[object]]::new()
    $accessPackagesToUpdate = [System.Collections.Generic.List[object]]::new()
    $accessPackagesUnchanged = [System.Collections.Generic.List[object]]::new()
    $accessPackagesToDelete = [System.Collections.Generic.List[object]]::new()
    $resourceRolesToAdd = [System.Collections.Generic.List[object]]::new()
    $resourceRolesToDelete = [System.Collections.Generic.List[object]]::new()
    $policiesToCreate = [System.Collections.Generic.List[object]]::new()
    $policiesToUpdate = [System.Collections.Generic.List[object]]::new()

    foreach ($doc in $Declarations) {
        $appName = $doc.app_name
        $catName = $(if ($doc.catalog_name) { $doc.catalog_name.Trim() } elseif ($appName -like "CAT-*") { $appName } else { "CAT-$appName" })
        $appDesc = $(if ($doc.app_description) { $doc.app_description.Trim() } else { "Catalogue $catName" })

        $catKey = $catName.ToLowerInvariant()
        $normKey = ($catName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
        $existingCat = $(
            if ($catalogMapByName.ContainsKey($catKey)) { 
                $catalogMapByName[$catKey] 
            } elseif ($catalogMapNormalized.ContainsKey($normKey)) {
                $catalogMapNormalized[$normKey]
            } else { 
                $null 
            }
        )

        # 1. Analyse du catalogue
        if (-not $existingCat) {
            $catalogsToCreate.Add(@{
                AppName     = $appName
                DisplayName = $catName
                Description = $appDesc
            })
        } else {
            if ($existingCat.description -ne $appDesc) {
                $catalogsToUpdate.Add(@{
                    Id          = $existingCat.id
                    AppName     = $appName
                    DisplayName = $catName
                    Description = $appDesc
                })
            } else {
                $catalogsUnchanged.Add(@{
                    Id          = $existingCat.id
                    AppName     = $appName
                    DisplayName = $catName
                })
            }
        }

        # 2. Analyse des Access Packages et ressources si le catalogue existe
        $existingApsMap = @{}
        $existingCatResourcesMap = @{}

        if ($existingCat) {
            $catId = $existingCat.id

            # Récupération des packages existants du catalogue (ou réutilisation si déjà alimentés)
            $existingAps = if ($existingCat.PSObject.Properties['accessPackages'] -and $null -ne $existingCat.accessPackages) {
                $existingCat.accessPackages
            } else {
                Get-AccessPackageEntra -CatalogId $catId
            }
            if ($existingAps) {
                foreach ($ap in $existingAps) {
                    if ($ap.displayName) {
                        $existingApsMap[$ap.displayName.Trim().ToLowerInvariant()] = $ap
                    }
                }
            }

            # Récupération des ressources existantes dans le catalogue (ou réutilisation si déjà alimentées)
            $catResources = if ($existingCat.PSObject.Properties['resources'] -and $null -ne $existingCat.resources) {
                $existingCat.resources
            } else {
                try {
                    Get-RessourcesCatalogue -CatalogId $catId
                } catch {
                    Write-Verbose "Impossible de récupérer les ressources du catalogue '$catId' : $_"
                    @()
                }
            }
            if ($catResources) {
                foreach ($res in $catResources) {
                    if ($res.originId) {
                        $existingCatResourcesMap[$res.originId.Trim().ToLowerInvariant()] = $res
                    }
                }
            }
        }

        # Détection des paquets déclarés
        $declaredApNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        if ($doc.access_packages) {
            foreach ($ap in $doc.access_packages) {
                $apName = Calculer-NomAccessPackage -AccessPackage $ap -AppName $appName
                $declaredApNames.Add($apName) | Out-Null
                $apKey = $apName.ToLowerInvariant()
                $apDesc = $(if ($ap.description) { $ap.description.Trim() } else { "Access Package $apName" })

                $existingAp = $(if ($existingApsMap.ContainsKey($apKey)) { $existingApsMap[$apKey] } else { $null })

                if (-not $existingAp) {
                    $accessPackagesToCreate.Add(@{
                        AppName     = $appName
                        CatalogName = $catName
                        DisplayName = $apName
                        Description = $apDesc
                    })
                    $policiesToCreate.Add(@{
                        AccessPackageName = $apName
                        DisplayName       = "Politique - $apName"
                        Approvers         = $ap.authorization_owners
                    })
                } else {
                    if ($existingAp.description -ne $apDesc) {
                        $accessPackagesToUpdate.Add(@{
                            Id          = $existingAp.id
                            DisplayName = $apName
                            Description = $apDesc
                        })
                    } else {
                        $accessPackagesUnchanged.Add(@{
                            Id          = $existingAp.id
                            DisplayName = $apName
                        })
                    }

                    # Comparaison des rôles de ressources (Resource Roles)
                    $currentRoleScopes = if ($existingAp.PSObject.Properties['resourceRoles'] -and $null -ne $existingAp.resourceRoles) {
                        $existingAp.resourceRoles
                    } else {
                        try {
                            Get-RolesRessourcesAccessPackage -AccessPackageId $existingAp.id -ErrorAction SilentlyContinue
                        } catch {
                            @()
                        }
                    }

                    $declaredResourceNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    if ($ap.resources) {
                        foreach ($res in $ap.resources) {
                            $rType = $res.resource_type
                            $resName = ""
                            $expectedRole = "Member"
                            if ($rType -eq "EntraID Group" -or $rType -eq "Group") {
                                $resName = $res.group_name
                                $expectedRole = if ($res.role) { $res.role.Trim() } else { "Member" }
                            } elseif ($rType -eq "Application Role" -or $rType -eq "Application") {
                                $resName = $res.enterprise_app
                                $expectedRole = if ($res.app_role) { 
                                    $res.app_role.Trim() 
                                } elseif (-not [string]::IsNullOrWhiteSpace($ap.context_subapp)) {
                                    "$($ap.context_subapp.Trim()) $($ap.privilege_level.Trim())"
                                } else {
                                    "$($ap.privilege_level.Trim())"
                                }
                            } elseif ($rType -in @("Sharepoint Group", "SharePoint Group", "SharePoint Online", "SharePoint Site")) {
                                $resName = if ($res.sharepoint_group_name) { $res.sharepoint_group_name } else { $res.sharepoint_url }
                                $expectedRole = if ($res.role) { $res.role.Trim() } else { "Member" }
                            }

                            if (-not [string]::IsNullOrWhiteSpace($resName)) {
                                $declaredResourceNames.Add($resName.Trim()) | Out-Null
                            }

                            # Vérifier si ce rôle de ressource est déjà lié à l'Access Package
                            $isAlreadyLinked = $false
                            if ($currentRoleScopes) {
                                foreach ($crs in $currentRoleScopes) {
                                    $scopeName = if ($crs.accessPackageResourceScope -and $crs.accessPackageResourceScope.displayName) {
                                        $crs.accessPackageResourceScope.displayName.Trim()
                                    } else { "" }
                                    $crsRole = if ($crs.accessPackageResourceRole -and $crs.accessPackageResourceRole.displayName) {
                                        $crs.accessPackageResourceRole.displayName.Trim()
                                    } else { "" }

                                    if ($scopeName.Equals($resName.Trim(), [System.StringComparison]::OrdinalIgnoreCase) -and 
                                        $crsRole.Equals($expectedRole, [System.StringComparison]::OrdinalIgnoreCase)) {
                                        $isAlreadyLinked = $true
                                        break
                                    }
                                }
                            }

                            if (-not $isAlreadyLinked) {
                                $resourceRolesToAdd.Add(@{
                                    CatalogName       = $catName
                                    AccessPackageName = $apName
                                    ResourceName      = $resName
                                    ResourceType      = $rType
                                    Role              = $expectedRole
                                })
                            }
                        }
                    }

                    # Détection des rôles de ressources obsolètes à retirer de l'Access Package
                    if ($currentRoleScopes) {
                        foreach ($crs in $currentRoleScopes) {
                            $scopeName = if ($crs.accessPackageResourceScope -and $crs.accessPackageResourceScope.displayName) {
                                $crs.accessPackageResourceScope.displayName.Trim()
                            } else { "" }
                            $crsRole = if ($crs.accessPackageResourceRole -and $crs.accessPackageResourceRole.displayName) {
                                $crs.accessPackageResourceRole.displayName.Trim()
                            } else { "" }
                            $crsId = $crs.id

                            if (-not [string]::IsNullOrWhiteSpace($scopeName) -and -not $declaredResourceNames.Contains($scopeName)) {
                                $resourceRolesToDelete.Add(@{
                                    CatalogName       = $catName
                                    AccessPackageName = $apName
                                    ResourceName      = $scopeName
                                    Role              = $crsRole
                                    RoleScopeId       = $crsId
                                })
                            }
                        }
                    }

                    # Contrôle de la politique d'assignation
                    $existingPolicy = if ($existingAp.PSObject.Properties['policy'] -and $null -ne $existingAp.policy) {
                        $existingAp.policy
                    } else {
                        try {
                            Get-PolitiqueAssignationEntra -AccessPackageId $existingAp.id -ErrorAction SilentlyContinue
                        } catch {
                            $null
                        }
                    }
                    if ($existingPolicy -and -not [string]::IsNullOrWhiteSpace($existingPolicy.id)) {
                        $targetPolicyName = "Politique - $apName"
                        $targetApproverIds = [System.Collections.Generic.List[string]]::new()
                        if ($ap.authorization_owners) {
                            foreach ($owner in $ap.authorization_owners) {
                                $u = if ($SSoTPrerequisites -and $SSoTPrerequisites.ResolvedUsers -and $SSoTPrerequisites.ResolvedUsers[$owner]) {
                                    $SSoTPrerequisites.ResolvedUsers[$owner]
                                } else {
                                    try { Resolve-GraphUser -UserEmailOrUpn $owner -ErrorAction SilentlyContinue } catch { $null }
                                }
                                if ($u) { $targetApproverIds.Add($u.id) }
                            }
                        }
                        if (-not (Test-PolitiqueIdentique -ExistingPolicy $existingPolicy -TargetDisplayName $targetPolicyName -TargetApproverIds $targetApproverIds.ToArray())) {
                            $policiesToUpdate.Add(@{
                                AccessPackageName = $apName
                                DisplayName       = $targetPolicyName
                                ExistingPolicy    = $existingPolicy
                            })
                        }
                    }
                }

                # Ressources déclarées
                if ($ap.resources) {
                    foreach ($res in $ap.resources) {
                        $catalogResourcesToAdd.Add(@{
                            CatalogName       = $catName
                            AccessPackageName = $apName
                            Resource          = $res
                        })
                    }
                }
            }
        }

        # Détection des packages obsolètes existants dans Entra ID mais retirés du YAML
        if ($existingCat) {
            foreach ($existingApName in $existingApsMap.Keys) {
                $apObj = $existingApsMap[$existingApName]
                if (-not $declaredApNames.Contains($apObj.displayName)) {
                    $accessPackagesToDelete.Add(@{
                        Id          = $apObj.id
                        DisplayName = $apObj.displayName
                        CatalogName = $catName
                    })
                }
            }
        }
    }

    $createsCount = $catalogsToCreate.Count + $accessPackagesToCreate.Count + $policiesToCreate.Count + $resourceRolesToAdd.Count
    $updatesCount = $catalogsToUpdate.Count + $accessPackagesToUpdate.Count + $policiesToUpdate.Count
    $deletesCount = $accessPackagesToDelete.Count + $resourceRolesToDelete.Count
    $noChangeCount = $catalogsUnchanged.Count + $accessPackagesUnchanged.Count

    return [PSCustomObject]@{
        CatalogsToCreate        = $catalogsToCreate.ToArray()
        CatalogsToUpdate        = $catalogsToUpdate.ToArray()
        CatalogsUnchanged       = $catalogsUnchanged.ToArray()
        CatalogResourcesToAdd   = $catalogResourcesToAdd.ToArray()
        AccessPackagesToCreate  = $accessPackagesToCreate.ToArray()
        AccessPackagesToUpdate  = $accessPackagesToUpdate.ToArray()
        AccessPackagesUnchanged = $accessPackagesUnchanged.ToArray()
        AccessPackagesToDelete  = $accessPackagesToDelete.ToArray()
        ResourceRolesToAdd      = $resourceRolesToAdd.ToArray()
        ResourceRolesToDelete   = $resourceRolesToDelete.ToArray()
        PoliciesToCreate        = $policiesToCreate.ToArray()
        PoliciesToUpdate        = $policiesToUpdate.ToArray()
        CreatesCount            = $createsCount
        UpdatesCount            = $updatesCount
        DeletesCount            = $deletesCount
        NoChangeCount           = $noChangeCount
        HasChanges              = (($createsCount + $updatesCount + $deletesCount) -gt 0)
    }
}

<#
.SYNOPSIS
    Applique de façon ordonnée et idempotente l'état déclaré vers Entra ID.
.DESCRIPTION
    Séquence d'exécution :
    1. Création / Mise à jour des catalogues
    2. Assignation des Catalog Owners
    3. Onboarding des ressources (groupes, apps) dans les catalogues
    4. Création / Mise à jour des Access Packages
    5. Association des rôles de ressources (Member, Owner, App Role) aux Access Packages
    6. Création / Mise à jour des politiques d'assignation
    7. Suppression sécurisée des ressources obsolètes
#>
function Synchroniser-EtatEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Declarations,

        [Parameter(Mandatory = $false)]
        $DiffReport = $null,

        [Parameter(Mandatory = $false)]
        [long]$LiveCommentId = 0
    )

    function Update-LiveProgress {
        param([string]$StatusText)
        if ($LiveCommentId -gt 0 -and (Get-Command -Name "Update-LivePRComment" -ErrorAction SilentlyContinue)) {
            Update-LivePRComment -CommentId $LiveCommentId -Message $StatusText
        }
    }

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "🚀 DÉPLOIEMENT DÉCLARATIF ENTRA ID (100% POWERSHELL)" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan

    $deployedResources = [System.Collections.Generic.List[PSObject]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    Update-LiveProgress "### 🚀 Déploiement Microsoft Entra ID en cours...`n`n| Étape | Statut |`n|---|---|`n| 📦 Catalogues | ⏳ En cours... |`n| 📁 Ressources (Groupes, Apps, SharePoint) | ⏸️ En attente |`n| 🎁 Access Packages | ⏸️ En attente |`n| 📜 Politiques d'Assignation | ⏸️ En attente |"

    foreach ($doc in $Declarations) {
        $appName = $doc.app_name
        $catName = $(if ($doc.catalog_name) { $doc.catalog_name.Trim() } elseif ($appName -like "CAT-*") { $appName } else { "CAT-$appName" })
        $appDesc = $(if ($doc.app_description) { $doc.app_description.Trim() } else { "Catalogue $catName" })

        Write-Host "`n📦 Application : $appName (Catalogue : '$catName')" -ForegroundColor Yellow

        # -------------------------------------------------------------------
        # ÉTAPE 1 : Assurer l'existence du Catalogue
        # -------------------------------------------------------------------
        $catalog = Get-CatalogueEntra -DisplayName $catName
        if (-not $catalog) {
            Write-Host "  ➕ Création du catalogue '$catName'..." -ForegroundColor Green
            $catalog = New-CatalogueEntra -DisplayName $catName -Description $appDesc
        } else {
            Write-Host "  ✅ Catalogue existant trouvé : '$catName' ($($catalog.id))" -ForegroundColor Gray
            if ($catalog.description -ne $appDesc) {
                Write-Host "  ✏️ Mise à jour de la description du catalogue..." -ForegroundColor Cyan
                Set-CatalogueEntra -CatalogId $catalog.id -Description $appDesc | Out-Null
            }
        }

        $catalogId = $catalog.id
        $deployedResources.Add([PSCustomObject]@{
            Type        = "Catalogue"
            DisplayName = $catName
            Id          = $catalogId
            Status      = "Actif"
        })

        # -------------------------------------------------------------------
        # ÉTAPE 2 : Onboarding des Ressources dans le Catalogue
        # -------------------------------------------------------------------
        Update-LiveProgress "### 🚀 Déploiement Microsoft Entra ID en cours...`n`n| Étape | Statut |`n|---|---|`n| 📦 Catalogues | ✅ Prêts |`n| 📁 Ressources (Groupes, Apps, SharePoint) | ⏳ En cours... |`n| 🎁 Access Packages | ⏸️ En attente |`n| 📜 Politiques d'Assignation | ⏸️ En attente |"

        $onboardedResourcesMap = @{}
        $existingCatResources = Get-RessourcesCatalogue -CatalogId $catalogId

        if ($doc.access_packages) {
            foreach ($ap in $doc.access_packages) {
                if (-not $ap.resources) { continue }
                foreach ($res in $ap.resources) {
                    $rType = $res.resource_type
                    if ($rType -eq "EntraID Group" -or $rType -eq "Group") {
                        $grpKey = $res.group_name.ToLowerInvariant()
                        if ($onboardedResourcesMap.ContainsKey($grpKey)) {
                            continue
                        }
                        $grpObj = Resolve-GraphGroup -GroupName $res.group_name
                        if ($grpObj) {
                            try {
                                Add-RessourceCatalogue -CatalogId $catalogId -OriginId $grpObj.id -OriginSystem "AadGroup" -ExistingResources $existingCatResources | Out-Null
                                $onboardedResourcesMap[$grpKey] = $grpObj.id
                                Write-Host "  📁 Groupe '$($res.group_name)' associé au catalogue." -ForegroundColor Gray
                            } catch {
                                Write-Warning "  ⚠️ Erreur onboarding groupe '$($res.group_name)' : $_"
                            }
                        }
                    } elseif ($rType -eq "Application Role" -or $rType -eq "Application") {
                        $appKey = $res.enterprise_app.ToLowerInvariant()
                        if ($onboardedResourcesMap.ContainsKey($appKey)) {
                            continue
                        }
                        $spObj = Resolve-GraphServicePrincipal -DisplayName $res.enterprise_app
                        if ($spObj) {
                            try {
                                Add-RessourceCatalogue -CatalogId $catalogId -OriginId $spObj.id -OriginSystem "AadApplication" -ExistingResources $existingCatResources | Out-Null
                                $onboardedResourcesMap[$appKey] = $spObj.id
                                Write-Host "  📱 Application '$($res.enterprise_app)' associée au catalogue." -ForegroundColor Gray
                            } catch {
                                Write-Warning "  ⚠️ Erreur onboarding application '$($res.enterprise_app)' : $_"
                            }
                        }
                    } elseif ($rType -in @("Sharepoint Group", "SharePoint Group", "SharePoint Online", "SharePoint Site")) {
                        $siteKey = $res.sharepoint_url.ToLowerInvariant()
                        if ($onboardedResourcesMap.ContainsKey($siteKey)) {
                            continue
                        }
                        $siteObj = Resolve-SharepointSite -SiteUrl $res.sharepoint_url
                        if ($siteObj) {
                            try {
                                Add-RessourceCatalogue -CatalogId $catalogId -OriginId $siteObj.webUrl -OriginSystem "SharePointOnline" -ExistingResources $existingCatResources | Out-Null
                                $onboardedResourcesMap[$siteKey] = $siteObj.id
                                Write-Host "  🌐 Site SharePoint '$($res.sharepoint_url)' associé au catalogue." -ForegroundColor Gray
                            } catch {
                                Write-Warning "  ⚠️ Erreur onboarding site SharePoint '$($res.sharepoint_url)' : $_"
                            }
                        }
                    }
                }
            }
        }

        # -------------------------------------------------------------------
        # ÉTAPE 3 : Création / Mise à jour des Access Packages
        # -------------------------------------------------------------------
        Update-LiveProgress "### 🚀 Déploiement Microsoft Entra ID en cours...`n`n| Étape | Statut |`n|---|---|`n| 📦 Catalogues | ✅ Prêts |`n| 📁 Ressources (Groupes, Apps, SharePoint) | ✅ Associées |`n| 🎁 Access Packages | ⏳ En cours... |`n| 📜 Politiques d'Assignation | ⏸️ En attente |"

        $existingAps = Get-AccessPackageEntra -CatalogId $catalogId
        $existingApMap = @{}
        if ($existingAps) {
            foreach ($ap in $existingAps) {
                if ($ap.displayName) {
                    $existingApMap[$ap.displayName.Trim().ToLowerInvariant()] = $ap
                }
            }
        }

        $activeApNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        if ($doc.access_packages) {
            foreach ($ap in $doc.access_packages) {
                $apName = Calculer-NomAccessPackage -AccessPackage $ap -AppName $appName
                $activeApNames.Add($apName) | Out-Null
                $apKey = $apName.ToLowerInvariant()
                $apDesc = $(if ($ap.description) { $ap.description.Trim() } else { "Access Package $apName" })

                $apObj = $(if ($existingApMap.ContainsKey($apKey)) { $existingApMap[$apKey] } else { $null })

                if (-not $apObj) {
                    Write-Host "  🎁 Création de l'Access Package '$apName'..." -ForegroundColor Green
                    $apObj = New-AccessPackageEntra -CatalogId $catalogId -DisplayName $apName -Description $apDesc
                } else {
                    Write-Host "  ✅ Access Package existant trouvé : '$apName' ($($apObj.id))" -ForegroundColor Gray
                    if ($apObj.description -ne $apDesc) {
                        Write-Host "  ✏️ Mise à jour de la description de '$apName'..." -ForegroundColor Cyan
                        Set-AccessPackageEntra -AccessPackageId $apObj.id -Description $apDesc | Out-Null
                    }
                }

                if (-not $apObj -or [string]::IsNullOrWhiteSpace($apObj.id)) {
                    Write-Warning "  ⚠️ Impossible de récupérer ou créer l'Access Package '$apName'."
                    $errors.Add("Échec création Access Package '$apName'")
                    continue
                }

                $apId = $apObj.id
                $deployedResources.Add([PSCustomObject]@{
                    Type        = "Access Package"
                    DisplayName = $apName
                    Id          = $apId
                    Status      = "Actif"
                })

                # ---------------------------------------------------------------
                # ÉTAPE 4 : Liaison & Nettoyage des Rôles de Ressources (Resource Roles)
                # ---------------------------------------------------------------
                $currentRoleScopes = Get-RolesRessourcesAccessPackage -AccessPackageId $apId
                $declaredRoleKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

                if ($ap.resources) {
                    foreach ($res in $ap.resources) {
                        $rType = $res.resource_type
                        $targetOriginId = $null
                        $roleToAssign = "Member"

                        if ($rType -eq "EntraID Group" -or $rType -eq "Group") {
                            $targetOriginId = $(if ($onboardedResourcesMap.ContainsKey($res.group_name.ToLowerInvariant())) {
                                $onboardedResourcesMap[$res.group_name.ToLowerInvariant()]
                            } else {
                                $g = Resolve-GraphGroup -GroupName $res.group_name
                                if ($g) { $g.id } else { $null }
                            })
                            # Groupes par défaut : Member sauf si explicitement Owner
                            if ($res.role -and $res.role.Equals("Owner", [StringComparison]::OrdinalIgnoreCase)) {
                                $roleToAssign = "Owner"
                            } else {
                                $roleToAssign = "Member"
                            }
                        } elseif ($rType -eq "Application Role" -or $rType -eq "Application") {
                            $targetOriginId = $(if ($onboardedResourcesMap.ContainsKey($res.enterprise_app.ToLowerInvariant())) {
                                $onboardedResourcesMap[$res.enterprise_app.ToLowerInvariant()]
                            } else {
                                $sp = Resolve-GraphServicePrincipal -DisplayName $res.enterprise_app
                                if ($sp) { $sp.id } else { $null }
                            })
                            # AppRole calculé automatiquement : {context/subapp} {privilege Level}
                            $computedAppRole = if (-not [string]::IsNullOrWhiteSpace($ap.context_subapp)) {
                                "$($ap.context_subapp.Trim()) $($ap.privilege_level.Trim())"
                            } else {
                                "$($ap.privilege_level.Trim())"
                            }
                            $roleToAssign = if ($res.app_role) { $res.app_role.Trim() } else { $computedAppRole }
                        } elseif ($rType -in @("Sharepoint Group", "SharePoint Group", "SharePoint Online", "SharePoint Site")) {
                            $siteKey = $res.sharepoint_url.ToLowerInvariant()
                            $targetOriginId = $(if ($onboardedResourcesMap.ContainsKey($siteKey)) {
                                $onboardedResourcesMap[$siteKey]
                            } else {
                                $siteObj = Resolve-SharepointSite -SiteUrl $res.sharepoint_url
                                if ($siteObj) { $siteObj.id } else { $null }
                            })
                            $roleToAssign = if ($res.role) { $res.role.Trim() } elseif ($res.sharepoint_group_name) { $res.sharepoint_group_name.Trim() } else { "Member" }
                        }

                        if ($targetOriginId) {
                            $declaredRoleKeys.Add("$($targetOriginId.ToLowerInvariant())|$($roleToAssign.ToLowerInvariant())") | Out-Null
                            try {
                                Add-RoleRessourceAccessPackage -CatalogId $catalogId -AccessPackageId $apId -ResourceOriginId $targetOriginId -RoleName $roleToAssign -ExistingRoles $currentRoleScopes | Out-Null
                                Write-Host "  🔗 Rôle '$roleToAssign' lié à l'Access Package '$apName'." -ForegroundColor Gray
                            } catch {
                                Write-Warning "  ⚠️ Erreur liaison de rôle sur '$apName' : $_"
                            }
                        }
                    }
                }

                # Détacher les rôles devenus obsolètes (retirés du fichier YAML)
                if ($currentRoleScopes) {
                    foreach ($rs in $currentRoleScopes) {
                        $scopeOriginId = if ($rs.accessPackageResourceScope -and $rs.accessPackageResourceScope.originId) {
                            $rs.accessPackageResourceScope.originId.Trim().ToLowerInvariant()
                        } else { "" }

                        $scopeRoleName = if ($rs.accessPackageResourceRole -and $rs.accessPackageResourceRole.displayName) {
                            $rs.accessPackageResourceRole.displayName.Trim()
                        } else { "" }

                        $rsKey = "$scopeOriginId|$($scopeRoleName.ToLowerInvariant())"

                        if ($scopeOriginId -and -not $declaredRoleKeys.Contains($rsKey)) {
                            $scopeDisplay = if ($rs.accessPackageResourceScope -and $rs.accessPackageResourceScope.displayName) {
                                $rs.accessPackageResourceScope.displayName
                            } else { $scopeOriginId }

                            Write-Host "  🗑️ Suppression de la ressource retirée de l'Access Package '$apName' : '$scopeDisplay' (Rôle: '$scopeRoleName')..." -ForegroundColor Yellow
                            try {
                                Remove-RoleRessourceAccessPackage -AccessPackageId $apId -RoleScopeId $rs.id | Out-Null
                                $deployedResources.Add([PSCustomObject]@{
                                    Type        = "Ressource Retirée"
                                    DisplayName = "$scopeDisplay ($scopeRoleName) de $apName"
                                    Id          = $rs.id
                                    Status      = "Supprimé"
                                })
                            } catch {
                                Write-Warning "  ⚠️ Erreur lors de la suppression de la ressource '$scopeDisplay' : $_"
                            }
                        }
                    }
                }

                # ---------------------------------------------------------------
                # ÉTAPE 5 : Politique d'Assignation Unique par Access Package
                # ---------------------------------------------------------------
                try {
                    $approverIds = [System.Collections.Generic.List[string]]::new()
                    if ($ap.authorization_owners) {
                        foreach ($email in $ap.authorization_owners) {
                            $u = Resolve-GraphUser -UserEmailOrUpn $email
                            if ($u) {
                                $approverIds.Add($u.id)
                            }
                        }
                    }

                    $policyName = "Politique - $apName"
                    $existingPolicy = Get-PolitiqueAssignationEntra -AccessPackageId $apId

                    if ($existingPolicy -and -not [string]::IsNullOrWhiteSpace($existingPolicy.id)) {
                        # Contrôle d'idempotence pure (No-Op) : Si déjà identique, aucun PUT lent vers Graph
                        if (Test-PolitiqueIdentique -ExistingPolicy $existingPolicy -TargetDisplayName $policyName -TargetApproverIds $approverIds.ToArray()) {
                            Write-Host "  ✅ Politique d'assignation déjà conforme : '$policyName' ($($existingPolicy.id))" -ForegroundColor Gray
                            $policy = $existingPolicy
                        } else {
                            Write-Host "  ✏️ Mise à jour de la politique d'assignation existante ('$($existingPolicy.displayName)' -> '$policyName')..." -ForegroundColor Cyan
                            $policy = Set-PolitiqueAssignationEntra -PolicyId $existingPolicy.id -AccessPackageId $apId -DisplayName $policyName -ApproverUserIds $approverIds.ToArray() -ExistingPolicy $existingPolicy
                        }
                    } else {
                        Write-Host "  📜 Création d'une nouvelle politique d'assignation pour '$apName'..." -ForegroundColor Green
                        $policy = New-PolitiqueAssignationEntra -AccessPackageId $apId -DisplayName $policyName -ApproverUserIds $approverIds.ToArray()
                    }

                    if ($policy -and -not [string]::IsNullOrWhiteSpace($policy.id)) {
                        $deployedResources.Add([PSCustomObject]@{
                            Type        = "Politique d'Assignation"
                            DisplayName = $policyName
                            Id          = $policy.id
                            Status      = "Actif"
                        })
                    }
                } catch {
                    Write-Warning "  ⚠️ Erreur lors de la configuration de la politique pour '$apName' : $_"
                    $errors.Add("Erreur politique '$apName' : $_")
                }
            }
        }

        # -------------------------------------------------------------------
        # ÉTAPE 6 : Nettoyage des Access Packages Obsolètes
        # -------------------------------------------------------------------
        if ($existingAps) {
            foreach ($oldAp in $existingAps) {
                if ($oldAp.displayName -and -not $activeApNames.Contains($oldAp.displayName)) {
                    Write-Host "  🗑️ Suppression de l'Access Package obsolète '$($oldAp.displayName)' ($($oldAp.id))..." -ForegroundColor Red
                    $oldPolicy = Get-PolitiqueAssignationEntra -AccessPackageId $oldAp.id
                    if ($oldPolicy) {
                        Remove-PolitiqueAssignationEntra -PolicyId $oldPolicy.id | Out-Null
                    }
                    Remove-AccessPackageEntra -AccessPackageId $oldAp.id | Out-Null
                }
            }
        }
    }

    if ($errors.Count -eq 0) {
        Write-Host "`n✅ Déploiement Entra ID terminé avec succès !" -ForegroundColor Green
        if ($LiveCommentId -gt 0 -and (Get-Command -Name "Formater-RapportDeploiementCD" -ErrorAction SilentlyContinue)) {
            $finalSummary = Formater-RapportDeploiementCD -DeployedResources $deployedResources
            Update-LiveProgress $finalSummary
        }
    } else {
        Write-Host "`n❌ Déploiement Entra ID terminé avec des erreurs." -ForegroundColor Red
        if ($LiveCommentId -gt 0) {
            $errList = ($errors | ForEach-Object { "- $_" }) -join "`n"
            Update-LiveProgress "### ❌ Déploiement Entra ID terminé avec des erreurs`n`n$errList"
        }
    }

    return [PSCustomObject]@{
        Success           = ($errors.Count -eq 0)
        DeployedResources = $deployedResources.ToArray()
        Errors            = $errors.ToArray()
    }
}

Export-ModuleMember -Function Comparer-EtatEntra, Synchroniser-EtatEntra
