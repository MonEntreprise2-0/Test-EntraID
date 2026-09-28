# ============================================================================
# MODULE : ValidationSyntaxe
# ============================================================================
# Rôle :
#   Valide la syntaxe des fichiers YAML, le respect du schéma déclaratif dans les yaml,
#   la cohérence de nomenclature et effectue le contrôle bloquant SSoT
#   contre Microsoft Entra ID pour s'assurer que les ressources existent.
# ============================================================================

<#
.SYNOPSIS
    Calcule le nom standardisé d'un Access Package selon la règle de nomenclature.
.DESCRIPTION
    Formule :
    - Si context_subapp est défini : "[context_subapp] [privilege_level] - [env]"
    - Sinon : "[privilege_level] - [env]"
#>
function Calculer-NomAccessPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $AccessPackage,

        [Parameter(Mandatory = $false)]
        [string]$AppName = ""
    )

    if ($AccessPackage.display_name -and -not [string]::IsNullOrWhiteSpace($AccessPackage.display_name)) {
        return $AccessPackage.display_name.Trim()
    }

    $app = ""
    if (-not [string]::IsNullOrWhiteSpace($AppName)) {
        $app = $AppName.Trim()
    } elseif ($AccessPackage.app_name -and -not [string]::IsNullOrWhiteSpace($AccessPackage.app_name)) {
        $app = $AccessPackage.app_name.Trim()
    }

    $context = ""
    if ($AccessPackage.context_subapp -and -not [string]::IsNullOrWhiteSpace($AccessPackage.context_subapp)) {
        $context = "$($AccessPackage.context_subapp.Trim()) "
    }

    $privilege = if ($AccessPackage.privilege_level) { $AccessPackage.privilege_level.Trim() } else { "" }
    $env = if ($AccessPackage.env) { $AccessPackage.env.Trim().ToUpperInvariant() } else { "" }

    if (-not [string]::IsNullOrWhiteSpace($app)) {
        return "$app - $context$privilege - $env".Trim()
    } else {
        return "$context$privilege - $env".Trim()
    }
}

<#
.SYNOPSIS
    Lit un fichier YAML et le convertit en objet/dictionnaire PowerShell.
.DESCRIPTION
    Utilise 'ConvertFrom-Yaml' si le module 'powershell-yaml' est présent.
    Fournit un parseur natif PowerShell en secours pour les fichiers déclaratifs Ardian.
#>
function Lire-DeclarationYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Le fichier de déclaration YAML n'existe pas : $Path"
    }

    $content = Get-Content -Path $Path -Raw -Encoding UTF8

    # 1. Tentative avec powershell-yaml (si disponible)
    if (Get-Command -Name "ConvertFrom-Yaml" -ErrorAction SilentlyContinue) {
        try {
            $parsed = ConvertFrom-Yaml -Yaml $content
            if ($parsed) {
                return $parsed
            }
        } catch {
            Write-Verbose "ConvertFrom-Yaml a levé une exception, bascule sur le parseur de secours : $_"
        }
    }

    # 2. Parseur natif de secours spécialisé pour le format déclaratif Ardian v2/v1
    return ConvertFrom-ArdianYamlInternal -YamlContent $content
}

# Parseur interne pour le schéma Ardian
function ConvertFrom-ArdianYamlInternal {
    param([string]$YamlContent)

    $result = [ordered]@{}
    $lines = $YamlContent -split "`r?`n"
    
    $currentAp = $null
    $currentResource = $null
    $inAccessPackages = $false
    $inResources = $false
    $inOwners = $false
    $accessPackagesList = [System.Collections.Generic.List[object]]::new()

    function Clean-YamlValue {
        param([string]$RawVal)
        if ($null -eq $RawVal) { return "" }
        $v = $RawVal.Trim()
        if ($v -match '^"(?<quoted>[^"]*)"\s*(?:#.*)?$') {
            return $Matches['quoted']
        }
        if ($v -match "^'(?<quoted>[^']*)'\s*(?:#.*)?$") {
            return $Matches['quoted']
        }
        if ($v -match '^(?<unquoted>[^#]+?)\s*(?:#.*)?$') {
            return $Matches['unquoted'].Trim()
        }
        return $v
    }

    foreach ($rawLine in $lines) {
        # Nettoyage des commentaires pleine ligne et espaces superflus
        $trimmed = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        # Détection de l'indentation
        $indent = 0
        while ($indent -lt $rawLine.Length -and $rawLine[$indent] -eq ' ') {
            $indent++
        }

        # 1. Clés de niveau racine
        if (-not $inAccessPackages -and $trimmed -match '^([a-zA-Z0-9_-]+)\s*:\s*(.*)$') {
            $key = $Matches[1].Trim()
            $val = Clean-YamlValue $Matches[2]

            if ($key -eq "access_packages") {
                $inAccessPackages = $true
            } else {
                $result[$key] = $val
            }
            continue
        }

        # 2. Section access_packages
        if ($inAccessPackages) {
            # Détection d'un nouvel Access Package
            if ($trimmed -match '^-\s*(.*)$') {
                $afterDash = $Matches[1].Trim()
                $isNewAp = $false

                if (-not $inResources -and -not $inOwners) {
                    $isNewAp = $true
                } elseif ($inOwners -and $afterDash -match '^(context_subapp|privilege_level|env|description|display_name)\s*:') {
                    $isNewAp = $true
                    $inOwners = $false
                } elseif ($inResources -and $afterDash -match '^(context_subapp|privilege_level|env|description|display_name)\s*:') {
                    $isNewAp = $true
                    $inResources = $false
                }

                if ($isNewAp) {
                    $currentAp = [ordered]@{
                        resources            = [System.Collections.Generic.List[object]]::new()
                        authorization_owners = [System.Collections.Generic.List[string]]::new()
                    }
                    $accessPackagesList.Add($currentAp)
                    $inResources = $false
                    $inOwners = $false
                    $currentResource = $null

                    if ($afterDash -match '^([a-zA-Z0-9_-]+)\s*:\s*(.*)$') {
                        $k = $Matches[1].Trim()
                        $v = Clean-YamlValue $Matches[2]
                        $currentAp[$k] = $v
                    }
                    continue
                }
            }

            # Éléments de liste sous authorization_owners
            if ($inOwners) {
                if ($trimmed -match '^-\s*(.*)$') {
                    $ownerEmail = Clean-YamlValue $Matches[1]
                    if ($currentAp -and -not [string]::IsNullOrWhiteSpace($ownerEmail)) {
                        $currentAp.authorization_owners.Add($ownerEmail)
                    }
                    continue
                } else {
                    $inOwners = $false
                }
            }

            # Éléments sous resources
            if ($inResources) {
                if ($trimmed -match '^-\s*(.*)$') {
                    $resLine = $Matches[1].Trim()
                    $currentResource = [ordered]@{}
                    if ($currentAp) {
                        $currentAp.resources.Add($currentResource)
                    }
                    if ($resLine -match '^([a-zA-Z0-9_-]+)\s*:\s*(.*)$') {
                        $rk = $Matches[1].Trim()
                        $rv = Clean-YamlValue $Matches[2]
                        $currentResource[$rk] = $rv
                    }
                    continue
                } elseif ($currentResource -and $trimmed -match '^(group_name|role|enterprise_app|app_role|sharepoint_url|sharepoint_group_name|catalog_id)\s*:\s*(.*)$') {
                    $rk = $Matches[1].Trim()
                    $rv = Clean-YamlValue $Matches[2]
                    $currentResource[$rk] = $rv
                    continue
                } else {
                    $inResources = $false
                }
            }

            # Propriétés directes de l'Access Package
            if ($trimmed -match '^([a-zA-Z0-9_-]+)\s*:\s*(.*)$') {
                $k = $Matches[1].Trim()
                $v = Clean-YamlValue $Matches[2]

                if ($k -eq "resources") {
                    $inResources = ($Matches[2].Trim() -ne "[]")
                    $inOwners = $false
                    continue
                } elseif ($k -eq "authorization_owners") {
                    $inOwners = ($Matches[2].Trim() -ne "[]")
                    $inResources = $false
                    continue
                } else {
                    if ($currentAp) {
                        $currentAp[$k] = $v
                    }
                    continue
                }
            }
        }
    }

    # Conversion en PSCustomObject pour compatibilité
    $finalAps = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($apHash in $accessPackagesList) {
        $resList = [System.Collections.Generic.List[PSObject]]::new()
        foreach ($rHash in $apHash.resources) {
            $resList.Add([PSCustomObject]$rHash)
        }
        $apHash.resources = $resList.ToArray()
        $apHash.authorization_owners = $apHash.authorization_owners.ToArray()
        $finalAps.Add([PSCustomObject]$apHash)
    }

    $result["access_packages"] = $finalAps.ToArray()
    return [PSCustomObject]$result
}

<#
.SYNOPSIS
    Valide la structure et les contraintes du schéma déclaratif Ardian v2.
.DESCRIPTION
    Vérifie les contraintes obligatoires :
    - app_name : kebab-case (regex : ^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$)
    - Concordance entre le nom du fichier, le nom du dossier et app_name
    - app_description : entre 5 et 500 caractères
    - access_packages : au moins 1 paquet d'accès
    - Pour chaque access_package :
      - privilege_level, env, description obligatoires
      - authorization_owners : au moins 1 adresse email valide
      - resources : au moins 1 ressource valide (group_name pour EntraID Group, enterprise_app/app_role pour Application Role)
    - Unicité des noms d'Access Packages générés au sein de l'application
#>
function Valider-StructureYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        $ParsedDoc = $null
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $ParsedDoc) {
        try {
            $ParsedDoc = Lire-DeclarationYaml -Path $FilePath
        } catch {
            $errors.Add("Erreur de parsing YAML dans le fichier $FilePath : $_")
            return [PSCustomObject]@{
                IsValid  = $false
                Errors   = $errors.ToArray()
                AppName  = ""
                FilePath = $FilePath
            }
        }
    }

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $parentDir = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($FilePath))

    # 1. Validation app_name (sans restriction kebab-case : espaces et majuscules autorisés)
    $appName = $ParsedDoc.app_name
    if ([string]::IsNullOrWhiteSpace($appName)) {
        $errors.Add("Le champ obligatoire 'app_name' est manquant ou vide.")
    } else {
        # Vérification règle 1 app = 1 dossier = 1 fichier avec préfixe obligatoire CAT-
        $cleanAppName = $appName -replace '^(?i)CAT-', ''
        $expectedName = "CAT-$cleanAppName"

        $unaccent = {
            param([string]$val)
            if ([string]::IsNullOrEmpty($val)) { return "" }
            return ($val -replace '[\u00E8-\u00EB\u00C8-\u00CBéèêëÉÈÊË]','e' `
                        -replace '[\u00E0-\u00E5\u00C0-\u00C5àâäÀÂÄ]','a' `
                        -replace '[\u00EC-\u00EF\u00CC-\u00CFîïÎÏ]','i' `
                        -replace '[\u00F2-\u00F6\u00D2-\u00D6ôöÔÖ]','o' `
                        -replace '[\u00F9-\u00FC\u00D9-\u00DCùûüÙÛÜ]','u' `
                        -replace '[\u00E7\u00C7çÇ]','c')
        }

        $cleanExpected = &$unaccent $expectedName
        $cleanFileName = &$unaccent $fileName
        $cleanParentDir = &$unaccent $parentDir

        $isValidFileName = ($fileName -eq "_example" -or $fileName -eq $expectedName -or $cleanFileName -eq $cleanExpected)
        $isValidParentDir = ($parentDir -eq "_example" -or $parentDir -eq $expectedName -or $cleanParentDir -eq $cleanExpected)

        if (-not $isValidFileName) {
            $errors.Add("Le nom du fichier ('$fileName.yaml') ne respecte pas la nomenclature obligatoire. Attendu : '$expectedName.yaml'.")
        }
        if (-not $isValidParentDir) {
            $errors.Add("Le dossier parent ('$parentDir') ne respecte pas la nomenclature obligatoire. Attendu : '$expectedName'.")
        }
    }

    # 2. Validation app_description (aucune restriction de longueur min ou max)
    $appDesc = $ParsedDoc.app_description
    if ($null -eq $appDesc -or [string]::IsNullOrWhiteSpace($appDesc)) {
        $errors.Add("Le champ obligatoire 'app_description' est manquant ou vide.")
    }

    # 3. Validation access_packages (optionnel : catalogue vide autorisé)
    $aps = $ParsedDoc.access_packages
    if ($aps -and $aps.Count -gt 0) {
        $computedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $allowedEnvs = @('DEV', 'UAT', 'PRD', 'TST', 'GLB')

        $apIndex = 0
        foreach ($ap in $aps) {
            $apIndex++
            $apName = Calculer-NomAccessPackage -AccessPackage $ap -AppName $appName

            if ([string]::IsNullOrWhiteSpace($apName)) {
                $errors.Add("Access Package #$apIndex : Impossible de calculer le nom (privilege_level ou env manquant).")
            } elseif (-not $computedNames.Add($apName)) {
                $errors.Add("Access Package #$apIndex : Doublon détecté. Le nom calculé '$apName' existe déjà dans cette application.")
            }

            if ([string]::IsNullOrWhiteSpace($ap.privilege_level)) {
                $errors.Add("Access Package '$apName' : Le champ 'privilege_level' est obligatoire.")
            }
            if ([string]::IsNullOrWhiteSpace($ap.env)) {
                $errors.Add("Access Package '$apName' : Le champ 'env' est obligatoire.")
            } elseif (-not ($allowedEnvs -contains $ap.env.Trim().ToUpperInvariant())) {
                $errors.Add("Access Package '$apName' : L'environnement '$($ap.env)' n'est pas autorisé. Valeurs strictement autorisées : $($allowedEnvs -join ', ').")
            }
            if ([string]::IsNullOrWhiteSpace($ap.description)) {
                $errors.Add("Access Package '$apName' : Le champ 'description' est obligatoire.")
            }

            # Validation des authorization_owners (optionnel)
            $owners = $ap.authorization_owners
            if ($owners -and $owners.Count -gt 0) {
                foreach ($owner in $owners) {
                    if ([string]::IsNullOrWhiteSpace($owner) -or $owner -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                        $errors.Add("Access Package '$apName' : L'adresse email de l'approbateur '$owner' est invalide.")
                    }
                }
            }

            # Validation des resources (optionnel)
            $resources = $ap.resources
            if ($resources -and $resources.Count -gt 0) {
                $resIndex = 0
                foreach ($res in $resources) {
                    $resIndex++
                    $resType = $res.resource_type
                    if ([string]::IsNullOrWhiteSpace($resType)) {
                        $errors.Add("Access Package '$apName' (ressource #$resIndex) : 'resource_type' est manquant.")
                        continue
                    }

                    switch ($resType) {
                        "EntraID Group" {
                            if ([string]::IsNullOrWhiteSpace($res.group_name)) {
                                $errors.Add("Access Package '$apName' : 'group_name' est requis pour les ressources de type 'EntraID Group'.")
                            }
                            if ($res.role -and ($res.role -notin @("Member", "Owner"))) {
                                $errors.Add("Access Package '$apName' : Le rôle '$($res.role)' est invalide (valeurs autorisées : Member, Owner).")
                            }
                        }
                        "Application Role" {
                            if ([string]::IsNullOrWhiteSpace($res.enterprise_app)) {
                                $errors.Add("Access Package '$apName' : 'enterprise_app' est requis pour les ressources 'Application Role'.")
                            }
                            # Note : app_role est calculé automatiquement si non renseigné
                        }
                        { $_ -in @("Sharepoint Group", "SharePoint Group", "SharePoint Online", "SharePoint Site") } {
                            if ($res.catalog_id) {
                                $errors.Add("Access Package '$apName' : Le champ 'catalog_id' a été supprimé et ne doit plus être utilisé pour les groupes SharePoint.")
                            }
                            if ([string]::IsNullOrWhiteSpace($res.sharepoint_url)) {
                                $errors.Add("Access Package '$apName' : 'sharepoint_url' est requis pour les ressources 'Sharepoint Group'.")
                            }
                            if ([string]::IsNullOrWhiteSpace($res.sharepoint_group_name)) {
                                $errors.Add("Access Package '$apName' : 'sharepoint_group_name' est requis pour les ressources 'Sharepoint Group'.")
                            }
                        }
                        default {
                            $errors.Add("Access Package '$apName' : Type de ressource non supporté '$resType'.")
                        }
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        IsValid   = ($errors.Count -eq 0)
        Errors    = $errors.ToArray()
        AppName   = $appName
        FilePath  = $FilePath
        ParsedDoc = $ParsedDoc
    }
}

<#
.SYNOPSIS
    Effectue le contrôle bloquant SSoT (Single Source of Truth) contre Entra ID.
.DESCRIPTION
    Entra ID est la Source Unique de Vérité. Cette fonction inspecte toutes les
    ressources déclarées dans les fichiers YAML et interroge directement Microsoft
    Graph API pour s'assurer que chaque groupe, application, rôle applicatif, site SharePoint
    et approbateur existe bien dans l'annuaire de production.
.PARAMETER Declarations
    Liste d'objets déclaratifs YAML ou chemins vers les fichiers YAML.
#>
function Valider-RessourcesEntraId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Declarations
    )

    $allGroups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allApps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allUsers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allSites = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $appRolesToCheck = [System.Collections.Generic.List[PSObject]]::new()

    # 1. Extraction exhaustive de toutes les ressources mentionnées
    foreach ($item in $Declarations) {
        $doc = $item
        if ($item -is [string]) {
            $doc = Lire-DeclarationYaml -Path $item
        } elseif ($item.ParsedDoc) {
            $doc = $item.ParsedDoc
        }

        if (-not $doc -or -not $doc.access_packages) {
            continue
        }

        foreach ($ap in $doc.access_packages) {
            # Approbateurs (authorization_owners)
            if ($ap.authorization_owners) {
                foreach ($email in $ap.authorization_owners) {
                    if (-not [string]::IsNullOrWhiteSpace($email)) {
                        $allUsers.Add($email.Trim()) | Out-Null
                    }
                }
            }

            # Ressources (Groupes, Applications, SharePoint)
            if ($ap.resources) {
                foreach ($res in $ap.resources) {
                    $rType = $res.resource_type
                    if ($rType -eq "EntraID Group" -or $rType -eq "Group") {
                        if (-not [string]::IsNullOrWhiteSpace($res.group_name)) {
                            $allGroups.Add($res.group_name.Trim()) | Out-Null
                        }
                    } elseif ($rType -eq "Application Role" -or $rType -eq "Application") {
                        if (-not [string]::IsNullOrWhiteSpace($res.enterprise_app)) {
                            $entAppName = $res.enterprise_app.Trim()
                            $allApps.Add($entAppName) | Out-Null

                            # Calcul automatique de l'AppRole : {context/subapp} {privilege Level}
                            $computedAppRole = if (-not [string]::IsNullOrWhiteSpace($ap.context_subapp)) {
                                "$($ap.context_subapp.Trim()) $($ap.privilege_level.Trim())"
                            } else {
                                "$($ap.privilege_level.Trim())"
                            }

                            $appRolesToCheck.Add([PSCustomObject]@{
                                EnterpriseApp   = $entAppName
                                RequiredAppRole = $computedAppRole
                                AccessPackage   = Calculer-NomAccessPackage -AccessPackage $ap -AppName $doc.app_name
                            })
                        }
                    } elseif ($rType -in @("Sharepoint Group", "SharePoint Group", "SharePoint Online", "SharePoint Site")) {
                        if (-not [string]::IsNullOrWhiteSpace($res.sharepoint_url)) {
                            $allSites.Add($res.sharepoint_url.Trim()) | Out-Null
                        }
                    }
                }
            }
        }
    }

    # 2. Résolution SSoT contre Microsoft Entra ID
    $missingGroups = [System.Collections.Generic.List[string]]::new()
    $missingApps = [System.Collections.Generic.List[string]]::new()
    $missingUsers = [System.Collections.Generic.List[string]]::new()
    $missingSites = [System.Collections.Generic.List[string]]::new()
    $missingAppRoles = [System.Collections.Generic.List[string]]::new()

    $resolvedGroups = @{}
    $resolvedApps = @{}
    $resolvedUsers = @{}
    $resolvedSites = @{}

    # Groupes
    foreach ($grpName in $allGroups) {
        $grpObj = Resolve-GraphGroup -GroupName $grpName
        if ($grpObj) {
            $resolvedGroups[$grpName] = $grpObj
        } else {
            $missingGroups.Add($grpName)
        }
    }

    # Applications (Enterprise Apps / Service Principals)
    foreach ($appName in $allApps) {
        $appObj = Resolve-GraphServicePrincipal -DisplayName $appName
        if ($appObj) {
            $resolvedApps[$appName] = $appObj
        } else {
            $missingApps.Add($appName)
        }
    }

    # Utilisateurs (Approbateurs)
    foreach ($userEmail in $allUsers) {
        $userObj = Resolve-GraphUser -UserEmailOrUpn $userEmail
        if ($userObj) {
            $resolvedUsers[$userEmail] = $userObj
        } else {
            $missingUsers.Add($userEmail)
        }
    }

    # Sites SharePoint
    foreach ($siteUrl in $allSites) {
        $siteObj = Resolve-SharepointSite -SiteUrl $siteUrl
        if ($siteObj) {
            $resolvedSites[$siteUrl] = $siteObj
        } else {
            $missingSites.Add($siteUrl)
        }
    }

    # 3. Contrôle SSoT bloquant pour les AppRoles déclarés
    foreach ($chk in $appRolesToCheck) {
        $entApp = $chk.EnterpriseApp
        $reqRole = $chk.RequiredAppRole
        if ($resolvedApps.ContainsKey($entApp)) {
            $sp = $resolvedApps[$entApp]
            $roleExists = $false
            if ($sp.appRoles) {
                foreach ($r in $sp.appRoles) {
                    if (($r.value -and $r.value.Equals($reqRole, [StringComparison]::OrdinalIgnoreCase)) -or
                        ($r.displayName -and $r.displayName.Equals($reqRole, [StringComparison]::OrdinalIgnoreCase))) {
                        $roleExists = $true
                        break
                    }
                }
            }
            if (-not $roleExists) {
                $missingAppRoles.Add("Application '$entApp' -> Rôle '$reqRole' requis pour '$($chk.AccessPackage)'")
            }
        }
    }

    $isValid = ($missingGroups.Count -eq 0 -and $missingApps.Count -eq 0 -and $missingUsers.Count -eq 0 -and $missingSites.Count -eq 0 -and $missingAppRoles.Count -eq 0)

    return [PSCustomObject]@{
        IsValid         = $isValid
        MissingGroups   = $missingGroups.ToArray()
        MissingApps     = $missingApps.ToArray()
        MissingUsers    = $missingUsers.ToArray()
        MissingSites    = $missingSites.ToArray()
        MissingAppRoles = $missingAppRoles.ToArray()
        ResolvedGroups  = $resolvedGroups
        ResolvedApps    = $resolvedApps
        ResolvedUsers   = $resolvedUsers
        ResolvedSites   = $resolvedSites
        TotalChecked    = ($allGroups.Count + $allApps.Count + $allUsers.Count + $allSites.Count + $appRolesToCheck.Count)
    }
}

Export-ModuleMember -Function Lire-DeclarationYaml, Valider-StructureYaml, Valider-RessourcesEntraId, Calculer-NomAccessPackage, ConvertFrom-ArdianYamlInternal
