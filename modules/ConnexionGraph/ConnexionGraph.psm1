# ============================================================================
# MODULE : ConnexionGraph
# ============================================================================
# Rôle: 
#   Fournit le socle d'authentification OIDC et le client HTTP standardisé
#   pour communiquer avec les API Microsoft Graph (v1.0 et beta).
# ============================================================================

# Cache de session : jeton et dictionnaires de résolution par type de ressource
$script:GraphAccessToken = $null
$script:GraphTokenExpiresOn = [DateTime]::MinValue
$script:CacheUsers             = [System.Collections.Generic.Dictionary[string, PSObject]]::new()
$script:CacheGroups            = [System.Collections.Generic.Dictionary[string, PSObject]]::new()
$script:CacheServicePrincipals = [System.Collections.Generic.Dictionary[string, PSObject]]::new()
$script:CacheSites             = [System.Collections.Generic.Dictionary[string, PSObject]]::new()

<#
.SYNOPSIS
    Établit la session d'authentification OIDC avec Microsoft Graph.
.DESCRIPTION
    Acquiert un jeton Bearer via Azure CLI (compatible GitHub Actions OIDC
    après azure/login). Le jeton est mis en cache et réutilisé tant qu'il
    reste valide (marge de sécurité de 5 minutes avant expiration).
.PARAMETER Force
    Force le renouvellement du jeton même s'il est encore valide.
#>
function Connect-GraphSession {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch]$Force
    )

    # Réutiliser le jeton en cache s'il reste valide (marge de 5 min)
    if (-not $Force -and -not [string]::IsNullOrWhiteSpace($script:GraphAccessToken) -and ([DateTime]::UtcNow -lt $script:GraphTokenExpiresOn.AddMinutes(-5))) {
        Write-Verbose "Jeton Microsoft Graph existant toujours valide en cache de session."
        return $script:GraphAccessToken
    }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI (az) introuvable. Installez Azure CLI ou assurez-vous qu'il est dans le PATH."
    }

    try {
        Write-Verbose "Obtention du jeton Graph via OIDC Azure CLI (az account get-access-token)..."
        $azResult = az account get-access-token --resource-type ms-graph --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($azResult)) {
            $tokenObj = $azResult | ConvertFrom-Json
            if ($tokenObj.accessToken) {
                $script:GraphAccessToken = $tokenObj.accessToken
                if ($tokenObj.expiresOn) {
                    $script:GraphTokenExpiresOn = [DateTime]::Parse($tokenObj.expiresOn).ToUniversalTime()
                } else {
                    $script:GraphTokenExpiresOn = [DateTime]::UtcNow.AddMinutes(50)
                }
                Write-Verbose "Jeton Microsoft Graph acquis avec succès via OIDC (Azure CLI)."
                return $script:GraphAccessToken
            }
        }
    } catch {
        Write-Verbose "Échec de l'obtention du jeton via Azure CLI OIDC : $_"
    }

    throw "Impossible d'acquérir un jeton d'accès pour Microsoft Graph. Assurez-vous d'être connecté via OIDC (az login / azure/login dans GitHub Actions)."
}

<#
.SYNOPSIS
    Retourne le jeton d'accès actuel de la session.
#>
function Get-GraphSessionToken {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([string]::IsNullOrWhiteSpace($script:GraphAccessToken) -or ([DateTime]::UtcNow -ge $script:GraphTokenExpiresOn)) {
        return (Connect-GraphSession)
    }
    return $script:GraphAccessToken
}

<#
.SYNOPSIS
    Exécute une requête HTTP REST unifiée contre Microsoft Graph API.
.DESCRIPTION
    Gère automatiquement l'en-tête d'autorisation, la pagination (@odata.nextLink),
    le renvoi avec temporisation en cas de throttling (HTTP 429), et formate
    les résultats en objets PowerShell.
.PARAMETER Endpoint
    Chemin d'accès relatif (ex: '/identityGovernance/entitlementManagement/catalogs') ou URL absolue.
.PARAMETER Method
    Méthode HTTP (GET, POST, PATCH, PUT, DELETE). Par défaut 'GET'.
.PARAMETER Body
    Corps de la requête (Hashtable, PSObject ou chaîne JSON).
.PARAMETER ApiVersion
    Version de l'API Graph ('v1.0' ou 'beta'). Par défaut 'v1.0'.
.PARAMETER AllPages
    Si présent, suit automatiquement tous les liens de pagination '@odata.nextLink' et agrège les résultats.
.PARAMETER IgnoreNotFound
    Si vrai, ne lève pas d'erreur sur un code 404 (retourne $null).
#>
function Invoke-GraphRequest {
    [CmdletBinding()]
    [OutputType([PSObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Endpoint,

        [ValidateSet("GET", "POST", "PATCH", "PUT", "DELETE")]
        [string]$Method = "GET",

        $Body = $null,

        [ValidateSet("v1.0", "beta")]
        [string]$ApiVersion = "v1.0",

        [switch]$AllPages,

        [switch]$IgnoreNotFound
    )

    $token = Get-GraphSessionToken
    $headers = @{
        "Authorization" = "Bearer $token"
        "Accept"        = "application/json"
    }

    # Construction de l'URL absolue si un chemin relatif est passé
    $targetUrl = $Endpoint
    if (-not ($targetUrl.StartsWith("https://", [StringComparison]::OrdinalIgnoreCase))) {
        if (-not ($targetUrl.StartsWith("/"))) {
            $targetUrl = "/" + $targetUrl
        }
        $targetUrl = "https://graph.microsoft.com/$ApiVersion$targetUrl"
    }

    # Préparation du corps de requête (JSON)
    $payload = $null
    if ($null -ne $Body) {
        $headers["Content-Type"] = "application/json; charset=utf-8"
        if ($Body -is [string]) {
            $payload = $Body
        } else {
            $payload = $Body | ConvertTo-Json -Depth 20 -Compress
        }
    }

    $allResults = [System.Collections.Generic.List[PSObject]]::new()
    $currentUrl = $targetUrl
    $maxRetries = 5

    do {
        $attempt = 0
        $response = $null
        $success = $false

        while (-not $success -and $attempt -lt $maxRetries) {
            $attempt++
            try {
                $params = @{
                    Uri         = $currentUrl
                    Method      = $Method
                    Headers     = $headers
                    ErrorAction = 'Stop'
                }
                if ($payload -and ($Method -in @("POST", "PATCH", "PUT"))) {
                    $params["Body"] = [System.Text.Encoding]::UTF8.GetBytes($payload)
                }

                $response = Invoke-RestMethod @params
                $success = $true
            } catch {
                $statusCode = 0
                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }

                # Throttling : respecter Retry-After avant de réessayer
                if ($statusCode -eq 429) {
                    $retryAfterSec = 5
                    if ($_.Exception.Response.Headers["Retry-After"]) {
                        [int]::TryParse($_.Exception.Response.Headers["Retry-After"], [ref]$retryAfterSec) | Out-Null
                    }
                    Write-Warning "Limitation Graph API (429). Pause de $retryAfterSec secondes avant tentative $attempt/$maxRetries..."
                    Start-Sleep -Seconds $retryAfterSec
                    continue
                }

                if ($statusCode -eq 404 -and $IgnoreNotFound) {
                    Write-Verbose "Ressource non trouvée (404) : $currentUrl"
                    return $null
                }

                # Erreur irrécupérable : remonter le détail Graph le plus précis disponible
                $errDetails = $_.Exception.Message
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $errDetails = $_.ErrorDetails.Message
                }
                if ($payload) {
                    Write-Verbose "Payload rejeté : $payload"
                }
                throw "Erreur lors de l'appel Graph [$Method] $currentUrl (HTTP $statusCode) : $errDetails"
            }
        }

        if (-not $success) {
            throw "Échec de l'appel Graph [$Method] $currentUrl après $maxRetries tentatives."
        }

        # Réponse vide (DELETE 204, etc.)
        if ($null -eq $response) {
            return $null
        }

        # Sans pagination demandée → retour immédiat
        if (-not $AllPages) {
            return $response
        }

        # Accumulation paginée
        if ($null -ne $response.value) {
            foreach ($item in $response.value) {
                $allResults.Add($item)
            }
            $currentUrl = $response.'@odata.nextLink'
        } else {
            # Résultat unitaire (pas de .value) malgré AllPages → retour tel quel
            return $response
        }

    } while (-not [string]::IsNullOrWhiteSpace($currentUrl))

    return $allResults.ToArray()
}

<#
.SYNOPSIS
    Résout un utilisateur dans Entra ID par son adresse email ou son UserPrincipalName.
    Associe le nom d'un user déclaré dans le yaml avec son GUID
.DESCRIPTION
    Interroge /v1.0/users avec mise en cache locale pour éviter les requêtes redondantes.
#>
function Resolve-GraphUser {
    [CmdletBinding()]
    [OutputType([PSObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$UserEmailOrUpn
    )

    $clean = $UserEmailOrUpn.Trim().ToLowerInvariant()
    if ($script:CacheUsers.ContainsKey($clean)) {
        return $script:CacheUsers[$clean]
    }

    $encoded = $clean.Replace("'", "''")
    $filter = "userPrincipalName eq '$encoded' or mail eq '$encoded'"
    $endpoint = "/users?`$filter=$([System.Uri]::EscapeDataString($filter))&`$select=id,displayName,userPrincipalName,mail,accountEnabled"

    try {
        $result = Invoke-GraphRequest -Endpoint $endpoint -Method GET -IgnoreNotFound
        if ($result -and $result.value -and $result.value.Count -gt 0) {
            $user = $result.value[0]
            $script:CacheUsers[$clean] = $user
            return $user
        }
    } catch {
        Write-Warning "Erreur lors de la résolution de l'utilisateur '$clean' : $_"
    }

    return $null
}

<#
.SYNOPSIS
    Résout un groupe de sécurité dans Entra ID par son displayName exact.
.DESCRIPTION
    Interroge /v1.0/groups avec mise en cache locale.
#>
function Resolve-GraphGroup {
    [CmdletBinding()]
    [OutputType([PSObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$GroupName
    )

    $trimmed = $GroupName.Trim()
    $clean = $trimmed.ToLowerInvariant()
    if ($script:CacheGroups.ContainsKey($clean)) {
        return $script:CacheGroups[$clean]
    }

    # Échappement OData : doubler les apostrophes dans le displayName
    $encoded = $trimmed.Replace("'", "''")
    $filter = "displayName eq '$encoded'"
    $endpoint = "/groups?`$filter=$([System.Uri]::EscapeDataString($filter))&`$select=id,displayName,securityEnabled,groupTypes"

    try {
        $result = Invoke-GraphRequest -Endpoint $endpoint -Method GET -IgnoreNotFound
        if ($result -and $result.value -and $result.value.Count -gt 0) {
            $grp = $result.value[0]
            $script:CacheGroups[$clean] = $grp
            return $grp
        }
    } catch {
        Write-Warning "Erreur lors de la résolution du groupe '$clean' : $_"
    }

    return $null
}

<#
.SYNOPSIS
    Résout un Service Principal (Enterprise Application) par son displayName.
.DESCRIPTION
    Interroge /v1.0/servicePrincipals avec mise en cache locale.
#>
function Resolve-GraphServicePrincipal {
    [CmdletBinding()]
    [OutputType([PSObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$DisplayName
    )

    $trimmed = $DisplayName.Trim()
    $clean = $trimmed.ToLowerInvariant()
    if ($script:CacheServicePrincipals.ContainsKey($clean)) {
        return $script:CacheServicePrincipals[$clean]
    }

    $encoded = $trimmed.Replace("'", "''")
    $filter = "displayName eq '$encoded'"
    $endpoint = "/servicePrincipals?`$filter=$([System.Uri]::EscapeDataString($filter))&`$select=id,displayName,appId,appRoles"

    try {
        $result = Invoke-GraphRequest -Endpoint $endpoint -Method GET -IgnoreNotFound
        if ($result -and $result.value -and $result.value.Count -gt 0) {
            $sp = $result.value[0]
            $script:CacheServicePrincipals[$clean] = $sp
            return $sp
        }
    } catch {
        Write-Warning "Erreur lors de la résolution du service principal '$clean' : $_"
    }

    return $null
}

<#
.SYNOPSIS
    Résout un site SharePoint dans Microsoft 365 par son URL.
.DESCRIPTION
    Interroge /v1.0/sites/{hostname}:/{relative-path} avec mise en cache locale.
.PARAMETER SiteUrl
    URL absolue du site SharePoint (ex: 'https://ardian.sharepoint.com/sites/MonSite').
#>
function Resolve-SharepointSite {
    [CmdletBinding()]
    [OutputType([PSObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SiteUrl
    )

    $clean = $SiteUrl.Trim()
    $cacheKey = $clean.ToLowerInvariant()
    if ($script:CacheSites.ContainsKey($cacheKey)) {
        return $script:CacheSites[$cacheKey]
    }

    try {
        $uri = [System.Uri]$clean
        $hostname = $uri.Host
        $relativePath = $uri.AbsolutePath.TrimEnd('/')

        $endpoint = "/sites/$hostname`:$relativePath"
        $site = Invoke-GraphRequest -Endpoint $endpoint -Method GET -IgnoreNotFound
        if ($site -and $site.id) {
            $script:CacheSites[$cacheKey] = $site
            return $site
        }
    } catch {
        Write-Warning "Erreur lors de la résolution du site SharePoint '$clean' : $_"
    }

    return $null
}

Export-ModuleMember -Function Connect-GraphSession, Get-GraphSessionToken, Invoke-GraphRequest, Resolve-GraphUser, Resolve-GraphGroup, Resolve-GraphServicePrincipal, Resolve-SharepointSite
