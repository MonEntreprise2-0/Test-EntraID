# ============================================================================
# MODULE : GestionAccessPackages
# ============================================================================
# Rôle :
#   Gère le cycle de vie complet des Access Packages Entra ID :
#   - Création, modification, suppression des paquets d'accès
#   - Association des ressources du catalogue avec leurs rôles (Member / Owner / App Role)
#   - Configuration des politiques d'assignation (approbateurs authorization_owners,
#     délai de 14 jours, durée d'assignation).
#
# Auteur : Ardian Cloud IAM & DevOps
# ============================================================================

<#
.SYNOPSIS
    Récupère un ou plusieurs Access Packages.
.PARAMETER AccessPackageId
    Identifiant GUID de l'Access Package.
.PARAMETER CatalogId
    Identifiant GUID du catalogue parent.
.PARAMETER DisplayName
    Nom d'affichage pour filtrer le résultat.
#>
function Get-AccessPackageEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $false)]
        [string]$CatalogId,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName
    )

    if (-not [string]::IsNullOrWhiteSpace($AccessPackageId)) {
        return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackages/$AccessPackageId" -Method GET -IgnoreNotFound
    }

    $endpoint = "/identityGovernance/entitlementManagement/accessPackages?`$top=999"
    if (-not [string]::IsNullOrWhiteSpace($CatalogId)) {
        $filter = "catalog/id eq '$CatalogId'"
        $endpoint = "/identityGovernance/entitlementManagement/accessPackages?`$filter=$([System.Uri]::EscapeDataString($filter))&`$top=999"
    }

    $allAps = Invoke-GraphRequest -Endpoint $endpoint -Method GET -AllPages
    if (-not $allAps) {
        return @()
    }

    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
        $clean = $DisplayName.Trim()
        foreach ($ap in $allAps) {
            if ($ap.displayName -and $ap.displayName.Equals($clean, [StringComparison]::OrdinalIgnoreCase)) {
                return $ap
            }
        }
        return $null
    }

    return $allAps
}

<#
.SYNOPSIS
    Crée un nouvel Access Package rattaché à un catalogue.
#>
function New-AccessPackageEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogId,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$Description = "Access Package géré par GitOps",

        [Parameter(Mandatory = $false)]
        [bool]$IsHidden = $false
    )

    $body = @{
        displayName = $DisplayName.Trim()
        description = $Description.Trim()
        isHidden    = $IsHidden
        catalog     = @{
            id = $CatalogId
        }
    }

    Write-Verbose "Création de l'Access Package '$DisplayName' dans le catalogue '$CatalogId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackages" -Method POST -Body $body
}

<#
.SYNOPSIS
    Met à jour un Access Package existant.
#>
function Set-AccessPackageEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        $IsHidden = $null
    )

    $body = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) { $body["displayName"] = $DisplayName.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($Description)) { $body["description"] = $Description.Trim() }
    if ($null -ne $IsHidden) { $body["isHidden"] = [bool]$IsHidden }

    if ($body.Count -eq 0) {
        return $null
    }

    Write-Verbose "Mise à jour de l'Access Package '$AccessPackageId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackages/$AccessPackageId" -Method PATCH -Body $body
}

<#
.SYNOPSIS
    Supprime un Access Package.
#>
function Remove-AccessPackageEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId
    )

    Write-Verbose "Suppression de l'Access Package '$AccessPackageId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackages/$AccessPackageId" -Method DELETE -IgnoreNotFound
}

<#
.SYNOPSIS
    Liste les liaisons de rôles de ressources (accessPackageResourceRoleScopes) d'un Access Package.
#>
function Get-RolesRessourcesAccessPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId
    )

    $endpoint = "/identityGovernance/entitlementManagement/accessPackages/$AccessPackageId/accessPackageResourceRoleScopes?`$expand=accessPackageResourceRole,accessPackageResourceScope&`$top=999"
    try {
        $res = Invoke-GraphRequest -Endpoint $endpoint -ApiVersion "beta" -Method GET -AllPages -IgnoreNotFound
        if ($res) { return $res }
    } catch {
        Write-Verbose "Échec de récupération des rôles via endpoint beta : $_"
    }

    return Invoke-GraphRequest -Endpoint $endpoint -ApiVersion "v1.0" -Method GET -AllPages -IgnoreNotFound
}

<#
.SYNOPSIS
    Associe un rôle sur une ressource du catalogue à un Access Package.
.DESCRIPTION
    Recherche la définition du rôle et du scope de la ressource dans le catalogue,
    puis poste l'association dans l'Access Package via l'endpoint beta de Microsoft Graph.
.PARAMETER CatalogId
    Identifiant du catalogue parent.
.PARAMETER AccessPackageId
    Identifiant de l'Access Package.
.PARAMETER ResourceOriginId
    Object ID du groupe ou du Service Principal dans Entra ID.
.PARAMETER RoleName
    Nom du rôle ('Member' ou 'Owner' pour un groupe, ou libellé du rôle applicatif).
#>
function Add-RoleRessourceAccessPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogId,

        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceOriginId,

        [Parameter(Mandatory = $false)]
        [string]$RoleName = "Member"
    )

    # 1. Vérifier si l'association existe déjà dans l'Access Package
    $existingRoles = Get-RolesRessourcesAccessPackage -AccessPackageId $AccessPackageId
    if ($existingRoles) {
        foreach ($rs in $existingRoles) {
            $scope = $rs.accessPackageResourceScope
            $role = $rs.accessPackageResourceRole
            if ($scope -and $scope.originId -and $scope.originId.Equals($ResourceOriginId, [StringComparison]::OrdinalIgnoreCase)) {
                if ($role -and $role.displayName -and $role.displayName.Equals($RoleName, [StringComparison]::OrdinalIgnoreCase)) {
                    Write-Verbose "Le rôle '$RoleName' sur la ressource '$ResourceOriginId' est déjà associé à l'Access Package '$AccessPackageId'."
                    return $rs
                }
            }
        }
    }

    # 2. Récupérer les ressources du catalogue avec leurs rôles et scopes développés
    $catResources = Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackageCatalogs/$CatalogId/accessPackageResources?`$expand=accessPackageResourceRoles,accessPackageResourceScopes&`$top=999" -ApiVersion "beta" -Method GET -AllPages -IgnoreNotFound

    $targetResource = $null
    if ($catResources) {
        foreach ($r in $catResources) {
            if ($r.originId -and $r.originId.Equals($ResourceOriginId, [StringComparison]::OrdinalIgnoreCase)) {
                $targetResource = $r
                break
            }
        }
    }

    if (-not $targetResource) {
        throw "La ressource '$ResourceOriginId' n'a pas été trouvée dans le catalogue '$CatalogId'. Assurez-vous qu'elle est d'abord rattachée au catalogue via Add-RessourceCatalogue."
    }

    # 3. Sélection du rôle correspondant
    $targetRole = $null
    if ($targetResource.accessPackageResourceRoles) {
        foreach ($r in $targetResource.accessPackageResourceRoles) {
            if ($r.displayName -and $r.displayName.Equals($RoleName, [StringComparison]::OrdinalIgnoreCase)) {
                $targetRole = $r
                break
            }
        }
        # Fallback pour les groupes si displayName est vide mais originId contient le rôle
        if (-not $targetRole) {
            foreach ($r in $targetResource.accessPackageResourceRoles) {
                if ($r.originId -and $r.originId.StartsWith($RoleName, [StringComparison]::OrdinalIgnoreCase)) {
                    $targetRole = $r
                    break
                }
            }
        }
    }

    # 4. Sélection du scope
    $targetScope = $null
    if ($targetResource.accessPackageResourceScopes -and $targetResource.accessPackageResourceScopes.Count -gt 0) {
        $targetScope = $targetResource.accessPackageResourceScopes[0]
    }

    if (-not $targetRole -or -not $targetScope) {
        throw "Impossible de déterminer le rôle '$RoleName' ou le scope pour la ressource '$ResourceOriginId' dans le catalogue '$CatalogId'."
    }

    $body = @{
        accessPackageResourceRole = @{
            originId              = $targetRole.originId
            displayName           = $targetRole.displayName
            originSystem          = $targetRole.originSystem
            accessPackageResource = @{
                id = $targetResource.id
            }
        }
        accessPackageResourceScope = @{
            originId     = $targetScope.originId
            originSystem = $targetScope.originSystem
        }
    }

    Write-Verbose "Liaison du rôle '$RoleName' ($($targetRole.originId)) à l'Access Package '$AccessPackageId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackages/$AccessPackageId/accessPackageResourceRoleScopes" -ApiVersion "beta" -Method POST -Body $body
}

<#
.SYNOPSIS
    Supprime une liaison de rôle de ressource d'un Access Package.
#>
function Remove-RoleRessourceAccessPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [string]$RoleScopeId
    )

    Write-Verbose "Suppression de la liaison de rôle '$RoleScopeId' de l'Access Package '$AccessPackageId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackages/$AccessPackageId/accessPackageResourceRoleScopes/$RoleScopeId" -ApiVersion "beta" -Method DELETE -IgnoreNotFound
}

<#
.SYNOPSIS
    Récupère la politique d'assignation d'un Access Package.
#>
function Get-PolitiqueAssignationEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $false)]
        [string]$PolicyId
    )

    if (-not [string]::IsNullOrWhiteSpace($PolicyId)) {
        return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/assignmentPolicies/$PolicyId" -Method GET -IgnoreNotFound
    }

    if (-not [string]::IsNullOrWhiteSpace($AccessPackageId)) {
        $filter = "accessPackage/id eq '$AccessPackageId'"
        $policies = Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/assignmentPolicies?`$filter=$([System.Uri]::EscapeDataString($filter))&`$top=999" -Method GET -AllPages -IgnoreNotFound
        if ($policies -and $policies.Count -gt 0) {
            return $policies[0]
        }

        # Fallback endpoint beta
        try {
            $policiesBeta = Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackageAssignmentPolicies?`$filter=$([System.Uri]::EscapeDataString($filter))&`$top=999" -ApiVersion "beta" -Method GET -AllPages -IgnoreNotFound
            if ($policiesBeta -and $policiesBeta.Count -gt 0) {
                return $policiesBeta[0]
            }
        } catch {
            Write-Verbose "Endpoint beta non disponible pour la politique : $_"
        }
    }

    return $null
}

<#
.SYNOPSIS
    Crée une politique d'assignation pour un Access Package.
.DESCRIPTION
    Configure :
    - Périmètre des demandeurs : AllExistingDirectoryMemberUsers
    - Approbation : Requise si des approbateurs (authorization_owners) sont fournis,
      délai d'approbation fixé à 14 jours (approvalStageTimeOutInDays = 14)
    - Durée d'assignation : Expire après DurationInDays (défaut 365 jours).
.PARAMETER AccessPackageId
    GUID de l'Access Package associé.
.PARAMETER DisplayName
    Nom de la politique.
.PARAMETER ApproverUserIds
    Liste des identifiants (GUID) des utilisateurs approbateurs (authorization_owners).
.PARAMETER DurationInDays
    Durée de validité de l'assignation en jours (défaut : 365).
.PARAMETER ApprovalTimeoutInDays
    Délai imparti à l'approbateur pour valider la demande (défaut : 14).
#>
function New-PolitiqueAssignationEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string[]]$ApproverUserIds = @(),

        [Parameter(Mandatory = $false)]
        [int]$DurationInDays = 365,

        [Parameter(Mandatory = $false)]
        [int]$ApprovalTimeoutInDays = 14
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        $DisplayName = "Politique d'assignation standard"
    }

    $approvalRequired = ($ApproverUserIds -and $ApproverUserIds.Count -gt 0)

    $approvalSettings = $null
    if ($approvalRequired) {
        $primaryApprovers = [System.Collections.Generic.List[object]]::new()
        foreach ($userId in $ApproverUserIds) {
            if (-not [string]::IsNullOrWhiteSpace($userId)) {
                $primaryApprovers.Add(@{
                    "@odata.type" = "#microsoft.graph.singleUser"
                    userId        = $userId.Trim()
                })
            }
        }

        $approvalSettings = [ordered]@{
            isApprovalRequiredForAdd    = $true
            isApprovalRequiredForUpdate = $false
            stages                      = @(
                [ordered]@{
                    durationBeforeAutomaticDenial   = "P$($ApprovalTimeoutInDays)D"
                    isApproverJustificationRequired = $false
                    isEscalationEnabled             = $false
                    durationBeforeEscalation        = "PT0S"
                    primaryApprovers                = $primaryApprovers.ToArray()
                    fallbackPrimaryApprovers        = @()
                    escalationApprovers             = @()
                    fallbackEscalationApprovers     = @()
                }
            )
        }
    } else {
        $approvalSettings = [ordered]@{
            isApprovalRequiredForAdd    = $false
            isApprovalRequiredForUpdate = $false
            stages                      = @()
        }
    }

    $expirationObj = $(if ($DurationInDays -and $DurationInDays -gt 0) {
        [ordered]@{
            type     = "afterDuration"
            duration = "P$($DurationInDays)D"
        }
    } else {
        [ordered]@{
            type = "noExpiration"
        }
    })

    $reqSettings = [ordered]@{
        enableTargetsToSelfAddAccess           = $true
        enableTargetsToSelfUpdateAccess        = $false
        enableTargetsToSelfRemoveAccess        = $true
        allowCustomAssignmentSchedule          = $false
        enableOnBehalfRequestorsToAddAccess    = $false
        enableOnBehalfRequestorsToUpdateAccess = $false
        enableOnBehalfRequestorsToRemoveAccess = $false
        onBehalfRequestors                     = @()
    }

    $body = [ordered]@{
        displayName              = $DisplayName
        description              = "Politique gérée par GitOps - $DisplayName"
        allowedTargetScope       = "allDirectoryUsers"
        specificAllowedTargets   = @()
        automaticRequestSettings = $null
        expiration               = $expirationObj
        requestorSettings        = $reqSettings
        requestApprovalSettings  = $approvalSettings
        accessPackage            = @{ id = $AccessPackageId }
    }

    Write-Verbose "Création de la politique d'assignation pour l'Access Package '$AccessPackageId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/assignmentPolicies" -Method POST -Body $body
}

<#
.SYNOPSIS
    Met à jour une politique d'assignation existante.
#>
function Set-PolitiqueAssignationEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyId,

        [Parameter(Mandatory = $false)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string[]]$ApproverUserIds,

        [Parameter(Mandatory = $false)]
        [int]$DurationInDays = 365,

        [Parameter(Mandatory = $false)]
        [int]$ApprovalTimeoutInDays = 14
    )

    $approvalRequired = ($ApproverUserIds -and $ApproverUserIds.Count -gt 0)

    $approvalSettings = $null
    if ($approvalRequired) {
        $primaryApprovers = [System.Collections.Generic.List[object]]::new()
        foreach ($userId in $ApproverUserIds) {
            if (-not [string]::IsNullOrWhiteSpace($userId)) {
                $primaryApprovers.Add(@{
                    "@odata.type" = "#microsoft.graph.singleUser"
                    userId        = $userId.Trim()
                })
            }
        }

        $approvalSettings = [ordered]@{
            isApprovalRequiredForAdd    = $true
            isApprovalRequiredForUpdate = $false
            stages                      = @(
                [ordered]@{
                    durationBeforeAutomaticDenial   = "P$($ApprovalTimeoutInDays)D"
                    isApproverJustificationRequired = $false
                    isEscalationEnabled             = $false
                    durationBeforeEscalation        = "PT0S"
                    primaryApprovers                = $primaryApprovers.ToArray()
                    fallbackPrimaryApprovers        = @()
                    escalationApprovers             = @()
                    fallbackEscalationApprovers     = @()
                }
            )
        }
    } else {
        $approvalSettings = [ordered]@{
            isApprovalRequiredForAdd    = $false
            isApprovalRequiredForUpdate = $false
            stages                      = @()
        }
    }

    $expirationObj = $(if ($DurationInDays -and $DurationInDays -gt 0) {
        [ordered]@{
            type     = "afterDuration"
            duration = "P$($DurationInDays)D"
        }
    } else {
        [ordered]@{
            type = "noExpiration"
        }
    })

    $reqSettings = [ordered]@{
        enableTargetsToSelfAddAccess           = $true
        enableTargetsToSelfUpdateAccess        = $false
        enableTargetsToSelfRemoveAccess        = $true
        allowCustomAssignmentSchedule          = $false
        enableOnBehalfRequestorsToAddAccess    = $false
        enableOnBehalfRequestorsToUpdateAccess = $false
        enableOnBehalfRequestorsToRemoveAccess = $false
        onBehalfRequestors                     = @()
    }

    # Récupération de la politique existante pour conserver ses métadonnées requises par le PUT
    $existing = Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/assignmentPolicies/$PolicyId" -Method GET -IgnoreNotFound
    $targetApId = $(if (-not [string]::IsNullOrWhiteSpace($AccessPackageId)) {
        $AccessPackageId
    } elseif ($existing -and $existing.accessPackage -and $existing.accessPackage.id) {
        $existing.accessPackage.id
    } else {
        $null
    })

    $targetScope = $(if ($existing -and $existing.allowedTargetScope) { $existing.allowedTargetScope } else { "allDirectoryUsers" })
    $specificTargets = $(if ($existing -and $existing.specificAllowedTargets) { $existing.specificAllowedTargets } else { @() })
    $policyDesc = $(if ($existing -and $existing.description) { $existing.description } else { "Politique gérée par GitOps" })
    $finalDisplayName = $(if (-not [string]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName } elseif ($existing -and $existing.displayName) { $existing.displayName } else { "Politique d'assignation standard" })

    $body = [ordered]@{
        id                       = $PolicyId
        displayName              = $finalDisplayName
        description              = $policyDesc
        allowedTargetScope       = $targetScope
        specificAllowedTargets   = $specificTargets
        automaticRequestSettings = $null
        expiration               = $expirationObj
        requestorSettings        = $reqSettings
        requestApprovalSettings  = $approvalSettings
    }

    if ($targetApId) {
        $body["accessPackage"] = @{ id = $targetApId }
    }

    Write-Verbose "Mise à jour de la politique d'assignation '$PolicyId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/assignmentPolicies/$PolicyId" -Method PUT -Body $body
}

<#
.SYNOPSIS
    Supprime une politique d'assignation d'Access Package.
.DESCRIPTION
    Gère gracieusement le comportement spécifique de Microsoft Graph
    (retourne 403 Forbidden sur les GET ultérieurs une fois supprimé).
#>
function Remove-PolitiqueAssignationEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyId
    )

    Write-Verbose "Suppression de la politique d'assignation '$PolicyId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/assignmentPolicies/$PolicyId" -Method DELETE -IgnoreNotFound
}

Export-ModuleMember -Function Get-AccessPackageEntra, New-AccessPackageEntra, Set-AccessPackageEntra, Remove-AccessPackageEntra, `
    Get-RolesRessourcesAccessPackage, Add-RoleRessourceAccessPackage, Remove-RoleRessourceAccessPackage, `
    Get-PolitiqueAssignationEntra, New-PolitiqueAssignationEntra, Set-PolitiqueAssignationEntra, Remove-PolitiqueAssignationEntra
