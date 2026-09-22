# ============================================================================
# MODULE : ValidationSyntaxe
# ============================================================================
# Rôle :
#   Valide la syntaxe des fichiers YAML, le respect du schéma déclaratif Ardian v2,
#   la cohérence de nomenclature et effectue le contrôle bloquant SSoT
#   (Single Source of Truth) contre Microsoft Entra ID.
#
# Auteur : Ardian Cloud IAM & DevOps
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
        $AccessPackage
    )

    if ($AccessPackage.display_name -and -not [string]::IsNullOrWhiteSpace($AccessPackage.display_name)) {
        return $AccessPackage.display_name.Trim()
    }

    $context = ""
    if ($AccessPackage.context_subapp -and -not [string]::IsNullOrWhiteSpace($AccessPackage.context_subapp)) {
        $context = "$($AccessPackage.context_subapp.Trim()) "
    }

    $privilege = if ($AccessPackage.privilege_level) { $AccessPackage.privilege_level.Trim() } else { "" }
    $env = if ($AccessPackage.env) { $AccessPackage.env.Trim() } else { "" }

    return "$context$privilege - $env".Trim()
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
            $val = $Matches[2].Trim()
            if ($val -match '^["''](.*)["'']$') { $val = $Matches[1] }

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
                        $v = $Matches[2].Trim()
                        if ($v -match '^["''](.*)["'']$') { $v = $Matches[1] }
                        $currentAp[$k] = $v
                    }
                    continue
                }
            }

            # Éléments de liste sous authorization_owners
            if ($inOwners) {
                if ($trimmed -match '^-\s*["'']?([^"'']+)["'']?$') {
                    $ownerEmail = $Matches[1].Trim()
                    if ($currentAp) {
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
                        $rv = $Matches[2].Trim()
                        if ($rv -match '^["''](.*)["'']$') { $rv = $Matches[1] }
                        $currentResource[$rk] = $rv
                    }
                    continue
                } elseif ($currentResource -and $trimmed -match '^(group_name|role|enterprise_app|app_role|sharepoint_url|catalog_id)\s*:\s*(.*)$') {
                    $rk = $Matches[1].Trim()
                    $rv = $Matches[2].Trim()
                    if ($rv -match '^["''](.*)["'']$') { $rv = $Matches[1] }
                    $currentResource[$rk] = $rv
                    continue
                } else {
                    $inResources = $false
                }
            }

            # Propriétés directes de l'Access Package
            if ($trimmed -match '^([a-zA-Z0-9_-]+)\s*:\s*(.*)$') {
                $k = $Matches[1].Trim()
                $v = $Matches[2].Trim()
                if ($v -match '^["''](.*)["'']$') { $v = $Matches[1] }

                if ($k -eq "resources") {
                    $inResources = $true
                    $inOwners = $false
                    continue
                } elseif ($k -eq "authorization_owners") {
                    $inOwners = $true
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

    # 1. Validation app_name
    $appName = $ParsedDoc.app_name
    if ([string]::IsNullOrWhiteSpace($appName)) {
        $errors.Add("Le champ obligatoire 'app_name' est manquant ou vide.")
    } else {
        if ($appName -notmatch '^[a-z0-9][a-z0-9-_]{1,62}[a-z0-9]$') {
            $errors.Add("Le champ 'app_name' ('$appName') doit respecter le format kebab-case ou snake_case (minuscules, chiffres, tirets, underscores) avec une longueur entre 3 et 64 caractères.")
        }
        # Vérification règle 1 app = 1 dossier = 1 fichier
        if ($fileName -ne "_example" -and $fileName -ne $appName) {
            $errors.Add("Le nom du fichier ('$fileName.yaml') ne correspond pas au 'app_name' ('$appName').")
        }
        if ($parentDir -ne "_example" -and $parentDir -ne $appName) {
            $errors.Add("Le dossier parent ('$parentDir') ne correspond pas au 'app_name' ('$appName').")
        }
    }

    # 2. Validation app_description
    $appDesc = $ParsedDoc.app_description
    if ([string]::IsNullOrWhiteSpace($appDesc)) {
        $errors.Add("Le champ obligatoire 'app_description' est manquant.")
    } elseif ($appDesc.Length -lt 5 -or $appDesc.Length -gt 500) {
        $errors.Add("La description de l'application doit contenir entre 5 et 500 caractères (longueur actuelle : $($appDesc.Length)).")
    }

    # 3. Validation access_packages
    $aps = $ParsedDoc.access_packages
    if ($null -eq $aps -or $aps.Count -eq 0) {
        $errors.Add("La liste 'access_packages' doit contenir au moins 1 Access Package.")
    } else {
        $computedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $apIndex = 0
        foreach ($ap in $aps) {
            $apIndex++
            $apName = Calculer-NomAccessPackage -AccessPackage $ap

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
            }
            if ([string]::IsNullOrWhiteSpace($ap.description) -or $ap.description.Length -lt 5) {
                $errors.Add("Access Package '$apName' : Le champ 'description' est obligatoire (au moins 5 caractères).")
            }

            # Validation des authorization_owners
            $owners = $ap.authorization_owners
            if ($null -eq $owners -or $owners.Count -eq 0) {
                $errors.Add("Access Package '$apName' : 'authorization_owners' doit contenir au moins 1 adresse email.")
            } else {
                foreach ($owner in $owners) {
                    if ([string]::IsNullOrWhiteSpace($owner) -or $owner -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                        $errors.Add("Access Package '$apName' : L'adresse email de l'approbateur '$owner' est invalide.")
                    }
                }
            }

            # Validation des resources
            $resources = $ap.resources
            if ($null -eq $resources -or $resources.Count -eq 0) {
                $errors.Add("Access Package '$apName' : 'resources' doit contenir au moins 1 ressource.")
            } else {
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
                            if ([string]::IsNullOrWhiteSpace($res.app_role)) {
                                $errors.Add("Access Package '$apName' : 'app_role' est requis pour les ressources 'Application Role'.")
                            }
                        }
                        "Sharepoint Group" {
                            if ([string]::IsNullOrWhiteSpace($res.sharepoint_url)) {
                                $errors.Add("Access Package '$apName' : 'sharepoint_url' est requis pour les ressources 'Sharepoint Group'.")
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
    Graph API pour s'assurer que chaque groupe, application et approbateur existe bien
    dans l'annuaire de production.
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

            # Ressources (Groupes, Applications)
            if ($ap.resources) {
                foreach ($res in $ap.resources) {
                    $rType = $res.resource_type
                    if ($rType -eq "EntraID Group" -or $rType -eq "Group") {
                        if (-not [string]::IsNullOrWhiteSpace($res.group_name)) {
                            $allGroups.Add($res.group_name.Trim()) | Out-Null
                        }
                    } elseif ($rType -eq "Application Role" -or $rType -eq "Application") {
                        if (-not [string]::IsNullOrWhiteSpace($res.enterprise_app)) {
                            $allApps.Add($res.enterprise_app.Trim()) | Out-Null
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

    $resolvedGroups = @{}
    $resolvedApps = @{}
    $resolvedUsers = @{}

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

    $isValid = ($missingGroups.Count -eq 0 -and $missingApps.Count -eq 0 -and $missingUsers.Count -eq 0)

    return [PSCustomObject]@{
        IsValid        = $isValid
        MissingGroups  = $missingGroups.ToArray()
        MissingApps    = $missingApps.ToArray()
        MissingUsers   = $missingUsers.ToArray()
        ResolvedGroups = $resolvedGroups
        ResolvedApps   = $resolvedApps
        ResolvedUsers  = $resolvedUsers
        TotalChecked   = ($allGroups.Count + $allApps.Count + $allUsers.Count)
    }
}

Export-ModuleMember -Function Lire-DeclarationYaml, Valider-StructureYaml, Valider-RessourcesEntraId, Calculer-NomAccessPackage
