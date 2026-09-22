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
        $SSoTPrerequisites = $null
    )

    Write-Verbose "Début du calcul différentiel (Diff) Git vs Entra ID..."

    # Récupération de tous les catalogues existants dans Entra ID
    $existingCatalogs = Get-CatalogueEntra
    $catalogMapByName = @{}
    if ($existingCatalogs) {
        foreach ($c in $existingCatalogs) {
            if ($c.displayName) {
                $catalogMapByName[$c.displayName.Trim().ToLowerInvariant()] = $c
            }
        }
    }

    $catalogsToCreate = [System.Collections.Generic.List[object]]::new()
    $catalogsToUpdate = [System.Collections.Generic.List[object]]::new()
    $catalogsUnchanged = [System.Collections.Generic.List[object]]::new()

    $ownersToAdd = [System.Collections.Generic.List[object]]::new()
    $catalogResourcesToAdd = [System.Collections.Generic.List[object]]::new()

    $accessPackagesToCreate = [System.Collections.Generic.List[object]]::new()
    $accessPackagesToUpdate = [System.Collections.Generic.List[object]]::new()
    $accessPackagesUnchanged = [System.Collections.Generic.List[object]]::new()
    $accessPackagesToDelete = [System.Collections.Generic.List[object]]::new()

    $rolesToAdd = [System.Collections.Generic.List[object]]::new()
    $policiesToCreate = [System.Collections.Generic.List[object]]::new()
    $policiesToUpdate = [System.Collections.Generic.List[object]]::new()

    foreach ($doc in $Declarations) {
        $appName = $doc.app_name
        $catName = $(if ($doc.catalog_name) { $doc.catalog_name.Trim() } else { $appName })
        $appDesc = $(if ($doc.app_description) { $doc.app_description.Trim() } else { "Catalogue $catName" })

        $catKey = $catName.ToLowerInvariant()
        $existingCat = $(if ($catalogMapByName.ContainsKey($catKey)) { $catalogMapByName[$catKey] } else { $null })

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
        $existingOwnersSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        if ($existingCat) {
            $catId = $existingCat.id

            # Récupération des packages existants du catalogue
            $existingAps = Get-AccessPackageEntra -CatalogId $catId
            if ($existingAps) {
                foreach ($ap in $existingAps) {
                    if ($ap.displayName) {
                        $existingApsMap[$ap.displayName.Trim().ToLowerInvariant()] = $ap
                    }
                }
            }

            # Récupération des ressources existantes dans le catalogue
            $catResources = Get-RessourcesCatalogue -CatalogId $catId
            if ($catResources) {
                foreach ($res in $catResources) {
                    if ($res.originId) {
                        $existingCatResourcesMap[$res.originId.Trim().ToLowerInvariant()] = $res
                    }
                }
            }

            # Récupération des Catalog Owners actuels
            $owners = Get-ProprietairesCatalogue -CatalogId $catId
            if ($owners) {
                foreach ($own in $owners) {
                    if ($own.principalId) {
                        $existingOwnersSet.Add($own.principalId.Trim()) | Out-Null
                    }
                }
            }
        }

        # Détection des paquets déclarés
        $declaredApNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($ap in $doc.access_packages) {
            $apName = Calculer-NomAccessPackage -AccessPackage $ap
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
            }

            # Propriétaires (authorization_owners -> Catalog Owners)
            if ($ap.authorization_owners) {
                foreach ($ownerEmail in $ap.authorization_owners) {
                    $ownersToAdd.Add(@{
                        CatalogName = $catName
                        UserEmail   = $ownerEmail
                    })
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

    $createsCount = $catalogsToCreate.Count + $accessPackagesToCreate.Count + $policiesToCreate.Count
    $updatesCount = $catalogsToUpdate.Count + $accessPackagesToUpdate.Count + $policiesToUpdate.Count
    $deletesCount = $accessPackagesToDelete.Count
    $noChangeCount = $catalogsUnchanged.Count + $accessPackagesUnchanged.Count

    return [PSCustomObject]@{
        CatalogsToCreate        = $catalogsToCreate.ToArray()
        CatalogsToUpdate        = $catalogsToUpdate.ToArray()
        CatalogsUnchanged       = $catalogsUnchanged.ToArray()
        CatalogOwnersToAdd      = $ownersToAdd.ToArray()
        CatalogResourcesToAdd   = $catalogResourcesToAdd.ToArray()
        AccessPackagesToCreate  = $accessPackagesToCreate.ToArray()
        AccessPackagesToUpdate  = $accessPackagesToUpdate.ToArray()
        AccessPackagesUnchanged = $accessPackagesUnchanged.ToArray()
        AccessPackagesToDelete  = $accessPackagesToDelete.ToArray()
        PoliciesToCreate        = $policiesToCreate.ToArray()
        PoliciesToUpdate        = $policiesToUpdate.ToArray()
        CreatesCount            = $createsCount
        UpdatesCount            = $updatesCount
        DeletesCount            = $deletesCount
        NoChangeCount           = $noChangeCount
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
        $DiffReport = $null
    )

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "🚀 DÉPLOIEMENT DÉCLARATIF ENTRA ID (100% POWERSHELL)" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan

    $deployedResources = [System.Collections.Generic.List[PSObject]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($doc in $Declarations) {
        $appName = $doc.app_name
        $catName = $(if ($doc.catalog_name) { $doc.catalog_name.Trim() } else { $appName })
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
        # ÉTAPE 2 : Assignation des Propriétaires du Catalogue (Catalog Owners)
        # -------------------------------------------------------------------
        $allOwners = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($ap in $doc.access_packages) {
            if ($ap.authorization_owners) {
                foreach ($email in $ap.authorization_owners) {
                    if (-not [string]::IsNullOrWhiteSpace($email)) {
                        $allOwners.Add($email.Trim()) | Out-Null
                    }
                }
            }
        }

        foreach ($ownerEmail in $allOwners) {
            $userObj = Resolve-GraphUser -UserEmailOrUpn $ownerEmail
            if ($userObj) {
                try {
                    Add-ProprietaireCatalogue -CatalogId $catalogId -UserId $userObj.id | Out-Null
                    Write-Host "  👑 Propriétaire '$ownerEmail' assigné au catalogue." -ForegroundColor Green
                } catch {
                    Write-Warning "  ⚠️ Erreur assignation propriétaire '$ownerEmail' : $_"
                }
            } else {
                Write-Warning "  ⚠️ Utilisateur '$ownerEmail' introuvable dans l'annuaire pour l'assignation de propriétaire."
            }
        }

        # -------------------------------------------------------------------
        # ÉTAPE 3 : Onboarding des Ressources dans le Catalogue
        # -------------------------------------------------------------------
        $onboardedResourcesMap = @{}

        foreach ($ap in $doc.access_packages) {
            if (-not $ap.resources) { continue }
            foreach ($res in $ap.resources) {
                $rType = $res.resource_type
                if ($rType -eq "EntraID Group" -or $rType -eq "Group") {
                    $grpObj = Resolve-GraphGroup -GroupName $res.group_name
                    if ($grpObj) {
                        try {
                            Add-RessourceCatalogue -CatalogId $catalogId -OriginId $grpObj.id -OriginSystem "AadGroup" | Out-Null
                            $onboardedResourcesMap[$res.group_name.ToLowerInvariant()] = $grpObj.id
                            Write-Host "  📁 Groupe '$($res.group_name)' associé au catalogue." -ForegroundColor Gray
                        } catch {
                            Write-Warning "  ⚠️ Erreur onboarding groupe '$($res.group_name)' : $_"
                        }
                    }
                } elseif ($rType -eq "Application Role" -or $rType -eq "Application") {
                    $spObj = Resolve-GraphServicePrincipal -DisplayName $res.enterprise_app
                    if ($spObj) {
                        try {
                            Add-RessourceCatalogue -CatalogId $catalogId -OriginId $spObj.id -OriginSystem "AadApplication" | Out-Null
                            $onboardedResourcesMap[$res.enterprise_app.ToLowerInvariant()] = $spObj.id
                            Write-Host "  📱 Application '$($res.enterprise_app)' associée au catalogue." -ForegroundColor Gray
                        } catch {
                            Write-Warning "  ⚠️ Erreur onboarding application '$($res.enterprise_app)' : $_"
                        }
                    }
                }
            }
        }

        # -------------------------------------------------------------------
        # ÉTAPE 4 : Création / Mise à jour des Access Packages
        # -------------------------------------------------------------------
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

        foreach ($ap in $doc.access_packages) {
            $apName = Calculer-NomAccessPackage -AccessPackage $ap
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

            $apId = $apObj.id
            $deployedResources.Add([PSCustomObject]@{
                Type        = "Access Package"
                DisplayName = $apName
                Id          = $apId
                Status      = "Actif"
            })

            # ---------------------------------------------------------------
            # ÉTAPE 5 : Liaison des Rôles de Ressources (Resource Roles)
            # ---------------------------------------------------------------
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
                        if ($res.role -and $res.role.Equals("Owner", [StringComparison]::OrdinalIgnoreCase)) {
                            $roleToAssign = "Owner"
                        }
                    } elseif ($rType -eq "Application Role" -or $rType -eq "Application") {
                        $targetOriginId = $(if ($onboardedResourcesMap.ContainsKey($res.enterprise_app.ToLowerInvariant())) {
                            $onboardedResourcesMap[$res.enterprise_app.ToLowerInvariant()]
                        } else {
                            $sp = Resolve-GraphServicePrincipal -DisplayName $res.enterprise_app
                            if ($sp) { $sp.id } else { $null }
                        })
                        if ($res.app_role) {
                            $roleToAssign = $res.app_role
                        }
                    }

                    if ($targetOriginId) {
                        try {
                            Add-RoleRessourceAccessPackage -CatalogId $catalogId -AccessPackageId $apId -ResourceOriginId $targetOriginId -RoleName $roleToAssign | Out-Null
                            Write-Host "  🔗 Rôle '$roleToAssign' lié à l'Access Package '$apName'." -ForegroundColor Gray
                        } catch {
                            Write-Warning "  ⚠️ Erreur liaison de rôle sur '$apName' : $_"
                        }
                    }
                }
            }

            # ---------------------------------------------------------------
            # ÉTAPE 6 : Politique d'Assignation (Approval & Duration)
            # ---------------------------------------------------------------
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
            $policy = Get-PolitiqueAssignationEntra -AccessPackageId $apId

            if (-not $policy) {
                Write-Host "  📜 Création de la politique d'assignation pour '$apName'..." -ForegroundColor Green
                $policy = New-PolitiqueAssignationEntra -AccessPackageId $apId -DisplayName $policyName -ApproverUserIds $approverIds.ToArray()
            } else {
                Write-Host "  ✅ Politique d'assignation existante trouvée ($($policy.id))." -ForegroundColor Gray
                Set-PolitiqueAssignationEntra -PolicyId $policy.id -DisplayName $policyName -ApproverUserIds $approverIds.ToArray() | Out-Null
            }

            if ($policy) {
                $deployedResources.Add([PSCustomObject]@{
                    Type        = "Politique d'Assignation"
                    DisplayName = $policyName
                    Id          = $policy.id
                    Status      = "Actif"
                })
            }
        }

        # -------------------------------------------------------------------
        # ÉTAPE 7 : Nettoyage des Access Packages Obsolètes
        # -------------------------------------------------------------------
        if ($existingAps) {
            foreach ($oldAp in $existingAps) {
                if ($oldAp.displayName -and -not $activeApNames.Contains($oldAp.displayName)) {
                    Write-Host "  🗑️ Suppression de l'Access Package obsolète '$($oldAp.displayName)' ($($oldAp.id))..." -ForegroundColor Red
                    # Suppression préalable de la politique si présente
                    $oldPolicy = Get-PolitiqueAssignationEntra -AccessPackageId $oldAp.id
                    if ($oldPolicy) {
                        Remove-PolitiqueAssignationEntra -PolicyId $oldPolicy.id | Out-Null
                    }
                    Remove-AccessPackageEntra -AccessPackageId $oldAp.id | Out-Null
                }
            }
        }
    }

    Write-Host "`n✅ Déploiement Entra ID terminé avec succès !" -ForegroundColor Green

    return [PSCustomObject]@{
        Success           = ($errors.Count -eq 0)
        DeployedResources = $deployedResources.ToArray()
        Errors            = $errors.ToArray()
    }
}

Export-ModuleMember -Function Comparer-EtatEntra, Synchroniser-EtatEntra
