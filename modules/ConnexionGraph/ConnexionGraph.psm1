# ============================================================================
# MODULE : ConnexionGraph
# ============================================================================
# Rôle :
#   Fournit le socle d'authentification OIDC et le client HTTP standardisé
#   pour communiquer avec les API Microsoft Graph (v1.0 et beta).
#
# Auteur : Ardian Cloud IAM & DevOps
# ============================================================================

# Variables de session de module (cache en mémoire)
$script:GraphAccessToken = $null
$script:GraphTokenExpiresOn = [DateTime]::MinValue
$script:CacheUsers = @{}
$script:CacheGroups = @{}
$script:CacheServicePrincipals = @{}

<#
.SYNOPSIS
    Établit la session d'authentification avec Microsoft Graph.
.DESCRIPTION
    Tente de récupérer un jeton Bearer pour Microsoft Graph :
    1. Si un jeton est passé directement via -AccessToken, il est utilisé.
    2. Sinon, interroge Azure CLI via 'az account get-access-token' (compatible GitHub Actions OIDC).
    3. Sinon, vérifie si les variables d'environnement AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID sont définies.
.PARAMETER AccessToken
    Jeton d'accès optionnel passé explicitement.
.PARAMETER Force
    Force le renouvellement du jeton même s'il est encore valide.
#>
function Connect-GraphSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$AccessToken,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    if (-not $Force -and -not [string]::IsNullOrWhiteSpace($script:GraphAccessToken) -and ([DateTime]::UtcNow -lt $script:GraphTokenExpiresOn.AddMinutes(-5))) {
        Write-Verbose "Jeton Microsoft Graph existant toujours valide en cache de session."
        return $script:GraphAccessToken
    }

    # 1. Utilisation du jeton passé directement
    if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
        $script:GraphAccessToken = $AccessToken.Trim()
        $script:GraphTokenExpiresOn = [DateTime]::UtcNow.AddHours(1)
        Write-Verbose "Jeton Microsoft Graph configuré manuellement."
        return $script:GraphAccessToken
    }

    # 2. Utilisation d'Azure CLI (cas standard GitHub Actions OIDC après azure/login)
    try {
        Write-Verbose "Tentative d'obtention du jeton Graph via Azure CLI (az account get-access-token)..."
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
                Write-Verbose "Jeton Microsoft Graph acquis avec succès via Azure CLI."
                return $script:GraphAccessToken
            }
        }
    } catch {
        Write-Verbose "Échec de l'obtention du jeton via Azure CLI : $_"
    }

    # 3. Utilisation de variables d'environnement SPN (Client Credentials)
    if ($env:AZURE_CLIENT_ID -and $env:AZURE_CLIENT_SECRET -and $env:AZURE_TENANT_ID) {
        Write-Verbose "Tentative d'obtention du jeton Graph via Client Credentials (variables d'environnement)..."
        $tokenUri = "https://login.microsoftonline.com/$($env:AZURE_TENANT_ID)/oauth2/v2.0/token"
        $body = @{
            client_id     = $env:AZURE_CLIENT_ID
            client_secret = $env:AZURE_CLIENT_SECRET
            scope         = "https://graph.microsoft.com/.default"
            grant_type    = "client_credentials"
        }
        $resp = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
        if ($resp.access_token) {
            $script:GraphAccessToken = $resp.access_token
            $script:GraphTokenExpiresOn = [DateTime]::UtcNow.AddSeconds($resp.expires_in)
            Write-Verbose "Jeton Microsoft Graph acquis avec succès via Client Credentials."
            return $script:GraphAccessToken
        }
    }

    throw "Impossible d'acquérir un jeton d'accès pour Microsoft Graph. Assurez-vous d'être connecté via 'az login' ou de définir AZURE_CLIENT_ID, AZURE_CLIENT_SECRET et AZURE_TENANT_ID."
}

<#
.SYNOPSIS
    Retourne le jeton d'accès actuel de la session.
#>
function Get-GraphSessionToken {
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
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Endpoint,

        [Parameter(Mandatory = $false)]
        [ValidateSet("GET", "POST", "PATCH", "PUT", "DELETE")]
        [string]$Method = "GET",

        [Parameter(Mandatory = $false)]
        $Body = $null,

        [Parameter(Mandatory = $false)]
        [ValidateSet("v1.0", "beta")]
        [string]$ApiVersion = "v1.0",

        [Parameter(Mandatory = $false)]
        [switch]$AllPages,

        [Parameter(Mandatory = $false)]
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

                # Cas 429 : Throttling Microsoft Graph
                if ($statusCode -eq 429) {
                    $retryAfterSec = 5
                    if ($_.Exception.Response.Headers["Retry-After"]) {
                        [int]::TryParse($_.Exception.Response.Headers["Retry-After"], [ref]$retryAfterSec) | Out-Null
                    }
                    Write-Warning "Limitation Graph API (429). Pause de $retryAfterSec secondes avant tentative $attempt/$maxRetries..."
                    Start-Sleep -Seconds $retryAfterSec
                    continue
                }

                # Cas 404 : Ressource non trouvée
                if ($statusCode -eq 404 -and $IgnoreNotFound) {
                    Write-Verbose "Ressource non trouvée (404) : $currentUrl"
                    return $null
                }

                # Erreur irrécupérable ou max tentatives atteintes
                $errDetails = $_.Exception.Message
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $errDetails = $_.ErrorDetails.Message
                }
                Write-Error "Erreur lors de l'appel Graph [$Method] $currentUrl (HTTP $statusCode) : $errDetails"
                if ($payload) {
                    Write-Verbose "Payload rejeté : $payload"
                }
                throw $_
            }
        }

        if (-not $success) {
            throw "Échec de l'appel Graph [$Method] $currentUrl après $maxRetries tentatives."
        }

        # Méthodes sans contenu de retour attendu (DELETE, ou 204 No Content)
        if ($null -eq $response) {
            return $null
        }

        # Si le résultat contient une collection paginée (@odata.nextLink)
        if ($response.value -ne $null -and $AllPages) {
            foreach ($item in $response.value) {
                $allResults.Add($item)
            }
            $currentUrl = $response.'@odata.nextLink'
        } else {
            # Résultat direct unitaire ou AllPages non demandé
            if ($AllPages -and $response.value -ne $null) {
                return $response.value
            }
            return $response
        }

    } while ($AllPages -and -not [string]::IsNullOrWhiteSpace($currentUrl))

    if ($AllPages) {
        return $allResults.ToArray()
    }

    return $response
}

<#
.SYNOPSIS
    Résout un utilisateur dans Entra ID par son adresse email ou son UserPrincipalName.
.DESCRIPTION
    Interroge /v1.0/users avec mise en cache locale pour éviter les requêtes redondantes.
#>
function Resolve-GraphUser {
    [CmdletBinding()]
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
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$GroupName
    )

    $clean = $GroupName.Trim().ToLowerInvariant()
    if ($script:CacheGroups.ContainsKey($clean)) {
        return $script:CacheGroups[$clean]
    }

    $encoded = $GroupName.Trim().Replace("'", "''")
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
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$DisplayName
    )

    $clean = $DisplayName.Trim().ToLowerInvariant()
    if ($script:CacheServicePrincipals.ContainsKey($clean)) {
        return $script:CacheServicePrincipals[$clean]
    }

    $encoded = $DisplayName.Trim().Replace("'", "''")
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

Export-ModuleMember -Function Connect-GraphSession, Get-GraphSessionToken, Invoke-GraphRequest, Resolve-GraphUser, Resolve-GraphGroup, Resolve-GraphServicePrincipal
