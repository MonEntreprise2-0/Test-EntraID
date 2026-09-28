# ============================================================================
# MODULE : GestionCatalogues
# ============================================================================
# Rôle :
#   Gère le cycle de vie des catalogues d'Entitlement Management Entra ID,
#   l'onboarding des ressources (groupes et applications) dans les catalogues
#   et l'assignation des propriétaires de catalogues (Catalog Owners).
# ============================================================================

<#
.SYNOPSIS
    Récupère un ou plusieurs catalogues Entra ID.
.DESCRIPTION
    Interroge /v1.0/identityGovernance/entitlementManagement/catalogs.
    Permet la recherche par ID ou par nom d'affichage (insensible à la casse).
.PARAMETER CatalogId
    Identifiant GUID du catalogue.
.PARAMETER DisplayName
    Nom d'affichage du catalogue à rechercher.
#>
function Get-CatalogueEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$CatalogId,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName
    )

    if (-not [string]::IsNullOrWhiteSpace($CatalogId)) {
        return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/catalogs/$CatalogId" -Method GET -IgnoreNotFound
    }

    $allCatalogs = Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/catalogs?`$top=999" -Method GET -AllPages
    if (-not $allCatalogs) {
        return @()
    }

    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
        $cleanName = $DisplayName.Trim()
        foreach ($cat in $allCatalogs) {
            if ($cat.displayName -and $cat.displayName.Equals($cleanName, [StringComparison]::OrdinalIgnoreCase)) {
                return $cat
            }
        }
        $normSearch = ($cleanName -replace '[\s_]+', '-' -replace '-+', '-').ToLowerInvariant()
        foreach ($cat in $allCatalogs) {
            if ($cat.displayName) {
                $catNorm = ($cat.displayName.Trim() -replace '[\s_]+', '-' -replace '-+', '-').ToLowerInvariant()
                if ($catNorm -eq $normSearch) {
                    return $cat
                }
            }
        }
        return $null
    }

    return $allCatalogs
}

<#
.SYNOPSIS
    Crée un nouveau catalogue d'Entitlement Management dans Entra ID.
#>
function New-CatalogueEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$Description = "Géré par GitOps",

        [Parameter(Mandatory = $false)]
        [bool]$IsExternallyVisible = $false
    )

    $body = @{
        displayName         = $DisplayName.Trim()
        description         = $Description.Trim()
        isExternallyVisible = $IsExternallyVisible
    }

    Write-Verbose "Création du catalogue Entra ID '$DisplayName'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/catalogs" -Method POST -Body $body
}

<#
.SYNOPSIS
    Met à jour les propriétés d'un catalogue existant.
#>
function Set-CatalogueEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogId,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        $IsExternallyVisible = $null
    )

    $body = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) { $body["displayName"] = $DisplayName.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($Description)) { $body["description"] = $Description.Trim() }
    if ($null -ne $IsExternallyVisible) { $body["isExternallyVisible"] = [bool]$IsExternallyVisible }

    if ($body.Count -eq 0) {
        return $null
    }

    Write-Verbose "Mise à jour du catalogue Entra ID '$CatalogId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/catalogs/$CatalogId" -Method PATCH -Body $body
}

<#
.SYNOPSIS
    Supprime un catalogue d'Entitlement Management.
#>
function Remove-CatalogueEntra {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogId
    )

    Write-Verbose "Suppression du catalogue Entra ID '$CatalogId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/catalogs/$CatalogId" -Method DELETE -IgnoreNotFound
}

<#
.SYNOPSIS
    Liste toutes les ressources (groupes, applications) actuellement associées à un catalogue.
#>
function Get-RessourcesCatalogue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogId
    )

    try {
        $resources = Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackageCatalogs/$CatalogId/accessPackageResources?`$top=999" -ApiVersion "beta" -Method GET -AllPages -IgnoreNotFound
        if ($null -ne $resources) {
            return $resources
        }
        return @()
    } catch {
        Write-Verbose "Échec de récupération des ressources du catalogue via endpoint beta : $_"
        return @()
    }
}

<#
.SYNOPSIS
    Associe (onboarde) une ressource existante (Groupe ou Enterprise App) à un catalogue.
.DESCRIPTION
    Crée une requête 'AdminAdd' via /accessPackageResourceRequests.
.PARAMETER CatalogId
    Identifiant du catalogue cible.
.PARAMETER OriginId
    Object ID du groupe ou du Service Principal dans Entra ID.
.PARAMETER OriginSystem
    Système d'origine ('AadGroup' pour un groupe, 'AadApplication' pour une application).
#>
function Add-RessourceCatalogue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogId,

        [Parameter(Mandatory = $true)]
        [string]$OriginId,

        [Parameter(Mandatory = $true)]
        [ValidateSet("AadGroup", "AadApplication", "SharePointOnline")]
        [string]$OriginSystem,

        [Parameter(Mandatory = $false)]
        $ExistingResources = $null
    )

    # Vérification si la ressource est déjà onboardée dans le catalogue (avec réutilisation du cache si fourni)
    $existing = if ($null -ne $ExistingResources) { $ExistingResources } else { Get-RessourcesCatalogue -CatalogId $CatalogId }
    if ($existing) {
        foreach ($res in $existing) {
            if ($res.originId -and $res.originId.Equals($OriginId, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Verbose "La ressource '$OriginId' ($OriginSystem) est déjà rattachée au catalogue '$CatalogId'."
                return $res
            }
        }
    }

    $body = @{
        catalogId             = $CatalogId
        requestType           = "AdminAdd"
        accessPackageResource = @{
            originId     = $OriginId
            originSystem = $OriginSystem
        }
    }

    Write-Verbose "Ajout de la ressource '$OriginId' ($OriginSystem) au catalogue '$CatalogId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackageResourceRequests" -ApiVersion "beta" -Method POST -Body $body
}

<#
.SYNOPSIS
    Retire une ressource d'un catalogue.
#>
function Remove-RessourceCatalogue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    $body = @{
        catalogId             = $CatalogId
        requestType           = "AdminRemove"
        accessPackageResource = @{
            id = $ResourceId
        }
    }

    Write-Verbose "Suppression de la ressource catalogue '$ResourceId' du catalogue '$CatalogId'..."
    return Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/accessPackageResourceRequests" -ApiVersion "beta" -Method POST -Body $body -IgnoreNotFound
}

Export-ModuleMember -Function Get-CatalogueEntra, New-CatalogueEntra, Set-CatalogueEntra, Remove-CatalogueEntra, `
    Get-RessourcesCatalogue, Add-RessourceCatalogue, Remove-RessourceCatalogue

